# Folio

A small, fast PDF reader for the Mac that does three things: reading, highlighting and notes. It's driven almost entirely from the keyboard, and it has no toolbars. A reader mode hides the title bar too, leaving just the page in an ordinary window.

Folio is built on Apple's PDFKit and saves standard PDF annotations, so highlights and notes made in Folio show up in PDF Expert, Acrobat and Preview, and theirs show up in Folio.

## Install

Requires macOS 14 (Sonoma) or later, on Apple Silicon or Intel.

1. Download `Folio.zip` from the [latest release](../../releases/latest), unzip it, and drag `Folio.app` into Applications.
2. The current download isn't yet notarized by Apple, so the first time you open it macOS will say it can't verify the app. Click **Done**, then open **System Settings ▸ Privacy & Security**, scroll down, and click **Open Anyway** next to the message about Folio. You only need to do this once.

   If you're comfortable with Terminal, this does the same thing:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Folio.app
   ```

3. To open PDFs in Folio, right-click a PDF ▸ Open With ▸ Folio. To make it the default, select a PDF, choose File ▸ Get Info, set "Open with" to Folio, and click **Change All**.

### Building from source

You need the Xcode command-line tools (`xcode-select --install`); the full Xcode app isn't required.

```bash
git clone <this repository's URL> folio
cd folio
./scripts/build.sh --install     # builds and copies Folio.app to /Applications
```

`./scripts/package.sh` builds a universal app and zips it for a release.

## Keys

Papers open one page per screen, fitted to the window. Bare keys are always on; there's nothing to enable. The first time Folio opens it shows a sheet of every shortcut; press `?` (or ⌘/) to see it again. ⇧⌘P opens a searchable list of commands that runs whichever you pick.

| Keys | Action |
|---|---|
| → / ← | next / previous page, in every mode |
| ↓ / ↑ | next / previous page (scrolls first if you've zoomed in) |
| space / ⇧space | a screen down / up, turning the page at its edge |
| ⌘↑ / ⌘↓ | first / last page |
| `g` (⌥⌘G) | go to page; accepts printed page numbers such as `245` |
| ⌘[ / ⌘] | back / forward after a jump |
| `s` (⌘F) | search as you type; all-lowercase ignores case. Return / ⇧Return go to the next / previous match; Esc closes and leaves the match selected |
| ⌘G / ⇧⌘G | next / previous match after closing search |
| `h` | highlight the selection; overlapping highlights merge |
| `n` | note on the selected passage (highlighting it if needed) or on the highlight you just made; otherwise on the highlight under the pointer, or a standalone note at the pointer |
| `x` or ⌫ | remove the selected or just-made highlight, or the one under the pointer |
| `c` | change colour of the selected or just-made highlight, or of the default colour |
| `e` | copy every highlight and note as Markdown, with page numbers |
| ⇧⌘E | export highlights and notes to a Markdown file |
| `t` | contents (outline), filterable |
| `;` | every highlight and note in the document, filterable |
| `o` | recent documents |
| `r` (⇧⌘R) | reader mode: no title bar, buttons or scroll bars, in an ordinary window |
| `b` | theme: normal, sepia, night |
| ⌘2 | two-page spread |
| `w` (⌘1) | switch between one page per screen and continuous scrolling (remembered per file) |
| `+` / `-` / `=` | zoom in / out / fit to window |
| `f` | full screen |
| `?` (⌘/) | show all keyboard shortcuts |
| ⇧⌘P | searchable list of commands |
| Esc | clear selection or close a panel |
| ⌘Z | undo any highlight, note or colour change |

The usual flow: select a passage, press `h`, then `n`, type, and press Esc. The note attaches to that highlight.

The note editor behaves like any Mac text field: Return starts a new line, ⌥ and ⌘ with the arrows move by word and line, and Folio's own shortcuts are off while you type. Esc or ⌘Return saves and closes, as does clicking elsewhere. Clearing a standalone note's text deletes it.

Hover over a citation, footnote or cross-reference link for a moment and a preview of what it points to pops up, so you can check a reference without losing your place. (This works in PDFs with linked citations, which includes most LaTeX papers and many publishers' PDFs.)

A highlight with a note gets a circle in the left margin, level with its first line; click the circle to open the note, or right-click it to edit or delete the note (keeping the highlight) or to remove both. Right-clicking a standalone note offers Edit and Delete. Clicking a highlight selects it. There's no margin bar, and the page layout never shifts. The pointer is an I-beam over pages and a hand over links and note circles.

Folio remembers your position, zoom and spread for each file, and remembers whether reader mode was on. Edits autosave in place through macOS document saving, which writes to a temporary file and swaps it in, so a crash mid-save can't corrupt the PDF.

## Layout

- `Sources/FolioCore/AnnotationKit.swift`: creating and reading highlights and notes. No UI.
- `Sources/Folio/Commands.swift`: every command in one table. Keys, menus, the shortcuts sheet and the command palette are all generated from it.
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
