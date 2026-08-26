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
- **Merge overlapping highlights** — merges near-duplicates within
  `My Clippings.html`/its underlying db.
  - **Merge now** — runs immediately with the settings below.
  - **Sources** — All / Kindle only / KOReader only.
  - **Max difference** — 5% / 8% / 15% / 25%.
- **Push highlights to current book** — only available (and only useful)
  while you have a book open.
  - **Push pending highlights** — matches this book's pending
    Kindle-Clippings-sourced highlights against the actual text and writes
    real annotations for whatever matches; skips (and links to) anything
    that already overlaps a highlight you have.
  - **Merge overlapping highlights in this book** — collapses duplicate
    highlight boxes already in the open book itself.
  - Shares the same Sources / Max difference settings as above.
- **Rebuild My Clippings file** — regenerates `My Clippings.html`
  immediately (also runs the automatic dedup/merge passes first).
- **Group by: Book / Timeline** — toggles output grouping.
- **Font** — Bookerly, Georgia, PT Serif, or sans-serif.
- **Set custom output folder... / Use default home folder** — where
  `My Clippings.html` is written.

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

- Kindle Clippings entries with only a `Location` number (no page number,
  common for books without fixed pagination) won't get a jump-link if they
  were never pushed into a real book, since there's nothing reliable to
  link to.
- The overlap-merge is text-similarity based (substring or a small edit
  distance), not semantic — two genuinely different but similarly-worded
  highlights close together could theoretically be merged. Tune the Max
  Difference setting down, or restrict Sources, if this happens in your
  library.

## License

MIT
