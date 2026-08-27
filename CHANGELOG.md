# Changelog

## v1.0.3

- **Highlight notes**: a note you attach to a KOReader highlight is now
  captured, shown under the quote in `My Clippings.html`, and carried over
  when pushed into a book's real annotations. A Kindle "Your Note" entry
  is folded into its highlight automatically; if you later edit that note
  in Kindle (which appends a new entry rather than replacing the old one),
  the latest version now correctly replaces the old one instead of
  becoming an orphaned duplicate.
- **Exclude folders**: new "Exclude a folder..." action stops future
  scans/live-sync from touching a folder (e.g. a research-papers
  subfolder) and immediately purges anything already pulled from it.
  Manage exclusions from "Excluded folders (N)".
- **Push reliability fixes**:
  - Fixed a parser bug where a Kindle highlight spanning multiple lines in
    `My Clippings.txt` got an embedded newline in its stored text, which
    silently broke matching it against the book (a one-time cleanup fixes
    already-affected highlights too).
  - Pushing now matches text across italicized/inline-formatted spans
    (`<i>emphasis</i>` no longer blocks a match), and validates that a
    found/matched position is actually usable before writing it, closing
    off a rare cause of a later, unrelated-looking crash on page turn.
  - After a push or restore that changes the book's real highlights, you
    now get an explicit prompt to fully close and reopen KOReader before
    continuing to read — works around a KOReader-side issue that can crash
    the app on the very next page turn otherwise.
- **New per-book recovery actions**, under "Push highlights to current
  book → Advanced": "Undo pushed highlights in this book" (removes only
  what the plugin added, unlinking them back to pending), "Delete ALL
  highlights in this book" (full reset, with confirmation), and "Restore
  highlights already known to the database" (recreates highlights the db
  has a good position for but which are missing from the book itself —
  e.g. after replacing the book file).
- Menu reorganized for a clearer top-to-bottom flow: Pull → Push to
  current book (with the everyday Push/Merge actions on top and the
  Undo/Delete/Restore recovery tools tucked under a nested "Advanced")
  → (Re)build → presentation/output settings, with the merge tuning knobs
  (Sources, Max difference) under their own "Advanced" at the bottom.
  Renamed "Rebuild My Clippings file" to "(Re)build My Clippings file
  from Highlights".

## v1.0.2

- Fixed KOReader-native highlights piling up as duplicates every time you
  edited one — now tracked by book + creation timestamp instead of text,
  so an edit updates the existing entry instead of appending a new one. A
  one-time cleanup collapses duplicates left over from before this fix.
- Overlap-merging is now configurable from the menu: choose which source
  pairs qualify (All / Kindle only / KOReader only) and the max text
  difference to merge on (5–25%, was a fixed 8%-Kindle-only rule before).
- New "Merge overlapping highlights in this book" action, under the new
  "Push highlights to current book" group — collapses duplicate highlight
  boxes in the *currently open book's own annotations*, not just in the
  consolidated file.
- Pushing pending highlights now checks the open book's existing
  highlights first and links to a match instead of creating a duplicate
  highlight box on top of one you already have.
- Menu reorganized: pull actions grouped under "Pull highlights"; merge
  and push actions grouped with their own settings.
- Renamed "Rebuild highlights file now" to "Rebuild My Clippings file".

## v1.0.1

- Highlight quotes are no longer italicized; each one now has a small
  italic "— Author, Title" citation line beneath it.
- Overlapping Kindle re-captures of the same passage (a highlight recorded
  twice with a slightly different boundary) are now automatically merged
  on every rebuild, as long as at least one side came from Kindle's My
  Clippings.txt. Two KOReader-native highlights are never merged this way.
- Auto-cover: `My Clippings.html` gets the bundled `cover.png` set as its
  custom cover the first time it's generated.
- Output renamed to `My Clippings.html`; README now leads with the cover
  image as the main screenshot.

## v1.0.0

Initial release: live-syncing highlight consolidation from KOReader
annotations and Kindle's My Clippings.txt, book/timeline grouping,
jump-to-book links, safe push-to-open-book recovery, robust cross-source
title matching, and configurable output folder/font.
