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

-- findAllText's search_flags (added in KOReader 2026.07, koreader#15543):
-- passing MATCH_ACROSS_TEXT_NODES (0x0001) does let a search match text
-- spanning an inline tag like <i> (which otherwise silently fails to find
-- any highlight containing italicized text). First two attempts reproduced
-- a KOReader crash on the next page turn after a push that used it
-- (getPageFromXPointer got a nil xpointer from somewhere in the annotation
-- list), but that book had several stale push sessions and edited
-- highlights accumulated from earlier testing -- confounding the test.
-- Re-enabled for a clean re-test on a book with a freshly wiped, from-
-- scratch annotation list. If it crashes again on a clean book, revert to
-- the plain 5-arg call (drop ", FINDALL_SEARCH_FLAGS" from both call sites
-- below) and treat it as a real, reproducible incompatibility.
local FINDALL_SEARCH_FLAGS = 0x00FF

-- Forward declarations: defined further down (near mergeOverlappingHighlights),
-- but also needed by pushToCurrentBook, which comes earlier in the file.
local normText, levenshtein, textsOverlap, sourcesQualifyForMerge

local KINDLE_MONTHS = {
    January = 1, February = 2, March = 3, April = 4, May = 5, June = 6,
    July = 7, August = 8, September = 9, October = 10, November = 11, December = 12,
}

