-- myclippings.koplugin
-- Consolidates highlights across your library into one live-updating file
-- (home-folder-relative), plus a formatted HTML "highlights book".

local Dispatcher = require("dispatcher")
local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local MyClippings = WidgetContainer:extend{
    name = "myclippings",
    is_doc_only = false,
}

local REGEN_DEBOUNCE_SECONDS = 8
local LINK_SCHEME = "hsjump"

function MyClippings:init()
    self.settings = LuaSettings:open(
        ("%s/%s"):format(DataStorage:getSettingsDir(), "myclippings_settings.lua")
    )
    self.db_path = ("%s/%s"):format(DataStorage:getSettingsDir(), "myclippings_db.lua")
    self:loadDB()

    if self.ui and self.ui.menu then
        self:onDispatcherRegisterActions()
        self.ui.menu:registerToMainMenu(self)
    end

    -- Register our custom link scheme so tapped jump-links bring up the
    -- external link dialog, where we add an "Open in book" button.
    if self.ui and self.ui.link then
        self.ui.link:registerScheme(LINK_SCHEME)
        self.ui.link:addToExternalLinkDialog("50_myclippings_jump", function(this, link_url)
            if not link_url:match("^" .. LINK_SCHEME .. "://") then return nil end
            return {
                text = _("Open in book"),
                callback = function()
                    UIManager:close(this.external_link_dialog)
                    MyClippings:jumpToLink(link_url)
                end,
            }
        end)
    end
end

function MyClippings:onDispatcherRegisterActions()
    Dispatcher:registerAction("myclippings_scan", {
        category = "none",
        event = "MyClippingsScan",
        title = _("Highlight Sync: scan now"),
        general = true,
    })
end

function MyClippings:onMyClippingsScan()
    self:scanAndMerge()
    return true
end

-- ===================== Settings helpers =====================

function MyClippings:getOutputDir()
    local custom = self.settings:readSetting("output_dir")
    if custom and custom ~= "" and lfs.attributes(custom, "mode") == "directory" then
        return custom
    end
    local ok, filemanagerutil = pcall(require, "apps/filemanager/filemanagerutil")
    if ok and filemanagerutil.getHomeFolder then
        local home = filemanagerutil.getHomeFolder()
        if home and home ~= "" then return home end
    end
    return Device.home_dir or "/mnt/us"
end

function MyClippings:getFontFamily()
    return self.settings:readSetting("font_family") or "Bookerly, Georgia, serif"
end

function MyClippings:getGroupMode()
    return self.settings:readSetting("group_mode") or "book" -- "book" or "timeline"
end

-- ===================== Persistent DB =====================
-- self.db = { books = { [path] = {title=, author=}, }, items = { {book_path=, page=, pos0=, pos1=, text=, datetime=, chapter=, source=}, ... } }

function MyClippings:loadDB()
    local ok, data = pcall(dofile, self.db_path)
    if ok and type(data) == "table" then
        self.db = data
    else
        self.db = { books = {}, items = {} }
    end
end

function MyClippings:saveDB()
    local f = io.open(self.db_path, "w")
    if not f then
        logger.warn("MyClippings: could not open db for writing:", self.db_path)
        return
    end
    f:write("return {\n  books = {\n")
    for path, b in pairs(self.db.books) do
        f:write(string.format("    [%q] = { title = %q, author = %q },\n", path, b.title or "", b.author or ""))
    end
    f:write("  },\n  items = {\n")
    for _, it in ipairs(self.db.items) do
        f:write(string.format(
            "    { book_path = %q, page = %s, pos0 = %s, pos1 = %s, text = %q, datetime = %q, chapter = %q, source = %q },\n",
            it.book_path or "",
            self:serializeVal(it.page),
            self:serializeVal(it.pos0),
            self:serializeVal(it.pos1),
            it.text or "",
            it.datetime or "",
            it.chapter or "",
            it.source or "koreader"
        ))
    end
    f:write("  },\n}\n")
    f:close()
end

function MyClippings:serializeVal(v)
    if v == nil then return "nil" end
    if type(v) == "number" then return tostring(v) end
    if type(v) == "string" then return string.format("%q", v) end
    return "nil" -- xpointers for rolling docs are strings; pages for paging docs are numbers; anything else we drop
end

-- Shared here (not just in the push-to-books section below) because dedup
-- needs it: strips all punctuation/spacing so "Title: Subtitle" (an epub's
-- own metadata) and "Title Subtitle" (as parsed from Kindle's plain-text
-- Clippings file) compare equal.
local function normalizeTitle(s)
    return (s or ""):lower():gsub("[^%w]", "")
