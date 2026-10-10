# Folio

A small, fast PDF reader for macOS with only the tools Seth wants: reading, highlighting, and notes, all driven from the keyboard. It's built on Apple's PDFKit and saves standard PDF annotations, so highlights and notes made here appear in PDF Expert, Acrobat and Preview, and theirs appear here.

## Install

```bash
./scripts/build.sh --install
```

This builds a release binary, wraps it as `Folio.app`, signs it ad hoc, and copies it to `/Applications`. It needs only the Xcode command-line tools. To make Folio the default PDF app, select any PDF in Finder, choose Get Info, set "Open with" to Folio, and click Change All.

## Keys

Papers open one page per screen, fitted to the window. Bare keys are always on; there's nothing to enable. `?` opens a searchable list of every command with its keys, and Return runs the chosen one.

| Keys | Action |
|---|---|
| → / ← | next / previous page, in every mode |
| ↓ / ↑ | next / previous page (scrolls first if you've zoomed in) |
| `j` / `k` | scroll down / up, turning the page at its edge (a count works: `5j`) |
| `d` / `u` | half a screen down / up |
| space / ⇧space | a screen down / up |
| `J` / `K` | next / previous page |
| `gg` / `G` | first / last page; `12G` goes to page 12 |
| `:` (⌥⌘G) | go to page; accepts printed page numbers such as `245` |
| ⌘[ / ⌘] | back / forward after a jump |
| `s` (⌘F) | search as you type; all-lowercase ignores case. Return / ⇧Return go to the next / previous match; Esc closes and leaves the match selected |
| ⌘G / ⇧⌘G | next / previous match after closing search |
| `h` | highlight the selection; overlapping highlights merge |
| `n` | note on the selected passage (highlighting it if needed) or on the highlight you just made; otherwise on the highlight under the pointer, or a standalone note at the pointer |
| `x` or ⌫ | remove the selected or just-made highlight, or the one under the pointer |
| `c` | change colour of the selected or just-made highlight, or of the default colour |
| `t` | contents (outline), filterable |
| `;` | every highlight and note in the document, filterable |
| `o` | recent documents |
| `r` (⇧⌘R) | reader mode: no title bar, buttons or scroll bars, in an ordinary window |
| ⌘2 | two-page spread |
| `w` (⌘1) | switch between one page per screen and continuous scrolling (remembered per file) |
| `+` / `-` / `=` | zoom in / out / fit to window |
| `f` | full screen |
| Esc | clear selection or close a panel |
| ⌘Z | undo any highlight, note or colour change |

The usual flow: select a passage, press `h`, then `n`, type, and press Esc. The note attaches to that highlight.

The note editor behaves like any Mac text field: Return starts a new line, ⌥ and ⌘ with the arrows move by word and line, and Folio's own shortcuts are off while you type. Esc or ⌘Return saves and closes, as does clicking elsewhere. Clearing a standalone note's text deletes it.

A highlight with a note gets a circle in the left margin, level with its first line; click the circle to open the note. Clicking a highlight selects it. There's no margin bar, and the page layout never shifts. The pointer is an I-beam over pages and a hand over links and note circles.

Folio remembers your position, zoom and spread for each file, and remembers whether reader mode was on. Edits autosave in place through macOS document saving, which writes to a temporary file and swaps it in, so a crash mid-save can't corrupt the PDF.

## Layout

- `Sources/FolioCore/AnnotationKit.swift`: creating and reading highlights and notes. No UI.
- `Sources/Folio/Commands.swift`: every command in one table. Keys, menus and the `?` palette are all generated from it.
- `Sources/Folio/ReaderWindowController*.swift`: the window, keyboard handling, find, palettes, reader mode, annotation editing.
- `Sources/Folio/Overlays.swift`: the HUD, find bar, palette, note editor and note dots.
- `Sources/Folio/TestHarness.swift`: debug-only scripted driver (see below). Not compiled into release builds.

## Testing

`folio-selftest` writes highlights and notes into a copy of a PDF and checks the round trip; `scripts/check-annotations.py` confirms that MuPDF reads the same marks:

```bash
swift build -c release --product folio-selftest
.build/release/folio-selftest in.pdf out.pdf
python3 scripts/check-annotations.py out.pdf   # needs PyMuPDF
```

A debug build can run a keystroke script against a real window. Build with `swift build`, wrap `.build/debug/Folio` in an app bundle, and launch it with `open -g -n --env FOLIO_TEST_SCRIPT=steps.txt --env FOLIO_TEST_LOG=out.log -a FolioDebug.app file.pdf`. The step syntax is documented at the top of `TestHarness.swift`.
