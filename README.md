# myclippings.koplugin

Consolidates highlights scattered across your reading setup — KOReader's own
per-book annotations and Kindle's native `My Clippings.txt` — into one
live-updating, nicely formatted **My Clippings.html** file. Every new
highlight you make in KOReader gets appended automatically; a manual "pull"
merges in anything from Kindle's clippings file too.

![My Clippings cover, applied automatically as the file's cover art](cover.png)

## Why

If you read across both the stock Kindle app and KOReader, or you've ever
re-exported/re-copied your library and had KOReader lose its `.sdr` sidecar
data, your highlights end up scattered across several places with no single
view of everything. This plugin builds and maintains that single view, and
can (carefully) recover highlights back into a book's real annotations so
they show up in other tools that read native KOReader highlights (e.g. the
`bookshelf.koplugin` quote-of-the-day widget).

## Features

- **Live sync** — hooks KOReader's `AnnotationsModified` event, so every
  highlight you make is appended (debounced) without any manual step.
- **Pull from KOReader** — walks your library's `.sdr` sidecars for existing
  annotations and merges them in.
- **Pull from Kindle** — parses `My Clippings.txt` (the file the stock
  Kindle app maintains) and merges it in too, deduplicated against what's
  already there.
- **Push pending highlights to the open book** — for highlights recovered
  from Kindle Clippings (which have no real position, just a page/location
  number), searches the *currently open* book for the exact text and, if
  found, writes a genuine annotation (real position, real `drawer`) into
  that book's own `.sdr` — indistinguishable from a highlight you made
  natively. Deliberately scoped to the book you have open right now; see
  [Design notes](#design-notes--why-no-bulk-push) for why.
- **Output formatting** — grouped by book or by timeline (your choice),
  each highlight rendered as a styled quote block with a working "Open in
  book" link that jumps to the exact position.
- **Merges overlapping highlights** — the same passage sometimes ends up
  highlighted more than once (Kindle re-capturing it with a slightly
  different boundary, or a KOReader highlight that got edited — see Design
  notes below). On every rebuild, pairs of highlights in the same book
  whose text overlaps or differs by less than a configurable percentage
  (5–25%, default 8%) are collapsed into one, keeping whichever side has a
  real position (or the longer text if neither does). Configurable to only
  merge Kindle-Kindle pairs, only KOReader-KOReader pairs, or any
  combination — from the plugin's menu.
- **Merge overlapping highlights in the current book** — a separate action
  that edits the *book's own* annotation list (via the same delete path
  KOReader's own highlight menu uses), so duplicate highlight boxes
  actually disappear from the book you're reading, not just from the
  consolidated file. Also runs automatically as part of pushing pending
  highlights into the open book.
- **Highlight notes** — a note you attach to a highlight in KOReader is
  captured and shown under the quote, and carried over when pushed into a
  book's real annotations. A Kindle "Your Note" entry is folded into its
  highlight automatically, including picking up the latest version if you
  later edit that note in Kindle.
- **Exclude folders** — stop a folder (e.g. a research-papers subfolder)
  from ever being scanned or live-synced, and immediately purge anything
  already pulled from it.
- **Per-book recovery tools** — undo just what the plugin pushed into a
  book, restore highlights the database already has a good position for
  but which are missing from the book (e.g. after replacing the book
  file), or wipe a book's highlights entirely for a clean re-push.
- **Configurable** — output folder (defaults to your KOReader home folder,
  overridable), font, and grouping mode, all from the plugin's menu.
- **Cover** — the bundled `cover.png` is set as `My Clippings.html`'s custom
  cover automatically the first time it's generated, so it shows up nicely
  in cover-grid views like `bookshelf.koplugin`'s. Pick a different cover
  yourself at any point (e.g. via bookshelf's own cover picker) and it's
  left alone from then on.

Shown in `bookshelf.koplugin`'s home screen, alongside the rest of a library:

![My Clippings shown in bookshelf.koplugin, alongside the rest of the library](screenshot.png)

## Installation

1. Download or clone this repo so the plugin folder is named
   `myclippings.koplugin`.
2. Copy the whole `myclippings.koplugin` folder into your KOReader plugins
   directory (e.g. `koreader/plugins/`).
3. Restart KOReader. It appears in the main menu under **Tools** (top level,
   not nested under "More tools") as **My Clippings Highlight Sync**.

## Usage

Open **Tools → My Clippings Highlight Sync**:

- **Pull highlights**
  - **Pull highlights from KOReader** — merge in `.sdr` annotations.
  - **Pull highlights from Kindle (My Clippings)** — merge in
    `My Clippings.txt`.
  - **Pull and merge highlights from all sources** — runs both pulls, then
    merges/dedupes.
- **Push highlights to current book** — only available (and only useful)
  while you have a book open.
  - **Push pending highlights** — matches this book's pending
    Kindle-Clippings-sourced highlights against the actual text and writes
    real annotations for whatever matches; skips (and links to) anything
    that already overlaps a highlight you have.
  - **Merge overlapping highlights in this book** — collapses duplicate
    highlight boxes already in the open book itself.
  - **Advanced**
    - **Undo pushed highlights in this book** — removes only what the
      plugin added, unlinking them back to pending.
    - **Delete ALL highlights in this book** — full reset (confirmation
      required), including any you made natively.
    - **Restore highlights already known to the database** — recreates
      highlights the db has a good position for but which are missing
      from the book itself (e.g. after replacing the book file).
    - **Repair broken highlights in this book** — fixes a v1.0.3 crash bug
      (see [Design notes](#matching-text-across-formatting-and-kindles-line-wrapping)):
      removes only highlights whose position doesn't actually resolve and
      unlinks them back to pending for a safe re-push.
- **(Re)build My Clippings file from Highlights** — regenerates
  `My Clippings.html` immediately (also runs the automatic dedup/merge
  passes first).
- **Group by: Book / Timeline** — toggles output grouping.
- **Font** — Bookerly, Georgia, PT Serif, or sans-serif.
- **Set custom output folder... / Use default home folder** — where
  `My Clippings.html` is written.
- **Exclude a folder... / Excluded folders (N)** — stop a folder from
  being scanned/synced, and manage current exclusions.
- **Advanced: merge settings**
  - **Merge now in My Clippings.html** — runs the overlap-merge
    immediately with the settings below.
  - **Sources** — All / Kindle only / KOReader only.
  - **Max difference** — 5% / 8% / 15% / 25%.
- **Check for updates...** — checks this repo's latest release against the
  installed version; if newer, shows the release notes with an option to
  download and install it in place (restarts KOReader afterward).

## Design notes / why no bulk push

An earlier version tried to push highlights into *any* matching book in
your library by opening each one headlessly via `DocumentRegistry` and
calling `document:findAllText()`. This reliably segfaulted KOReader (exit
code 139) — confirmed via a standalone `luajit` reproduction outside the
full app, isolating it to `findAllText()` on a document that hasn't gone
through the normal ReaderUI initialization sequence. Opening a document
alone isn't enough; something `findAllText` depends on only gets set up by
the full "show this book in the reader" flow.

The safe alternative implemented here only searches the book you already
have open — since that document went through the normal flow, this uses
the exact same code path KOReader's own in-book search does, with no crash
risk observed. If you want highlights pushed into other books, open them
and run the push from within each one.

### Matching text across formatting and Kindle's line-wrapping

Pushing/restoring needs to find a highlight's exact text in the book to
get a real position. Two things used to break that silently:

- Kindle word-wraps a long highlight across multiple lines in
  `My Clippings.txt`; joining those with a literal newline embedded a
  character that doesn't exist in the book's actual (space-separated)
  text. Fixed by joining with a space instead — plus a one-time cleanup
  for highlights already affected.
- A highlight whose text crosses an italicized (or otherwise
  inline-formatted) span — `<i>emphasis</i>` splits the sentence into
  separate text nodes — used to never match, since `findAllText()`
  defaults to matching within one contiguous text run. Passing KOReader's
  own `MATCH_ACROSS_TEXT_NODES` search flag (the same flag its own in-book
  search uses by default) fixes this — but that flag introduced its own
  problem: a cross-node match's position can be a syntactically valid
  string that still doesn't resolve to a real page, and v1.0.3 accepted it
  anyway, writing a broken highlight that crashed KOReader later (opening
  the Bookmarks list, or turning a page). Fixed in v1.0.4 by confirming a
  position actually resolves before ever writing it. **If you used
  Push/Restore on v1.0.3 and hit a crash like this**, open the affected
  book and run Push highlights to current book → Advanced → "Repair
  broken highlights in this book" — it removes only the broken entries and
  unlinks them back to pending so a fresh push recovers them safely.

### Why KOReader-native highlights used to duplicate on edit

KOReader keeps a highlight's creation timestamp stable even when you later
resize its boundary — only the text/position change. Earlier versions of
this plugin tracked highlights by their text, so every edit looked like a
brand new highlight and got appended instead of replacing the old one,
leaving a growing pile of stale near-duplicates for any highlight you
edited more than once. It's now tracked by book + creation timestamp
instead, so edits update the existing entry in place; a one-time cleanup
also collapses any duplicates left over from before this fix.

## Known limitations

- Push and Restore only work on reflowable documents (EPUB, FB2, HTML,
  TXT) — refused outright on paging documents (PDF, CBZ, DjVu), since
  those use a different backend and position model this feature was never
  tested against.
- Kindle Clippings entries with only a `Location` number (no page number,
  common for books without fixed pagination) won't get a jump-link if they
  were never pushed into a real book, since there's nothing reliable to
  link to.
- The overlap-merge is text-similarity based (substring or a small edit
  distance), not semantic — two genuinely different but similarly-worded
  highlights close together could theoretically be merged. Tune the Max
  Difference setting down, or restrict Sources, if this happens in your
  library.
- Pushing/restoring changes a book's real annotations, and KOReader has a
  known issue where the *next page turn* right after that can crash the
  app (unrelated to this plugin's own logic — it's in KOReader's
  bookmark/dogear-visibility check). The plugin now prompts you to fully
  close and reopen KOReader after any push or restore, before continuing
  to read, which reliably avoids it.

## License

MIT