end

-- True if two already-normalized titles should count as the same book:
-- exact match, or one is a prefix of the other. Handles Kindle's Clippings
-- title being the raw "Title Subtitle" run together with no punctuation,
-- while an epub's own metadata title is often just the clean "Title" --
-- an exact-equality check misses that entirely.
local function titlesMatch(na, nb)
    if na == "" or nb == "" then return false end
    if na == nb then return true end
    local shorter, longer = na, nb
    if #na > #nb then shorter, longer = nb, na end
    if #shorter < 6 then return false end -- avoid false positives on tiny titles
    return longer:sub(1, #shorter) == shorter
end

-- Resolves every known book_path to one canonical {title=, author=, key=,
-- norm=} record, grouping paths whose titles match per titlesMatch above.
-- Real (non clippings://) paths are processed first and win as canonical,
-- since that's actual book metadata; a Kindle-Clippings pseudo-path only
-- supplies the title/author when no real path has claimed that group yet.
-- Cheap enough (dozens of books) to just rebuild on demand, no caching.
function MyClippings:buildCanonicalBooks()
    local paths = {}
    for path in pairs(self.db.books) do table.insert(paths, path) end
    table.sort(paths, function(a, b)
        local a_real, b_real = not a:match("^clippings://"), not b:match("^clippings://")
        if a_real ~= b_real then return a_real end
        return a < b
    end)

    local groups = {}
    local path_to_group = {}
    for _, path in ipairs(paths) do
        local book = self.db.books[path]
        local norm = normalizeTitle(book.title)
        local matched
        for _, g in ipairs(groups) do
            if titlesMatch(norm, g.norm) then matched = g break end
        end
        if matched then
            if matched.is_clippings and not path:match("^clippings://") then
                matched.title, matched.author, matched.norm, matched.is_clippings =
                    book.title, book.author, norm, false
            end
            path_to_group[path] = matched
        else
            local g = {
                key = norm, title = book.title, author = book.author, norm = norm,
                is_clippings = path:match("^clippings://") ~= nil,
            }
            table.insert(groups, g)
            path_to_group[path] = g
        end
    end
    return path_to_group
end

-- Keyed on the canonical book's title + exact highlight text, NOT
-- book_path/page/datetime. This matters because the same highlight can
-- legitimately show up under two different book_paths: the
-- Kindle-Clippings pseudo-path ("clippings://...") and, once
-- pushToCurrentBook writes it into a real .sdr, the real epub path too --
-- a later "Pull from KOReader" would otherwise see that real .sdr entry as
-- brand new and double-count it.
function MyClippings:dedupeKey(item)
    local canon = self:buildCanonicalBooks()
    local group = canon[item.book_path]
    local title_key = group and group.key or (item.book_path or "")
    return title_key .. "|" .. (item.text or "")
end

function MyClippings:addItem(item)
    self._seen = self._seen or {}
    if not self._seen_built then
        for _, it in ipairs(self.db.items) do
            self._seen[self:dedupeKey(it)] = true
        end
        self._seen_built = true
    end
    local key = self:dedupeKey(item)
    if self._seen[key] then return false end
    self._seen[key] = true
    table.insert(self.db.items, item)
    return true
end

-- ===================== Live sync: annotation event =====================

function MyClippings:onAnnotationsModified(items)
    if not self.ui or not self.ui.document then return end
    local item = items[1]
    if not item or not item.text then return end -- ignore bookmarks-without-text / removals

    local props = self.ui.doc_props or {}
    local book_path = self.document and self.document.file or (self.ui.document and self.ui.document.file)
    if not book_path then return end

    self.db.books[book_path] = {
        title = props.title or book_path:match("([^/]+)%.%w+$") or book_path,
        author = props.authors or props.author or "",
    }

    local added = self:addItem({
        book_path = book_path,
        page = item.page,
        pos0 = type(item.pos0) == "string" and item.pos0 or nil,
        pos1 = type(item.pos1) == "string" and item.pos1 or nil,
        text = item.text,
        datetime = item.datetime or os.date("%Y-%m-%d %H:%M:%S"),
        chapter = item.chapter or "",
        source = "koreader",
    })

    if added then
        self:saveDB()
        self:scheduleRegen()
    end
end

function MyClippings:scheduleRegen()
    if self._regen_scheduled then
        UIManager:unschedule(self.regenBound)
    end
    self.regenBound = self.regenBound or function() self:regenerateOutputs() end
    self._regen_scheduled = true
    UIManager:scheduleIn(REGEN_DEBOUNCE_SECONDS, self.regenBound)
end

-- ===================== One-time scan & merge =====================

function MyClippings:scanAndMerge()
    local home = self:getOutputDir()
    local count_sdr = self:scanSDR(home)
    local count_clippings = self:scanMyClippings()

    self:saveDB()
    self:regenerateOutputs()

    UIManager:show(InfoMessage:new{
        text = T(_("Highlight scan complete.\nFrom KOReader highlights: %1\nFrom Kindle My Clippings.txt: %2\nTotal unique highlights: %3"),
            count_sdr, count_clippings, #self.db.items),
    })
end

function MyClippings:pullFromKOReader()
    local home = self:getOutputDir()
    local count_sdr = self:scanSDR(home)
    self:saveDB()
    self:regenerateOutputs()
    UIManager:show(InfoMessage:new{
        text = T(_("Pulled %1 new highlight(s) from KOReader.\nTotal unique highlights: %2"), count_sdr, #self.db.items),
    })
end

function MyClippings:pullFromKindle()
    local count_clippings = self:scanMyClippings()
    self:saveDB()
    self:regenerateOutputs()
    UIManager:show(InfoMessage:new{
        text = T(_("Pulled %1 new highlight(s) from Kindle My Clippings.txt.\nTotal unique highlights: %2"), count_clippings, #self.db.items),
    })
end

function MyClippings:scanSDR(root_dir)
    local found = 0
    local function scan_dir(dir, depth)
        if depth > 6 then return end
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok then return end
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." then
                local full = dir .. "/" .. entry
                local mode = lfs.attributes(full, "mode")
                if mode == "directory" then
                    if entry:match("%.sdr$") then
                        found = found + self:scanOneSDR(full)
                    else
                        scan_dir(full, depth + 1)
                    end
                end
            end
        end
    end
    scan_dir(root_dir, 0)
    return found
end

function MyClippings:scanOneSDR(sdr_dir)
    local found = 0
    local ok, iter, dir_obj = pcall(lfs.dir, sdr_dir)
    if not ok then return 0 end
    for entry in iter, dir_obj do
        if entry:match("^metadata%..*%.lua$") then
            local full = sdr_dir .. "/" .. entry
            local dok, data = pcall(dofile, full)
            if dok and type(data) == "table" and data.doc_path and data.annotations and #data.annotations > 0 then
                local props = data.doc_props or {}
                for _, ann in ipairs(data.annotations) do
                    if ann.text and ann.text ~= "" then
                        self.db.books[data.doc_path] = self.db.books[data.doc_path] or {
                            title = props.title or data.doc_path:match("([^/]+)%.%w+$") or data.doc_path,
                            author = props.authors or "",
                        }
                        local added = self:addItem({
                            book_path = data.doc_path,
                            page = ann.page,
                            pos0 = type(ann.pos0) == "string" and ann.pos0 or nil,
                            pos1 = type(ann.pos1) == "string" and ann.pos1 or nil,
                            text = ann.text,
                            datetime = ann.datetime or "",
                            chapter = ann.chapter or "",
                            source = "koreader",
                        })
                        if added then found = found + 1 end
                    end
                end
            end
        end
    end
    return found
end

function MyClippings:scanMyClippings()
    local candidates = { "/mnt/us/documents/My Clippings.txt" }
    local path
    for _, p in ipairs(candidates) do
        if lfs.attributes(p, "mode") == "file" then path = p break end
    end
    if not path then return 0 end

    local f = io.open(path, "r")
    if not f then return 0 end
    local content = f:read("*a")
    f:close()
    -- strip BOM
    content = content:gsub("^\239\187\191", "")

    local found = 0
    for entry in (content .. "\n=========="):gmatch("(.-)\n==========") do
        local lines = {}
        for line in entry:gmatch("[^\n]+") do
            line = line:gsub("\r+$", "")
            if line:match("%S") then table.insert(lines, line) end
        end
        if #lines >= 2 then
            local title_line = lines[1]:gsub("^\239\187\191", "")
            local meta_line = lines[2]
            local text = table.concat(lines, "\n", 3)
            if text and text:match("%S") then
                local title, author = title_line, ""
                local t, a = title_line:match("^(.-)%s*%(([^%(%)]+)%)%s*%(%2%)$")
                if not t then t, a = title_line:match("^(.-)%s*%(([^%(%)]+)%)$") end
                if t then title, author = t, a end
                local page = meta_line:match("page (%S+)")
                local date = meta_line:match("Added on (.+)$")
                local pseudo_path = "clippings://" .. title
                self.db.books[pseudo_path] = { title = title, author = author or "" }
                local added = self:addItem({
                    book_path = pseudo_path,
                    page = page,
                    text = text,
                    datetime = date or "",
                    chapter = "",
                    source = "kindle",
                })
                if added then found = found + 1 end
            end
        end
    end
    return found
end

-- ===================== Push highlights into real book sidecars =====================
-- For highlights we recovered without a real position (e.g. from My Clippings.txt),
-- find the matching book file in the library, search the document for the exact
-- highlighted text, and if found, write a genuine annotation (real xpointer) into
-- that book's own .sdr sidecar -- the same format KOReader itself would write.
-- We never fabricate a position: if the text isn't found verbatim, we skip it.

-- Deliberately excludes azw3/mobi/kfx: proprietary Kindle formats with much
-- shakier KOReader support than these native/well-supported ones, and a
-- likely factor in the DocumentRegistry crashes we hit.
local EBOOK_EXTS = { epub=true, fb2=true, pdf=true, cbz=true, txt=true, html=true, htm=true }
-- normalizeTitle is defined earlier (near dedupeKey), reused here.

function MyClippings:buildTitleIndex(root_dir)
    local index = {}
    local function scan_dir(dir, depth)
        if depth > 6 then return end
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok then return end
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." then
                local full = dir .. "/" .. entry
                local mode = lfs.attributes(full, "mode")
                if mode == "directory" then
                    if not entry:match("%.sdr$") then
                        scan_dir(full, depth + 1)
                    end
                elseif mode == "file" then
                    local ext = entry:match("%.([%w]+)$")
                    if ext and EBOOK_EXTS[ext:lower()] then
                        local base = entry:gsub("%.[%w]+$", "")
                        index[normalizeTitle(base)] = full
                    end
                end
            end
        end
    end
    scan_dir(root_dir, 0)
    return index
end

-- Builds the queue of (real_path -> items) still needing a push, skipping the
-- currently-open book. Kept separate so pushNextBook can call it fresh each
-- time (cheap: just a directory walk + table scan, no documents opened).
function MyClippings:buildPushQueue()
    local home = self:getOutputDir()
    local title_index = self:buildTitleIndex(home)
    local active_path = self.ui and self.ui.document and self.ui.document.file

    local by_real_path = {}
    local order = {}
    local skipped_no_match, skipped_active = 0, 0
    for _, it in ipairs(self.db.items) do
        if not it.pos0 then
            local book = self.db.books[it.book_path] or {}
            local real_path = title_index[normalizeTitle(book.title)]
            if real_path and real_path == active_path then
                skipped_active = skipped_active + 1
            elseif real_path then
                if not by_real_path[real_path] then
                    by_real_path[real_path] = {}
                    table.insert(order, real_path)
                end
                table.insert(by_real_path[real_path], it)
            else
                skipped_no_match = skipped_no_match + 1
            end
        end
    end
    return order, by_real_path, skipped_no_match, skipped_active
end

-- Pushes one book's worth of matched highlights into its real .sdr.
-- Returns pushed_count, not_found_count. Opens/closes/GCs around itself so
-- callers can loop this without accumulating memory across books.
function MyClippings:pushOneBook(DocumentRegistry, DocSettings, real_path, items)
    local pushed, not_found_in_text = 0, 0
    local ok_open, doc = pcall(function() return DocumentRegistry:openDocument(real_path) end)
    if ok_open and doc then
        local ok_settings, settings = pcall(function() return DocSettings:open(real_path) end)
        if ok_settings and settings then
            local annotations = settings:readSetting("annotations") or {}
            for _, it in ipairs(items) do
                local ok_search, results = pcall(function()
                    return doc:findAllText(it.text, false, 0, 1, false)
                end)
                local match = ok_search and results and results[1]
                if match and match.start then
                    table.insert(annotations, {
                        text = it.text,
                        pos0 = match.start,
                        pos1 = match["end"] or match.start,
                        datetime = (it.datetime ~= "" and it.datetime) or os.date("%Y-%m-%d %H:%M:%S"),
                        drawer = "lighten",
                        chapter = it.chapter or "",
                    })
                    it.pos0 = match.start
                    it.pos1 = match["end"] or match.start
                    pushed = pushed + 1
                else
                    not_found_in_text = not_found_in_text + 1
                end
            end
            settings:saveSetting("annotations", annotations)
            pcall(function() settings:flush() end)
        end
        pcall(function() doc:close() end)
    end
    doc = nil
    collectgarbage("collect")
    return pushed, not_found_in_text
end

-- Loops the full push queue one book at a time (memory released between each
-- via pushOneBook's own GC), showing progress through Trapper -- the same
-- abortable "N of M" dialog KOReader's own long-running plugin tasks use.
-- Tapping the progress popup brings up an Abort/Continue choice.
function MyClippings:pushToBooks()
    local ok1, DocumentRegistry = pcall(require, "document/documentregistry")
    local ok2, DocSettings = pcall(require, "docsettings")
    if not ok1 or not ok2 then
        UIManager:show(InfoMessage:new{ text = _("Could not load document APIs.") })
        return
    end

    local order, by_real_path, skipped_no_match, skipped_active = self:buildPushQueue()
    if #order == 0 then
        local msg = _("No highlights need pushing.")
        if skipped_no_match > 0 or skipped_active > 0 then
            msg = msg .. "\n" .. T(_("(No matching book file: %1, currently open: %2)"), skipped_no_match, skipped_active)
        end
        UIManager:show(InfoMessage:new{ text = msg })
        return
    end

    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        Trapper:setPausedText(_("Push interrupted"), _("Abort"), _("Continue"))

        local total_pushed, total_not_found, books_done = 0, 0, 0
        for i, real_path in ipairs(order) do
            local book = self.db.books[by_real_path[real_path][1].book_path] or {}
            local go_on = Trapper:info(T(_("Pushing highlights %1 of %2:\n%3"), i, #order, book.title or real_path))
            if not go_on then break end

            local pushed, not_found = self:pushOneBook(DocumentRegistry, DocSettings, real_path, by_real_path[real_path])
            total_pushed = total_pushed + pushed
            total_not_found = total_not_found + not_found
            books_done = books_done + 1
        end

        self:saveDB()
        Trapper:reset()
        UIManager:show(InfoMessage:new{
            text = T(_("Pushed %1 highlight(s) across %2 book(s).\n%3 not found verbatim.\nSkipped (no matching file): %4\nSkipped (currently open): %5"),
                total_pushed, books_done, total_not_found, skipped_no_match, skipped_active),
        })
    end)
end

-- Safe alternative to pushToBooks: only pushes into the book you currently
-- have open. Uses self.ui.document directly (already fully initialized by
-- the normal reader flow, unlike a bare DocumentRegistry:openDocument) and
-- self.ui.annotation:addItem -- the exact same path a real highlight takes.
-- No headless document opens, no crash risk we've seen so far.
function MyClippings:pushToCurrentBook()
    if not self.ui or not self.ui.document or not self.ui.annotation then
        UIManager:show(InfoMessage:new{ text = _("Open a book first.") })
        return
    end

    local props = self.ui.doc_props or {}
    local current_title = normalizeTitle(props.title)
    if current_title == "" then
        UIManager:show(InfoMessage:new{ text = _("Could not determine this book's title.") })
        return
    end

    local canon = self:buildCanonicalBooks()
    local pending = {}
    for _, it in ipairs(self.db.items) do
        if not it.pos0 then
            local g = canon[it.book_path]
            if g and titlesMatch(current_title, g.norm) then
                table.insert(pending, it)
            end
        end
    end

    if #pending == 0 then
        UIManager:show(InfoMessage:new{ text = _("No pending highlights for this book.") })
        return
    end

    local pushed, not_found = 0, 0
    for _, it in ipairs(pending) do
        local ok_search, results = pcall(function()
            return self.ui.document:findAllText(it.text, false, 0, 1, false)
        end)
        local match = ok_search and results and results[1]
        if match and match.start then
            local ok_add, index = pcall(function()
                return self.ui.annotation:addItem({
                    page = match.start,
                    pos0 = match.start,
                    pos1 = match["end"] or match.start,
                    text = it.text,
                    datetime = (it.datetime ~= "" and it.datetime) or os.date("%Y-%m-%d %H:%M:%S"),
                    drawer = "lighten",
                    chapter = it.chapter or "",
                })
            end)
            if ok_add then
                local real_path = self.ui.document.file
                it.pos0 = match.start
                it.pos1 = match["end"] or match.start
                it.book_path = real_path -- so its jump-link points at the real file, not the clippings:// pseudo-path
                self.db.books[real_path] = self.db.books[real_path] or {
                    title = props.title or real_path:match("([^/]+)%.%w+$") or real_path,
                    author = props.authors or props.author or "",
                }
                pushed = pushed + 1
                pcall(function()
                    self.ui:handleEvent(Event:new("AnnotationsModified",
                        { { page = match.start, pos0 = match.start, text = it.text }, nb_highlights_added = 1, index_modified = index }))
                end)
            else
                not_found = not_found + 1
            end
        else
            not_found = not_found + 1
        end
    end

    if pushed > 0 then
        pcall(function() self.ui.annotation:onSaveSettings() end)
    end

    self:saveDB()
    UIManager:show(InfoMessage:new{
        text = T(_("Pushed %1 highlight(s) into this book (saved to disk).\n%2 not found verbatim in the text."), pushed, not_found),
    })
end

-- ===================== Output generation =====================

-- Removes exact duplicates (same normalized title + same exact text) that
-- ended up in the db from before the dedup key fix, or from any other stray
-- source. When duplicates collide, keeps the one with a real pos0 (already
-- linked to a book) over an unlinked one; otherwise keeps the first seen.
-- Runs automatically before every rebuild, so this stays clean going forward
-- without needing a separate manual step.
function MyClippings:dedupeExistingItems()
    local by_key = {}
    local order = {}
    for _, it in ipairs(self.db.items) do
        local key = self:dedupeKey(it)
        local existing = by_key[key]
        if not existing then
            by_key[key] = it
            table.insert(order, key)
        elseif it.pos0 and not existing.pos0 then
            by_key[key] = it -- prefer the linked one
        end
    end
    local before = #self.db.items
    self.db.items = {}
    for _, key in ipairs(order) do
        table.insert(self.db.items, by_key[key])
    end
    self._seen = nil
    self._seen_built = false
    local removed = before - #self.db.items
    if removed > 0 then
        self:saveDB()
    end
    return removed
end

-- This plugin's own directory (wherever it was installed), so the bundled
-- cover.png can be found regardless of the KOReader install path.
local PLUGIN_DIR = debug.getinfo(1, "S").source:match("@(.*/)") or "./"

-- Sets the bundled cover.png as this output file's custom cover, but only if
-- it doesn't already have one -- so a cover you later pick yourself via
-- bookshelf.koplugin's own cover picker is never overwritten.
function MyClippings:applyDefaultCoverIfMissing(out_path)
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds then return end
    local existing = DocSettings:findCustomCoverFile(out_path)
    if existing then return end
    local cover_path = PLUGIN_DIR .. "cover.png"
    if lfs.attributes(cover_path, "mode") ~= "file" then return end
    local ok_settings, settings = pcall(function() return DocSettings:open(out_path) end)
    if ok_settings and settings then
        pcall(function() settings:flushCustomCover(out_path, cover_path) end)
    end
end

function MyClippings:regenerateOutputs()
    self._regen_scheduled = false
    self:dedupeExistingItems()
    local dir = self:getOutputDir()
    local out_path = dir .. "/My Clippings.html"
    self:writeHTML(out_path)
    self:applyDefaultCoverIfMissing(out_path)
end

local function htmlEscape(s)
    s = s or ""
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function slug(s)
    return (s or ""):lower():gsub("[^a-z0-9]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
end

local function truncateTitle(s, max_len)
    s = s or ""
    max_len = max_len or 40
    if #s <= max_len then return s end
    return s:sub(1, max_len - 1):gsub("%s+%S*$", "") .. "…"
end

local function buildCitation(author, title)
    local t = truncateTitle(title)
    if author and author ~= "" then
        return "— " .. author .. ", " .. t
    end
    return "— " .. t
end

function MyClippings:buildJumpLink(item)
    if not item.pos0 and not item.page then return nil end
    local target = item.pos0 or tostring(item.page)
    -- base64-free simple encoding: path and target separated by a control char sequence,
    -- percent-encoded minimally for the few chars that matter in an href context
    local function enc(s) return (s or ""):gsub("[ %%\"'<>]", function(c) return string.format("%%%02X", c:byte()) end) end
    return string.format("%s://%s|%s", LINK_SCHEME, enc(item.book_path), enc(target))
end

function MyClippings:jumpToLink(link_url)
    local body = link_url:match("^" .. LINK_SCHEME .. "://(.*)$")
    if not body then return end
    local path_enc, target_enc = body:match("^(.-)|(.*)$")
    local function dec(s) return (s or ""):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end) end
    local path, target = dec(path_enc), dec(target_enc)
    if not path or path:match("^clippings://") then
        UIManager:show(InfoMessage:new{ text = _("This highlight came from My Clippings.txt and has no linked book file on this device.") })
        return
    end
    if lfs.attributes(path, "mode") ~= "file" then
        UIManager:show(InfoMessage:new{ text = T(_("Book file not found:\n%1"), path) })
        return
    end
    local ReaderUI = require("apps/reader/readerui")
    local target_num = tonumber(target)
    ReaderUI:showReader(path, nil, false, false, function(ui)
        if not ui then return end
        if target_num and ui.paging then
            ui.paging:onGotoPage(target_num)
        elseif ui.rolling then
            ui.rolling:onGotoXPointer(target)
        end
    end)
end

function MyClippings:writeHTML(out_path)
    local font = self:getFontFamily()
    local mode = self:getGroupMode()

    -- Grouped via the canonical book map (titlesMatch-based, not exact-string
    -- keying): the same book can legitimately show up under the clippings://
    -- pseudo-path for not-yet-pushed items AND the real file path once some
    -- highlights are pushed, with the two sides' titles not even matching
    -- exactly (Kindle's raw "Title Subtitle" vs the epub's clean "Title").
    local canon = self:buildCanonicalBooks()
    local by_book = {}
    local order = {}
    local group_book = {}
    for _, it in ipairs(self.db.items) do
        local g = canon[it.book_path] or { key = it.book_path or "?", title = it.book_path, author = "" }
        if not by_book[g.key] then
            by_book[g.key] = {}
            table.insert(order, g.key)
            group_book[g.key] = g
        end
        table.insert(by_book[g.key], it)
    end

    local html = {}
    local function put(s) table.insert(html, s) end

    put('<!doctype html><html><head><meta charset="utf-8"><title>My Clippings</title><style>')
    put(string.format('body{font-family:%s;width:100%%;margin:0;padding:1em 4%%;line-height:1.5;color:#222;background:#fdfaf5;box-sizing:border-box;column-count:1;-webkit-column-count:1;columns:1;}', font))
    put('h1{font-size:1.6em;border-bottom:2px solid #333;padding-bottom:0.3em;}')
    put('h2{font-size:1.3em;margin-top:2em;color:#5a3e2b;border-bottom:1px solid #ccc;padding-bottom:0.2em;}')
    put('.author{font-size:0.85em;color:#777;font-style:italic;margin-top:-0.5em;margin-bottom:1em;}')
    put('blockquote{margin:1em 0;padding:0.9em 1.1em;border-radius:14px;border:1px solid #ddc9ae;background:#f5efe4;font-style:normal;}')
    put('.citation{font-size:0.7em;color:#a08060;font-style:italic;margin-top:0.4em;}')
    put('.meta{font-size:0.75em;color:#999;margin-top:0.4em;font-style:normal;}')
    put('.meta a{color:#7a5c3e;text-decoration:underline;}')
    put('.chapter{font-size:0.78em;color:#a08060;}')
    put('nav{margin-bottom:2em;}nav a{display:block;margin:0.2em 0;color:#5a3e2b;text-decoration:none;}')
    put('</style></head><body><h1>My Clippings</h1>')

    if mode == "timeline" then
        local flat = {}
        for _, it in ipairs(self.db.items) do table.insert(flat, it) end
        table.sort(flat, function(a, b) return (a.datetime or "") > (b.datetime or "") end)
        for _, it in ipairs(flat) do
            local book = canon[it.book_path] or self.db.books[it.book_path] or {}
            local link = self:buildJumpLink(it)
            put('<blockquote>&ldquo;' .. htmlEscape(it.text) .. '&rdquo;')
            put('<div class="citation">' .. htmlEscape(buildCitation(book.author, book.title)) .. '</div>')
            put('<div class="meta">' .. htmlEscape(book.title or "") ..
                (it.chapter ~= "" and (' &middot; <span class="chapter">' .. htmlEscape(it.chapter) .. '</span>') or "") ..
                ' &middot; ' .. htmlEscape(it.datetime or ""))
            if link then
                put(' &middot; <a href="' .. link .. '">p.' .. htmlEscape(tostring(it.page or "")) .. '</a>')
            end
            put('</div></blockquote>')
        end
    else
        put('<nav>')
        for _, key in ipairs(order) do
            local book = group_book[key] or {}
            put('<a href="#' .. slug(book.title) .. '">' .. htmlEscape(book.title or key) .. '</a>')
        end
        put('</nav>')
        for _, key in ipairs(order) do
            local book = group_book[key] or {}
            put('<h2 id="' .. slug(book.title) .. '">' .. htmlEscape(book.title or key) .. '</h2>')
            if book.author and book.author ~= "" then
                put('<div class="author">' .. htmlEscape(book.author) .. '</div>')
            end
            for _, it in ipairs(by_book[key]) do
                local link = self:buildJumpLink(it)
                put('<blockquote>&ldquo;' .. htmlEscape(it.text) .. '&rdquo;')
                put('<div class="citation">' .. htmlEscape(buildCitation(book.author, book.title)) .. '</div>')
                put('<div class="meta">' ..
                    (it.chapter ~= "" and ('<span class="chapter">' .. htmlEscape(it.chapter) .. '</span> &middot; ') or "") ..
                    htmlEscape(it.datetime or ""))
                if link then
                    put(' &middot; <a href="' .. link .. '">p.' .. htmlEscape(tostring(it.page or "")) .. '</a>')
                end
                    put('</div></blockquote>')
            end
        end
    end

    put('</body></html>')

    local f = io.open(out_path, "w")
    if not f then
        logger.warn("MyClippings: could not write output:", out_path)
        return
    end
    f:write(table.concat(html, "\n"))
    f:close()
end

-- ===================== Menu =====================

function MyClippings:addToMainMenu(menu_items)
    menu_items.myclippings = {
        text = _("My Clippings Highlight Sync"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Pull highlights from KOReader"),
                keep_menu_open = true,
                callback = function() self:pullFromKOReader() end,
            },
            {
                text = _("Pull highlights from Kindle (My Clippings)"),
                keep_menu_open = true,
                callback = function() self:pullFromKindle() end,
            },
            {
                text = _("Pull and merge highlights from all sources (tries all pulls then merges)"),
                keep_menu_open = true,
                callback = function() self:scanAndMerge() end,
            },
            {
                text = _("Push pending highlights to open book (must have a book open)"),
                keep_menu_open = true,
                callback = function() self:pushToCurrentBook() end,
            },
            {
                text = _("Rebuild highlights file now"),
                keep_menu_open = true,
                callback = function()
                    self:regenerateOutputs()
                    UIManager:show(InfoMessage:new{ text = _("Highlights file rebuilt."), timeout = 2 })
                end,
            },
            {
                text_func = function()
                    return T(_("Group by: %1"), self:getGroupMode() == "timeline" and _("Timeline") or _("Book"))
                end,
                keep_menu_open = true,
                callback = function()
                    local new_mode = self:getGroupMode() == "timeline" and "book" or "timeline"
                    self.settings:saveSetting("group_mode", new_mode)
                    self.settings:flush()
                    self:regenerateOutputs()
                end,
            },
            {
                text_func = function()
                    local f = self:getFontFamily()
                    return T(_("Font: %1"), f:match("^[^,]+"))
                end,
                sub_item_table = {
                    { text = "Bookerly", callback = function() self:setFont("Bookerly, Georgia, serif") end },
                    { text = "Georgia", callback = function() self:setFont("Georgia, serif") end },
                    { text = "PT Serif", callback = function() self:setFont("'PT Serif', Georgia, serif") end },
                    { text = "Sans-serif", callback = function() self:setFont("sans-serif") end },
                },
            },
            {
                text = _("Set custom output folder..."),
                keep_menu_open = true,
                callback = function() self:promptOutputFolder() end,
            },
            {
                text = _("Use default home folder for output"),
                keep_menu_open = true,
                callback = function()
                    self.settings:saveSetting("output_dir", nil)
                    self.settings:flush()
                    UIManager:show(InfoMessage:new{ text = _("Output folder reset to home folder."), timeout = 2 })
                end,
            },
        },
    }
end

function MyClippings:setFont(font)
    self.settings:saveSetting("font_family", font)
    self.settings:flush()
    self:regenerateOutputs()
end

function MyClippings:promptOutputFolder()
    local ok, PathChooser = pcall(require, "ui/widget/pathchooser")
    if not ok then return end
    local chooser = PathChooser:new{
        path = self:getOutputDir(),
        select_directory = true,
        select_file = false,
        onConfirm = function(path)
            self.settings:saveSetting("output_dir", path)
            self.settings:flush()
            self:regenerateOutputs()
        end,
    }
    UIManager:show(chooser)
end

return MyClippings