-- Kindle's clippings datetime ("Tuesday, August 4, 2026 12:52:19 AM") is
-- NOT chronologically sortable as a plain string -- weekday/month names and
-- unpadded numbers make lexicographic comparison meaningless. This converts
-- it (when recognized) to a zero-padded "YYYY-MM-DD HH:MM:SS" key that
-- sorts correctly; KOReader's own already-ISO-ish datetime passes through
-- unchanged (it's sortable as-is), and anything unparseable falls back to
-- the raw string rather than erroring.
local function datetimeSortKey(s)
    s = s or ""
    local month, day, year, hour, min, sec, ampm =
        s:match("%a+,%s*(%a+)%s+(%d+),%s+(%d+)%s+(%d+):(%d+):(%d+)%s*(%a*)")
    if month and KINDLE_MONTHS[month] then
        hour = tonumber(hour)
        local upper_ampm = ampm:upper()
        if upper_ampm == "PM" and hour < 12 then hour = hour + 12 end
        if upper_ampm == "AM" and hour == 12 then hour = 0 end
        return string.format("%04d-%02d-%02d %02d:%02d:%02d",
            tonumber(year), KINDLE_MONTHS[month], tonumber(day), hour, tonumber(min), tonumber(sec))
    end
    return s
end

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

function MyClippings:getMergeSourceFilter()
    return self.settings:readSetting("merge_source_filter") or "all" -- "kindle", "koreader", or "all"
end

function MyClippings:getMergeMaxDiffPercent()
    return self.settings:readSetting("merge_max_diff_percent") or 8
end

function MyClippings:getExcludedFolders()
    return self.settings:readSetting("excluded_folders") or {}
end

function MyClippings:addExcludedFolder(path)
    path = path:gsub("/+$", "") -- normalize away a trailing slash
    if path == "" then return end
    local excluded = self:getExcludedFolders()
    for _, p in ipairs(excluded) do
        if p == path then return end -- already excluded
    end
    table.insert(excluded, path)
    self.settings:saveSetting("excluded_folders", excluded)
    self.settings:flush()
end

function MyClippings:removeExcludedFolder(path)
    local excluded = self:getExcludedFolders()
    for i, p in ipairs(excluded) do
        if p == path then
            table.remove(excluded, i)
            break
        end
    end
    self.settings:saveSetting("excluded_folders", excluded)
    self.settings:flush()
end

-- True if book_path is inside (or is) one of the excluded folders.
function MyClippings:isPathExcluded(path)
    if not path then return false end
    for _, folder in ipairs(self:getExcludedFolders()) do
        if path == folder or path:sub(1, #folder + 1) == folder .. "/" then
            return true
        end
    end
    return false
end

-- Removes any already-ingested highlights/books whose path now falls under
-- an excluded folder -- exclusion only stops future scans/live sync, so
-- this is needed to actually clear out what's already in the db.
function MyClippings:purgeExcludedItems()
    local kept = {}
    for _, it in ipairs(self.db.items) do
        if not self:isPathExcluded(it.book_path) then
            table.insert(kept, it)
        end
    end
    local removed = #self.db.items - #kept
    self.db.items = kept
    for path in pairs(self.db.books) do
        if self:isPathExcluded(path) then
            self.db.books[path] = nil
        end
    end
    if removed > 0 then
        self._seen = nil
        self._seen_built = false
        self._koreader_id_index = nil
        self._koreader_id_built = false
        self:saveDB()
    end
    return removed
end

-- ===================== Persistent DB =====================
-- self.db = { books = { [path] = {title=, author=}, }, items = { {book_path=, page=, location=, pos0=, pos1=, text=, note=, datetime=, chapter=, source=, is_note=}, ... } }
-- is_note: true for a Kindle "Your Note" entry that couldn't be attached to
-- a highlight (see scanMyClippings) -- text is the note's own content, not
-- a quote from the book, and is rendered without quote-mark styling.

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
            "    { book_path = %q, page = %s, location = %s, pos0 = %s, pos1 = %s, text = %q, note = %q, datetime = %q, chapter = %q, source = %q, is_note = %s },\n",
            it.book_path or "",
            self:serializeVal(it.page),
            self:serializeVal(it.location),
            self:serializeVal(it.pos0),
            self:serializeVal(it.pos1),
            it.text or "",
            it.note or "",
            it.datetime or "",
            it.chapter or "",
            it.source or "koreader",
            it.is_note and "true" or "false"
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

-- KOReader keeps a highlight's creation datetime stable across edits (only
-- its text/pos0/pos1 change when you resize the selection), so book +
-- datetime is a stable identity for "this is the same highlight, possibly
-- edited" -- unlike dedupeKey, which is keyed on the text itself and so
-- treats every edit as a brand new highlight.
function MyClippings:koreaderEditKey(item)
    local canon = self:buildCanonicalBooks()
    local group = canon[item.book_path]
    local title_key = group and group.key or (item.book_path or "")
    return title_key .. "|" .. (item.datetime or "")
end

function MyClippings:addItem(item)
    if item.source == "koreader" and item.datetime and item.datetime ~= "" then
        self._koreader_id_index = self._koreader_id_index or {}
        if not self._koreader_id_built then
            for i, it in ipairs(self.db.items) do
                if it.source == "koreader" and it.datetime and it.datetime ~= "" then
                    self._koreader_id_index[self:koreaderEditKey(it)] = i
                end
            end
            self._koreader_id_built = true
        end
        local id = self:koreaderEditKey(item)
        local existing_idx = self._koreader_id_index[id]
        local existing = existing_idx and self.db.items[existing_idx]
        if existing then
            local changed = existing.text ~= item.text or existing.pos0 ~= item.pos0 or existing.pos1 ~= item.pos1
                or existing.note ~= item.note
            for k, v in pairs(item) do existing[k] = v end
            if changed then self._seen_built = false end -- text changed, exact-match dedup cache is now stale
            return changed
        end
        table.insert(self.db.items, item)
        self._koreader_id_index[id] = #self.db.items
        self._seen_built = false
        return true
    end

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

-- One-time cleanup for highlights that were already duplicated by the
-- edit-tracking bug above (each edit of a KOReader highlight appended a
-- new entry instead of updating in place). Keeps the last entry for each
-- (book, datetime) id, since later pulls saw the highlight's most recent
-- text at the time they ran.
function MyClippings:dedupeKoreaderEditsById()
    local last_by_id = {}
    local order = {}
    for _, it in ipairs(self.db.items) do
        if it.source == "koreader" and it.datetime and it.datetime ~= "" then
            local id = self:koreaderEditKey(it)
            if not last_by_id[id] then table.insert(order, id) end
            last_by_id[id] = it
        end
    end
    local kept = {}
    local placed = {}
    for _, it in ipairs(self.db.items) do
        if it.source == "koreader" and it.datetime and it.datetime ~= "" then
            local id = self:koreaderEditKey(it)
            if not placed[id] then
                placed[id] = true
                table.insert(kept, last_by_id[id])
            end
        else
            table.insert(kept, it)
        end
    end
    local removed = #self.db.items - #kept
    if removed > 0 then
        self.db.items = kept
        self._seen = nil
        self._seen_built = false
        self._koreader_id_index = nil
        self._koreader_id_built = false
        self:saveDB()
    end
    return removed
end

-- Retroactively re-attaches a standalone Kindle note (see scanMyClippings)
-- to its highlight, for cases the live parse couldn't handle: the highlight
-- was already in the db (so addItem silently skipped it as a duplicate and
-- the in-memory "last highlight" tracking never got set), leaving a note
-- edit stranded as its own item instead of overwriting the original note.
-- Groups Kindle-sourced items in the same book by page/location: the
-- earliest highlight in a group is the parent, the latest note is the
-- corrected version (Kindle's export is append-only, so later = newer
-- edit), and every standalone note in the group gets folded into it.
function MyClippings:mergeStandaloneNotesIntoHighlights()
    local canon = self:buildCanonicalBooks()
    local groups = {}
    for _, it in ipairs(self.db.items) do
        if it.source == "kindle" then
            local g = canon[it.book_path]
            local bookkey = g and g.key or (it.book_path or "?")
            local poskey = it.page or it.location
            if poskey and poskey ~= "" then
                local key = bookkey .. "|" .. poskey
                groups[key] = groups[key] or { highlights = {}, notes = {} }
                if it.is_note then
                    table.insert(groups[key].notes, it)
                else
                    table.insert(groups[key].highlights, it)
                end
            end
        end
    end

    local to_remove = {}
    for _, g in pairs(groups) do
        if #g.highlights > 0 and #g.notes > 0 then
            table.sort(g.highlights, function(a, b) return datetimeSortKey(a.datetime) < datetimeSortKey(b.datetime) end)
            local parent = g.highlights[1]
            table.sort(g.notes, function(a, b) return datetimeSortKey(a.datetime) < datetimeSortKey(b.datetime) end)
            parent.note = g.notes[#g.notes].text
            for _, n in ipairs(g.notes) do
                to_remove[n] = true
            end
        end
    end

    if next(to_remove) == nil then return 0 end
    local kept = {}
    for _, it in ipairs(self.db.items) do
        if not to_remove[it] then table.insert(kept, it) end
    end
    local removed = #self.db.items - #kept
    self.db.items = kept
    self._seen = nil
    self._seen_built = false
    self._koreader_id_index = nil
    self._koreader_id_built = false
    self:saveDB()
    return removed
end

-- ===================== Live sync: annotation event =====================

function MyClippings:onAnnotationsModified(items)
    if not self.ui or not self.ui.document then return end
    local item = items[1]
    if not item or not item.text then return end -- ignore bookmarks-without-text / removals

    local props = self.ui.doc_props or {}
    local book_path = self.document and self.document.file or (self.ui.document and self.ui.document.file)
    if not book_path then return end
    if self:isPathExcluded(book_path) then return end

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
        note = item.note or "",
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
    local count_clippings, count_notes = self:scanMyClippings()

    self:saveDB()
    self:regenerateOutputs()

    UIManager:show(InfoMessage:new{
        text = T(_("Highlight scan complete.\nFrom KOReader highlights: %1\nFrom Kindle My Clippings.txt: %2 (%3 note(s))\nTotal unique highlights: %4"),
            count_sdr, count_clippings, count_notes, #self.db.items),
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
    local count_clippings, count_notes = self:scanMyClippings()
    self:saveDB()
    self:regenerateOutputs()
    UIManager:show(InfoMessage:new{
        text = T(_("Pulled %1 new highlight(s) from Kindle My Clippings.txt (%2 note(s)).\nTotal unique highlights: %3"), count_clippings, count_notes, #self.db.items),
    })
end

function MyClippings:scanSDR(root_dir)
    local found = 0
    local function scan_dir(dir, depth)
        if depth > 6 then return end
        if self:isPathExcluded(dir) then return end
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
                            note = ann.note or "",
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
    local notes_found = 0 -- Note entries seen, whether attached to a highlight or standalone
    -- Kindle writes a "Your Note" entry right after the "Your Highlight" it
    -- was made on, both from the same title -- tracked here so a Note gets
    -- attached to that highlight instead of showing up as its own quote.
    local last_highlight_by_book = {}
    for entry in (content .. "\n=========="):gmatch("(.-)\n==========") do
        local lines = {}
        for line in entry:gmatch("[^\n]+") do
            line = line:gsub("\r+$", "")
            if line:match("%S") then table.insert(lines, line) end
        end
        if #lines >= 2 then
            local title_line = lines[1]:gsub("^\239\187\191", "")
            local meta_line = lines[2]
            -- Kindle word-wraps a long highlight across multiple lines in
            -- the plain-text export -- that's just its own line-wrapping,
            -- not a real paragraph break in the book, so join with a space
            -- (not "\n") or findAllText below will never match the actual
            -- book text against an embedded newline that doesn't exist there.
            local text = table.concat(lines, " ", 3)
            if text and text:match("%S") then
                local title, author = title_line, ""
                local t, a = title_line:match("^(.-)%s*%(([^%(%)]+)%)%s*%(%2%)$")
                if not t then t, a = title_line:match("^(.-)%s*%(([^%(%)]+)%)$") end
                if t then title, author = t, a end
                local page = meta_line:match("page (%S+)")
                local location = meta_line:match("Location (%S+)")
                local date = meta_line:match("Added on (.+)$")
                local pseudo_path = "clippings://" .. title
                self.db.books[pseudo_path] = { title = title, author = author or "" }

                -- meta_line reads e.g. "- Your Highlight on page 5 | Added on ..."
                -- / "- Your Note on page 5 | ..." / "- Your Bookmark on page 5 | ...".
                local entry_type = meta_line:match("Your (%a+)") or "Highlight"

                if entry_type == "Bookmark" then
                    -- not a highlight and not a note on one; nothing to keep
                elseif entry_type == "Note" then
                    local target = last_highlight_by_book[pseudo_path]
                    if target then
                        -- Kindle's export is append-only: editing a note
                        -- doesn't rewrite its old entry, it appends a new
                        -- one later in the file. So a later Note for the
                        -- same highlight is an edit of the earlier one, not
                        -- a second note -- overwrite, don't duplicate.
                        target.note = text
                        notes_found = notes_found + 1
                    else
                        local added = self:addItem({
                            book_path = pseudo_path,
                            page = page,
                            location = location,
                            text = text,
                            note = "",
                            datetime = date or "",
                            chapter = "",
                            source = "kindle",
                            is_note = true,
                        })
                        if added then
                            found = found + 1
                            notes_found = notes_found + 1
                        end
                    end
                else -- "Highlight" (or an unrecognized type -- treat as a highlight, the old behavior)
                    local item = {
                        book_path = pseudo_path,
                        page = page,
                        location = location,
                        text = text,
                        note = "",
                        datetime = date or "",
                        chapter = "",
                        source = "kindle",
                    }
                    local added = self:addItem(item)
                    if added then
                        found = found + 1
                        last_highlight_by_book[pseudo_path] = item
                    end
                end
            end
        end
    end
    return found, notes_found
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
                    return doc:findAllText(it.text, false, 0, 1, false, FINDALL_SEARCH_FLAGS)
                end)
                local match = ok_search and results and results[1]
                if match and type(match.start) == "string" then
                    table.insert(annotations, {
                        text = it.text,
                        pos0 = match.start,
                        pos1 = type(match["end"]) == "string" and match["end"] or match.start,
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
-- Being a non-empty string isn't enough to trust an xpointer: with
-- MATCH_ACROSS_TEXT_NODES enabled, findAllText can return a match spanning
-- multiple text nodes whose start position is a syntactically valid string
-- that still doesn't resolve to a real page. ReaderAnnotation:addItem()
-- calls getPageFromXPointer() on it internally and silently accepts nil,
-- leaving a highlight with page=nil in the .sdr -- which doesn't crash
-- until later (turning a page, or opening the Bookmarks list). Calling the
-- same resolution ourselves first and rejecting anything that doesn't
-- resolve closes that off before it's ever written.
function MyClippings:xpointerResolvesToPage(xpointer)
    local ok, page = pcall(function()
        return self.ui.document:getPageFromXPointer(xpointer)
    end)
    return ok and page ~= nil
end

function MyClippings:pushToCurrentBook()
    if not self.ui or not self.ui.document or not self.ui.annotation then
        UIManager:show(InfoMessage:new{ text = _("Open a book first.") })
        return
    end
    if not self.ui.rolling then
        -- Everything here (findAllText, getPageFromXPointer, xpointer
        -- strings as positions) is built around reflowable/rolling
        -- documents (EPUB, FB2, HTML, TXT) via crengine. A paging document
        -- (PDF, CBZ, DjVu) uses a completely different backend (mupdf) and
        -- position model that's never been tested with this feature, and a
        -- user reported a book becoming unopenable ("No reader engine for
        -- this file or invalid file") after pushing to it -- plausibly
        -- exactly this mismatch. Refuse rather than risk it.
        UIManager:show(InfoMessage:new{
            text = _("Pushing highlights isn't supported for this document type (only reflowable formats like EPUB, FB2, HTML, and TXT)."),
        })
        return
    end

    local props = self.ui.doc_props or {}
    local current_title = normalizeTitle(props.title)
    if current_title == "" then
        UIManager:show(InfoMessage:new{ text = _("Could not determine this book's title.") })
        return
    end

    -- Clean up first, so "pending" reflects merged/deduped state rather
    -- than pushing near-duplicate Kindle re-captures as separate
    -- highlights into the book.
    self:fixEmbeddedNewlines()
    self:dedupeExistingItems()
    self:dedupeKoreaderEditsById()
    self:mergeStandaloneNotesIntoHighlights()
    self:mergeOverlappingHighlights(self:getMergeSourceFilter(), self:getMergeMaxDiffPercent() / 100)

    local canon = self:buildCanonicalBooks()
    local pending = {}
    for _, it in ipairs(self.db.items) do
        if not it.pos0 and not it.is_note then
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

    -- Existing native highlights already in this book -- pushing a
    -- Kindle-Clippings item that overlaps one of these would create a
    -- second, duplicate highlight box on top of a highlight you already
    -- have, so those are matched against and linked instead of re-added.
    local max_diff_ratio = self:getMergeMaxDiffPercent() / 100
    local existing_annotations = (self.ui.annotation and self.ui.annotation.annotations) or {}

    local pushed, matched_existing, not_found = 0, 0, 0
    local existing_mutated = false
    for _, it in ipairs(pending) do
        local already = nil
        for _, ann in ipairs(existing_annotations) do
            if ann.text and type(ann.pos0) == "string" and self:xpointerResolvesToPage(ann.pos0)
                and textsOverlap(ann.text, it.text, max_diff_ratio) then
                already = ann
                break
            end
        end

        if already then
            local real_path = self.ui.document.file
            it.pos0 = already.pos0
            it.pos1 = type(already.pos1) == "string" and already.pos1 or already.pos0
            it.page = already.pos0
            it.book_path = real_path
            self.db.books[real_path] = self.db.books[real_path] or {
                title = props.title or real_path:match("([^/]+)%.%w+$") or real_path,
                author = props.authors or props.author or "",
            }
            -- Carry the Kindle note over onto the real annotation too, if it
            -- doesn't already have one of its own.
            if it.note and it.note ~= "" and (not already.note or already.note == "") then
                already.note = it.note
                existing_mutated = true
            end
            matched_existing = matched_existing + 1
        else
            local ok_search, results = pcall(function()
                return self.ui.document:findAllText(it.text, false, 0, 1, false, FINDALL_SEARCH_FLAGS)
            end)
            local match = ok_search and results and results[1]
            -- Validate the match is a real xpointer string, not just
            -- truthy: with MATCH_ACROSS_TEXT_NODES enabled, a hit spanning
            -- multiple text nodes isn't guaranteed to come back as one --
            -- an annotation with a malformed pos0 doesn't fail loudly here,
            -- it crashes later (e.g. turning a page triggers KOReader's own
            -- bookmark-dogear code to compare positions and choke on it).
            if match and type(match.start) == "string" and self:xpointerResolvesToPage(match.start) then
                local pos1 = type(match["end"]) == "string" and match["end"] or match.start
                local ok_add, index = pcall(function()
                    return self.ui.annotation:addItem({
                        page = match.start,
                        pos0 = match.start,
                        pos1 = pos1,
                        text = it.text,
                        note = it.note or "",
                        datetime = (it.datetime ~= "" and it.datetime) or os.date("%Y-%m-%d %H:%M:%S"),
                        drawer = "lighten",
                        chapter = it.chapter or "",
                    })
                end)
                if ok_add then
                    local real_path = self.ui.document.file
                    it.pos0 = match.start
                    it.pos1 = pos1
                    it.book_path = real_path -- so its jump-link points at the real file, not the clippings:// pseudo-path
                    self.db.books[real_path] = self.db.books[real_path] or {
                        title = props.title or real_path:match("([^/]+)%.%w+$") or real_path,
                        author = props.authors or props.author or "",
                    }
                    pushed = pushed + 1
                    -- Track this new annotation so a later duplicate in the
                    -- same pending batch also matches against it, not just
                    -- what existed on disk before this push started.
                    table.insert(existing_annotations, { text = it.text, pos0 = it.pos0, pos1 = it.pos1, note = it.note })
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
    end

    if pushed > 0 or existing_mutated then
        pcall(function() self.ui.annotation:onSaveSettings() end)
    end

    self:mergeOverlappingHighlights(self:getMergeSourceFilter(), max_diff_ratio)
    self:saveDB()
    local msg = T(_("Pushed %1 new highlight(s) into this book (saved to disk).\n%2 already matched an existing highlight and were linked instead of duplicated.\n%3 not found verbatim in the text."), pushed, matched_existing, not_found)
    if pushed > 0 or matched_existing > 0 then
        msg = msg .. "\n\n" .. _("A known KOReader issue can crash the app on the next page turn right after annotations change. Please fully close and reopen KOReader now, before continuing to read.")
    end
    UIManager:show(InfoMessage:new{ text = msg })
end

-- Removes, from the currently open book's real annotations, only the ones
-- this plugin itself pushed there (identified by matching pos0 against our
-- own db) -- leaves any highlight you made natively in the book alone.
-- Unlinks the corresponding db items back to "pending" so they can be
-- pushed again later. Uses the same self.ui.annotation API pushing does,
-- so KOReader itself handles the on-disk .sdr write correctly.
-- Recreates highlights the db already has a real (already-linked) position
-- for, but which are missing from this book's actual annotation list --
-- e.g. after a .sdr got deleted/replaced outside the plugin, or a book file
-- got swapped for a fresh copy. Uses the stored pos0/pos1 directly (no
-- findAllText search needed, since we already trust that position), via
-- the same annotation:addItem() API used everywhere else here.
function MyClippings:restoreKnownHighlightsInCurrentBook()
    if not self.ui or not self.ui.document or not self.ui.annotation then
        UIManager:show(InfoMessage:new{ text = _("Open a book first.") })
        return
    end
    if not self.ui.rolling then
        UIManager:show(InfoMessage:new{
            text = _("Restoring highlights isn't supported for this document type (only reflowable formats like EPUB, FB2, HTML, and TXT)."),
        })
        return
    end
    local real_path = self.ui.document.file

    local existing_pos0 = {}
    for _, ann in ipairs(self.ui.annotation.annotations) do
        if type(ann.pos0) == "string" then existing_pos0[ann.pos0] = true end
    end

    local restored, skipped, already_present, unresolvable = 0, 0, 0, 0
    for _, it in ipairs(self.db.items) do
        if it.book_path == real_path and type(it.pos0) == "string" and it.pos0 ~= "" then
          if not self:xpointerResolvesToPage(it.pos0) then
            unresolvable = unresolvable + 1
          elseif existing_pos0[it.pos0] then
            already_present = already_present + 1
          else
            local ok_add = pcall(function()
                self.ui.annotation:addItem({
                    page = it.pos0,
                    pos0 = it.pos0,
                    pos1 = type(it.pos1) == "string" and it.pos1 or it.pos0,
                    text = it.text,
                    note = it.note or "",
                    datetime = (it.datetime ~= "" and it.datetime) or os.date("%Y-%m-%d %H:%M:%S"),
                    drawer = "lighten",
                    chapter = it.chapter or "",
                })
            end)
            if ok_add then
                restored = restored + 1
                existing_pos0[it.pos0] = true
            else
                skipped = skipped + 1
            end
          end
        end
    end

    if restored > 0 then
        pcall(function() self.ui.annotation:onSaveSettings() end)
    end

    local msg = T(_("Restored %1 highlight(s) already known to the database.\n%2 already present in this book.\n%3 failed to restore.\n%4 skipped (position no longer resolves in this book)."), restored, already_present, skipped, unresolvable)
    if restored > 0 then
        msg = msg .. "\n\n" .. _("A known KOReader issue can crash the app on the next page turn right after annotations change. Please fully close and reopen KOReader now, before continuing to read.")
    end
    UIManager:show(InfoMessage:new{ text = msg })
end

function MyClippings:unpushFromCurrentBook()
    if not self.ui or not self.ui.document or not self.ui.annotation then
        UIManager:show(InfoMessage:new{ text = _("Open a book first.") })
        return
    end
    local real_path = self.ui.document.file

    local pushed_pos0 = {}
    for _, it in ipairs(self.db.items) do
        if it.source == "kindle" and it.book_path == real_path and it.pos0 then
            pushed_pos0[it.pos0] = true
        end
    end
    if next(pushed_pos0) == nil then
        UIManager:show(InfoMessage:new{ text = _("No pushed highlights found for this book.") })
        return
    end

    local annotations = self.ui.annotation.annotations
    local removed = 0
    for i = #annotations, 1, -1 do
        if pushed_pos0[annotations[i].pos0] then
            table.remove(annotations, i)
            removed = removed + 1
        end
    end
    if removed > 0 then
        pcall(function() self.ui.annotation:onSaveSettings() end)
    end

    local canon = self:buildCanonicalBooks()
    local pseudo_path
    local g = canon[real_path]
    if g then
        for path, book in pairs(self.db.books) do
            if path:match("^clippings://") and titlesMatch(normalizeTitle(book.title), g.norm) then
                pseudo_path = path
                break
            end
        end
    end

    local unlinked = 0
    for _, it in ipairs(self.db.items) do
        if it.source == "kindle" and it.book_path == real_path and pushed_pos0[it.pos0] then
            it.pos0 = nil
            it.pos1 = nil
            it.page = nil
            if pseudo_path then it.book_path = pseudo_path end
            unlinked = unlinked + 1
        end
    end
    self._seen = nil
    self._seen_built = false
    self._koreader_id_index = nil
    self._koreader_id_built = false
    self:saveDB()

    UIManager:show(InfoMessage:new{
        text = T(_("Removed %1 pushed highlight(s) from this book and unlinked %2 db item(s) back to pending."), removed, unlinked),
    })
end

-- Wipes EVERY annotation in the currently open book -- native highlights
-- included, not just ones this plugin pushed. Only reachable from a
-- dedicated menu item with a confirmation dialog; there's no scoped
-- undo for this one. Unlinks every Kindle-sourced db item pointing at this
-- book back to pending, so a fresh Pull+Push can repopulate it from
-- My Clippings.txt.
function MyClippings:clearAllAnnotationsInCurrentBook()
    if not self.ui or not self.ui.document or not self.ui.annotation then
        UIManager:show(InfoMessage:new{ text = _("Open a book first.") })
        return
    end
    local real_path = self.ui.document.file
    local count = #self.ui.annotation.annotations

    for i = #self.ui.annotation.annotations, 1, -1 do
        table.remove(self.ui.annotation.annotations, i)
    end
    pcall(function() self.ui.annotation:onSaveSettings() end)

    local canon = self:buildCanonicalBooks()
    local pseudo_path
    local g = canon[real_path]
    if g then
        for path, book in pairs(self.db.books) do
            if path:match("^clippings://") and titlesMatch(normalizeTitle(book.title), g.norm) then
                pseudo_path = path
                break
            end
        end
    end

    local unlinked = 0
    for _, it in ipairs(self.db.items) do
        if it.source == "kindle" and it.book_path == real_path then
            it.pos0 = nil
            it.pos1 = nil
            it.page = nil
            if pseudo_path then it.book_path = pseudo_path end
            unlinked = unlinked + 1
        end
    end
    self._seen = nil
    self._seen_built = false
    self._koreader_id_index = nil
    self._koreader_id_built = false
    self:saveDB()

    UIManager:show(InfoMessage:new{
        text = T(_("Cleared %1 annotation(s) from this book and unlinked %2 db item(s) back to pending."), count, unlinked),
    })
end

function MyClippings:confirmClearAllAnnotationsInCurrentBook()
    if not self.ui or not self.ui.document then
        UIManager:show(InfoMessage:new{ text = _("Open a book first.") })
        return
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Delete ALL highlights in this book -- including any you made natively, not just pushed ones? This can't be undone from here; Kindle-sourced ones can be re-pushed afterward."),
        ok_text = _("Delete all"),
        ok_callback = function() self:clearAllAnnotationsInCurrentBook() end,
    })
end

-- Collapses overlapping highlights that already exist as real annotations
-- in the currently open book (e.g. from before pushToCurrentBook started
-- checking for existing matches, or from re-highlighting the same passage
-- natively in KOReader more than once). Unlike mergeOverlappingHighlights,
-- this edits the book's actual annotation list via the same
-- ReaderHighlight:deleteHighlight() KOReader's own highlight-delete menu
-- uses, so the extra highlight boxes actually disappear from the book, not
-- just from the consolidated file. Source-blind: once pushed, a highlight
-- has no record of whether it came from Kindle or KOReader, so this
-- compares every pair by text overlap only.
-- Self-service fix for a v1.0.3 bug: pushing/restoring a highlight whose
-- match crossed formatted text (MATCH_ACROSS_TEXT_NODES) could accept a
-- position that's a valid string but doesn't actually resolve to a page,
-- silently writing a broken highlight that crashes KOReader later when
-- something reads its page (opening the Bookmarks list, turning a page).
-- Removes any such broken entries from the book's real annotations and
-- unlinks the matching db item back to pending, so pushing it again (now
-- validated) can safely recover it.
function MyClippings:repairBrokenAnnotationsInCurrentBook()
    if not self.ui or not self.ui.document or not self.ui.annotation then
        UIManager:show(InfoMessage:new{ text = _("Open a book first.") })
        return
    end
    local real_path = self.ui.document.file
    local anns = self.ui.annotation.annotations

    local removed_texts = {}
    for i = #anns, 1, -1 do
        local ann = anns[i]
        local pos0_ok = type(ann.pos0) == "string" and self:xpointerResolvesToPage(ann.pos0)
        local page_ok = type(ann.page) == "string" and self:xpointerResolvesToPage(ann.page)
        if not pos0_ok and not page_ok then
            table.insert(removed_texts, ann.text or "")
            table.remove(anns, i)
        end
    end
    local removed = #removed_texts

    if removed > 0 then
        pcall(function() self.ui.annotation:onSaveSettings() end)
    end

    local unlinked = 0
    if removed > 0 then
        local removed_set = {}
        for _, t in ipairs(removed_texts) do removed_set[t] = true end
        local canon = self:buildCanonicalBooks()
        local pseudo_path
        local g = canon[real_path]
        if g then
            for path, book in pairs(self.db.books) do
                if path:match("^clippings://") and titlesMatch(normalizeTitle(book.title), g.norm) then
                    pseudo_path = path
                    break
                end
            end
        end
        for _, it in ipairs(self.db.items) do
            if it.book_path == real_path and removed_set[it.text] then
                it.pos0 = nil
                it.pos1 = nil
                it.page = nil
                if pseudo_path then it.book_path = pseudo_path end
                unlinked = unlinked + 1
            end
        end
        self._seen = nil
        self._seen_built = false
        self._koreader_id_index = nil
        self._koreader_id_built = false
        self:saveDB()
    end

    UIManager:show(InfoMessage:new{
        text = removed > 0
            and T(_("Removed %1 broken highlight(s) from this book (position couldn't be resolved) and unlinked %2 back to pending. Push again to safely recover them."), removed, unlinked)
            or _("No broken highlights found in this book."),
    })
end

function MyClippings:mergeAnnotationsInCurrentBook()
    if not self.ui or not self.ui.annotation or not self.ui.highlight then
        UIManager:show(InfoMessage:new{ text = _("Open a book first.") })
        return
    end

    local anns = self.ui.annotation.annotations
    local max_diff_ratio = self:getMergeMaxDiffPercent() / 100
    local to_drop = {}
    for a = 1, #anns do
        local ia = anns[a]
        if ia.text and not to_drop[ia] then
            for b = a + 1, #anns do
                local ib = anns[b]
                if ib.text and not to_drop[ib] and textsOverlap(ia.text, ib.text, max_diff_ratio) then
                    local drop
                    if ia.note and not ib.note then
                        drop = ib
                    elseif ib.note and not ia.note then
                        drop = ia
                    elseif #(ib.text or "") > #(ia.text or "") then
                        drop = ia
                    else
                        drop = ib
                    end
                    to_drop[drop] = true
                    if drop == ia then break end
                end
            end
        end
    end

    local count = 0
    for _ in pairs(to_drop) do count = count + 1 end
    if count == 0 then
        UIManager:show(InfoMessage:new{ text = _("No overlapping highlights found in this book."), timeout = 3 })
        return
    end

    -- Delete from highest index to lowest so removing one doesn't shift
    -- the indices of items still waiting to be checked/removed.
    for i = #self.ui.annotation.annotations, 1, -1 do
        local item = self.ui.annotation.annotations[i]
        if to_drop[item] then
            pcall(function() self.ui.highlight:deleteHighlight(i) end)
        end
    end
    pcall(function() self.ui.annotation:onSaveSettings() end)

    UIManager:show(InfoMessage:new{
        text = T(_("Merged %1 overlapping highlight(s) in this book."), count),
        timeout = 3,
    })
end

-- ===================== Output generation =====================

-- One-time fix for highlights ingested before scanMyClippings joined
-- Kindle's word-wrapped lines with a space instead of "\n" -- a highlight
-- with an embedded newline never matches findAllText against the book's
-- actual (space-separated) text, silently failing every push for it.
-- Rewrites text/note in place; doesn't touch pos0/pos1 (any that were
-- already linked stay linked -- only the stored text changes).
function MyClippings:fixEmbeddedNewlines()
    local fixed = 0
    for _, it in ipairs(self.db.items) do
        if it.text and it.text:find("\n", 1, true) then
            it.text = it.text:gsub("\n", " ")
            fixed = fixed + 1
        end
        if it.note and it.note:find("\n", 1, true) then
            it.note = it.note:gsub("\n", " ")
        end
    end
    if fixed > 0 then
        self._seen = nil
        self._seen_built = false
        self._koreader_id_index = nil
        self._koreader_id_built = false
        self:saveDB()
    end
    return fixed
end

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
    self._koreader_id_index = nil
    self._koreader_id_built = false
    local removed = before - #self.db.items
    if removed > 0 then
        self:saveDB()
    end
    return removed
end

function normText(s)
    return (s or ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
end

-- Classic O(n*m) edit distance -- fine here since it's only ever run on
-- individual highlight-length strings, not full documents.
function levenshtein(a, b)
    local la, lb = #a, #b
    if la == 0 then return lb end
    if lb == 0 then return la end
    local prev = {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        local cur = { [0] = i }
        local ca = a:byte(i)
        for j = 1, lb do
            local cost = (ca == b:byte(j)) and 0 or 1
            cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        end
        prev = cur
    end
    return prev[lb]
end

-- True if two highlight texts look like the same passage captured with a
-- slightly different boundary (a character or two off at the start/end),
-- not two genuinely different highlights.
function textsOverlap(a, b, max_diff_ratio)
    a, b = normText(a), normText(b)
    if a == "" or b == "" then return false end
    if a == b then return true end
    if a:find(b, 1, true) or b:find(a, 1, true) then return true end
    local maxlen = math.max(#a, #b)
    if maxlen > 400 then return false end -- avoid O(n*m) blowup on long passages
    return levenshtein(a, b) / maxlen <= max_diff_ratio
end

function sourcesQualifyForMerge(filter, sa, sb)
    if filter == "kindle" then return sa == "kindle" and sb == "kindle" end
    if filter == "koreader" then return sa == "koreader" and sb == "koreader" end
    return true -- "all"
end

-- Collapses near-duplicate highlights within the same book. Which pairs
-- qualify is controlled by source_filter ("kindle" = both sides must be
-- Kindle-sourced, "koreader" = both must be KOReader-native, "all" = any
-- combination) and max_diff_ratio (0..1, e.g. 0.08 = merge if the two
-- texts differ by less than 8%), both set via the plugin menu. Keeps
-- whichever side has a real position (pos0) so the jump-link survives,
-- otherwise keeps the longer text.
function MyClippings:mergeOverlappingHighlights(source_filter, max_diff_ratio)
    local canon = self:buildCanonicalBooks()
    local by_book = {}
    for idx, it in ipairs(self.db.items) do
        local g = canon[it.book_path]
        local key = g and g.key or (it.book_path or "?")
        by_book[key] = by_book[key] or {}
        table.insert(by_book[key], idx)
    end

    local to_remove = {}
    for _, idxs in pairs(by_book) do
        for a = 1, #idxs do
            local ia = idxs[a]
            if not to_remove[ia] then
                for b = a + 1, #idxs do
                    local ib = idxs[b]
                    if not to_remove[ib] then
                        local item_a = self.db.items[ia]
                        local item_b = self.db.items[ib]
                        if sourcesQualifyForMerge(source_filter, item_a.source, item_b.source)
                            and textsOverlap(item_a.text, item_b.text, max_diff_ratio) then
                            local drop_idx
                            if item_a.pos0 and not item_b.pos0 then
                                drop_idx = ib
                            elseif item_b.pos0 and not item_a.pos0 then
                                drop_idx = ia
                            elseif #(item_b.text or "") > #(item_a.text or "") then
                                drop_idx = ia
                            else
                                drop_idx = ib
                            end
                            local keep_item = (drop_idx == ia) and item_b or item_a
                            local drop_item = (drop_idx == ia) and item_a or item_b
                            if drop_item.note and drop_item.note ~= "" then
                                if not keep_item.note or keep_item.note == "" then
                                    keep_item.note = drop_item.note
                                elseif keep_item.note ~= drop_item.note then
                                    keep_item.note = keep_item.note .. "\n---\n" .. drop_item.note
                                end
                            end
                            to_remove[drop_idx] = true
                            if drop_idx == ia then break end
                        end
                    end
                end
            end
        end
    end

    if next(to_remove) == nil then return 0 end
    local kept = {}
    for i, it in ipairs(self.db.items) do
        if not to_remove[i] then table.insert(kept, it) end
    end
    local removed = #self.db.items - #kept
    self.db.items = kept
    self._seen = nil
    self._seen_built = false
    self._koreader_id_index = nil
    self._koreader_id_built = false
    self:saveDB()
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
    self:fixEmbeddedNewlines()
    self:dedupeExistingItems()
    self:dedupeKoreaderEditsById()
    self:mergeStandaloneNotesIntoHighlights()
    self:mergeOverlappingHighlights(self:getMergeSourceFilter(), self:getMergeMaxDiffPercent() / 100)
    local dir = self:getOutputDir()
    local out_path = dir .. "/My Clippings.html"
    self:writeHTML(out_path)
    self:applyDefaultCoverIfMissing(out_path)
end

function MyClippings:mergeNow()
    local before = #self.db.items
    self:regenerateOutputs()
    local removed = before - #self.db.items
    UIManager:show(InfoMessage:new{
        text = removed > 0 and T(_("Merged %1 overlapping highlight(s)."), removed)
            or _("No overlapping highlights found with the current settings."),
        timeout = 3,
    })
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
    put('blockquote{margin:1em 0;padding:0.9em 1.1em;border-radius:14px;border:1px solid #ddc9ae;background:#f5efe4;font-style:normal;page-break-inside:avoid;break-inside:avoid;}')
    put('.citation{font-size:0.7em;color:#a08060;font-style:italic;margin-top:0.4em;}')
    put('.note{font-size:0.9em;color:#444;font-style:normal;margin-top:0.5em;padding-top:0.5em;border-top:1px dashed #ddc9ae;}')
    put('.note-label{font-size:0.7em;font-weight:bold;color:#a08060;text-transform:uppercase;letter-spacing:0.05em;margin-right:0.4em;}')
    put('.standalone-note{border-style:dashed;background:#faf7f0;}')
    put('.meta{font-size:0.75em;color:#999;margin-top:0.4em;font-style:normal;}')
    put('.meta a{color:#7a5c3e;text-decoration:underline;}')
    put('.chapter{font-size:0.78em;color:#a08060;}')
    put('nav{margin-bottom:2em;}nav a{display:block;margin:0.2em 0;color:#5a3e2b;text-decoration:none;}')
    put('</style></head><body><h1>My Clippings</h1>')

    if mode == "timeline" then
        local flat = {}
        for _, it in ipairs(self.db.items) do table.insert(flat, it) end
        table.sort(flat, function(a, b) return datetimeSortKey(a.datetime) > datetimeSortKey(b.datetime) end)
        for _, it in ipairs(flat) do
            local book = canon[it.book_path] or self.db.books[it.book_path] or {}
            local link = self:buildJumpLink(it)
            if it.is_note then
                put('<blockquote class="standalone-note"><span class="note-label">Note</span><span class="quote-text">' .. htmlEscape(it.text) .. '</span>')
            else
                put('<blockquote>&ldquo;' .. htmlEscape(it.text) .. '&rdquo;')
                if it.note and it.note ~= "" then
                    put('<div class="note"><span class="note-label">Note</span>' .. htmlEscape(it.note) .. '</div>')
                end
            end
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
                if it.is_note then
                    put('<blockquote class="standalone-note"><span class="note-label">Note</span><span class="quote-text">' .. htmlEscape(it.text) .. '</span>')
                else
                    put('<blockquote>&ldquo;' .. htmlEscape(it.text) .. '&rdquo;')
                    if it.note and it.note ~= "" then
                        put('<div class="note"><span class="note-label">Note</span>' .. htmlEscape(it.note) .. '</div>')
                    end
                end
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

-- Shared "Sources" / "Max difference" settings items, used both by the
-- top-level "Merge overlapping highlights" group (which merges within the
-- consolidated file/db) and by "Push highlights to current book" (which
-- also merges the currently open book's real annotations) -- one setting,
-- shown in both places rather than duplicated logic.
function MyClippings:buildMergeSettingsMenuItems()
    return {
        {
            text_func = function()
                local f = self:getMergeSourceFilter()
                return T(_("Sources: %1"), f == "kindle" and _("Kindle only")
                    or f == "koreader" and _("KOReader only") or _("All"))
            end,
            sub_item_table = {
                {
                    text = _("All (any Kindle/KOReader pair)"),
                    callback = function() self.settings:saveSetting("merge_source_filter", "all"); self.settings:flush() end,
                },
                {
                    text = _("Kindle only (both sides from My Clippings.txt)"),
                    callback = function() self.settings:saveSetting("merge_source_filter", "kindle"); self.settings:flush() end,
                },
                {
                    text = _("KOReader only (both sides native highlights)"),
                    callback = function() self.settings:saveSetting("merge_source_filter", "koreader"); self.settings:flush() end,
                },
            },
        },
        {
            text_func = function()
                return T(_("Max difference: %1%"), self:getMergeMaxDiffPercent())
            end,
            sub_item_table = {
                { text = "5%", callback = function() self.settings:saveSetting("merge_max_diff_percent", 5); self.settings:flush() end },
                { text = "8%", callback = function() self.settings:saveSetting("merge_max_diff_percent", 8); self.settings:flush() end },
                { text = "15%", callback = function() self.settings:saveSetting("merge_max_diff_percent", 15); self.settings:flush() end },
                { text = "25%", callback = function() self.settings:saveSetting("merge_max_diff_percent", 25); self.settings:flush() end },
            },
        },
    }
end

function MyClippings:addToMainMenu(menu_items)
    menu_items.myclippings = {
        text = _("My Clippings Highlight Sync"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Pull highlights"),
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
                },
            },
            {
                text = _("Push highlights to current book"),
                sub_item_table = {
                    {
                        text = _("Push pending highlights (must have a book open)"),
                        keep_menu_open = true,
                        callback = function() self:pushToCurrentBook() end,
                    },
                    {
                        text = _("Merge overlapping highlights in this book (must have a book open)"),
                        keep_menu_open = true,
                        callback = function() self:mergeAnnotationsInCurrentBook() end,
                    },
                    {
                        text = _("Advanced"),
                        sub_item_table = {
                            {
                                text = _("Undo pushed highlights in this book (must have a book open)"),
                                keep_menu_open = true,
                                callback = function() self:unpushFromCurrentBook() end,
                            },
                            {
                                text = _("Delete ALL highlights in this book (must have a book open)"),
                                keep_menu_open = true,
                                callback = function() self:confirmClearAllAnnotationsInCurrentBook() end,
                            },
                            {
                                text = _("Restore highlights already known to the database (must have a book open)"),
                                keep_menu_open = true,
                                callback = function() self:restoreKnownHighlightsInCurrentBook() end,
                            },
                            {
                                text = _("Repair broken highlights in this book (fixes a v1.0.3 crash bug, must have a book open)"),
                                keep_menu_open = true,
                                callback = function() self:repairBrokenAnnotationsInCurrentBook() end,
                            },
                        },
                    },
                },
            },
            {
                text = _("(Re)build My Clippings file from Highlights"),
                keep_menu_open = true,
                callback = function()
                    self:regenerateOutputs()
                    UIManager:show(InfoMessage:new{ text = _("My Clippings file rebuilt."), timeout = 2 })
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
            {
                text = _("Exclude a folder..."),
                keep_menu_open = true,
                callback = function() self:promptExcludeFolder() end,
            },
            {
                text_func = function()
                    local n = #self:getExcludedFolders()
                    return n > 0 and T(_("Excluded folders (%1)"), n) or _("Excluded folders (none)")
                end,
                sub_item_table_func = function()
                    local items = {}
                    for _idx, folder in ipairs(self:getExcludedFolders()) do
                        table.insert(items, {
                            text = T(_("%1 (tap to remove)"), folder),
                            keep_menu_open = true,
                            callback = function()
                                self:removeExcludedFolder(folder)
                                self:regenerateOutputs()
                                UIManager:show(InfoMessage:new{ text = T(_("No longer excluding: %1"), folder), timeout = 2 })
                            end,
                        })
                    end
                    if #items == 0 then
                        table.insert(items, { text = _("No folders excluded."), select_enabled = false })
                    end
                    return items
                end,
            },
            {
                text = _("Advanced: merge settings"),
                sub_item_table = (function()
                    local items = {
                        {
                            text = _("Merge now in My Clippings.html (with settings below)"),
                            keep_menu_open = true,
                            callback = function() self:mergeNow() end,
                        },
                    }
                    for _, it in ipairs(self:buildMergeSettingsMenuItems()) do table.insert(items, it) end
                    return items
                end)(),
            },
            {
                text = _("Check for updates..."),
                keep_menu_open = true,
                callback = function()
                    local ok, Updater = pcall(require, "myclippings_updater")
                    if ok then
                        Updater.check()
                    else
                        UIManager:show(InfoMessage:new{ text = _("Update checker unavailable.") })
                    end
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

function MyClippings:promptExcludeFolder()
    local ok, PathChooser = pcall(require, "ui/widget/pathchooser")
    if not ok then return end
    local chooser = PathChooser:new{
        path = self:getOutputDir(),
        select_directory = true,
        select_file = false,
        onConfirm = function(path)
            self:addExcludedFolder(path)
            local removed = self:purgeExcludedItems()
            self:regenerateOutputs()
            UIManager:show(InfoMessage:new{
                text = removed > 0
                    and T(_("Excluding: %1\nRemoved %2 already-scanned highlight(s) from it."), path, removed)
                    or T(_("Excluding: %1"), path),
                timeout = 3,
            })
        end,
    }
    UIManager:show(chooser)
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
