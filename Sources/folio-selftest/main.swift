// Writes highlights and notes into a copy of a PDF, reloads it, and reports what PDFKit sees.
// Usage: folio-selftest <in.pdf> <out.pdf>
// Pair with scripts/check-annotations.py to confirm another engine (MuPDF) reads the same marks.
import AppKit
import FolioCore
import PDFKit

let args = CommandLine.arguments
guard args.count == 3, let pdf = PDFDocument(url: URL(fileURLWithPath: args[1])), pdf.pageCount >= 2,
      let p0 = pdf.page(at: 0), let p1 = pdf.page(at: 1) else {
    print("usage: folio-selftest <in.pdf with 2+ pages> <out.pdf>")
    exit(2)
}

func normalise(_ s: String?) -> String {
    (s ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

let yellow = NSColor(srgbRed: 1, green: 0.85, blue: 0.24, alpha: 1)
var expected: [String] = []

// 1. A multi-line highlight with a note on page 1.
let n0 = p0.numberOfCharacters
let multi = p0.selection(for: NSRange(location: n0 / 3, length: min(400, n0 / 3)))!
let first = AnnotationKit.makeHighlights(for: multi, color: yellow, author: "selftest")
first[0].annotation.contents = "A note on a multi-line highlight."
expected.append(normalise(multi.string))

// 2. A highlight that crosses from page 1 onto page 2.
let cross = pdf.selection(from: p0, atCharacterIndex: max(0, n0 - 60), to: p1, atCharacterIndex: 60)!
let second = AnnotationKit.makeHighlights(for: cross, color: yellow, author: "selftest")
print("cross-page selection produced \(second.count) annotations (expect 2)")

// 3. A sticky note.
let sticky = AnnotationKit.makeStickyNote(at: CGPoint(x: 40, y: 700), text: "Standalone note", color: yellow, author: "selftest")

for item in first + second { item.page.addAnnotation(item.annotation) }
p1.addAnnotation(sticky)
guard pdf.write(to: URL(fileURLWithPath: args[2])) else { print("write failed"); exit(1) }

// Reload and inspect.
let reloaded = PDFDocument(url: URL(fileURLWithPath: args[2]))!
var failures = 0
for i in 0..<2 {
    let page = reloaded.page(at: i)!
    for a in page.annotations where AnnotationKit.isMarkup(a) || AnnotationKit.isSticky(a) {
        let text = AnnotationKit.isMarkup(a) ? normalise(AnnotationKit.textSelection(of: a, on: page)?.string) : ""
        print("page \(i + 1) \(AnnotationKit.kind(a)) lines=\(AnnotationKit.rects(of: a).count) note=\(a.contents ?? "-")")
        if !text.isEmpty { print("   text: \(text.prefix(90))…") }
        if a.contents == "A note on a multi-line highlight." && text != expected[0] {
            failures += 1
            print("   MISMATCH\n   want: \(expected[0].prefix(90))…")
        }
    }
}
// Export: the Markdown summary should hold both highlights (the cross-page one counts once per page) and the note.
let summary = ReadingKit.markdownSummary(of: reloaded, title: "Selftest")
print("markdown export: \(summary.count) items")
print(summary.text.split(separator: "\n").prefix(8).joined(separator: "\n"))
if summary.count != 4 || !summary.text.contains("A note on a multi-line highlight.") || !summary.text.contains("**Note, p. 2:** Standalone note") {
    failures += 1
    print("EXPORT MISMATCH")
}
print(failures == 0 ? "PDFKit round trip OK" : "PDFKit round trip FAILED")
exit(failures == 0 ? 0 : 1)
