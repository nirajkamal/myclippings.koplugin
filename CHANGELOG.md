# Changelog

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
