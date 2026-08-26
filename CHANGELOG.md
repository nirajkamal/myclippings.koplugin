# Changelog

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
