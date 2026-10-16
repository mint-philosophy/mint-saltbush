import AppKit
import PDFKit

/// Reading aids that don't depend on the window: reference previews and annotation export.
public enum ReadingKit {
    // MARK: Reference previews

    /// The in-document target of a link (a citation, footnote or cross-reference), if it has one.
    public static func internalDestination(of link: PDFAnnotation) -> PDFDestination? {
        let destination = link.destination ?? (link.action as? PDFActionGoTo)?.destination
        return destination?.page == nil ? nil : destination
    }

    private static let linkTextCache = NSMapTable<PDFAnnotation, NSArray>.weakToStrongObjects()

    /// The parts of a link that actually cover its text. Link boxes in papers are often padded
    /// well beyond the citation, so this trims them to the characters inside.
    public static func linkTextRects(of link: PDFAnnotation, on page: PDFPage) -> [CGRect] {
        if let cached = linkTextCache.object(forKey: link) as? [NSValue] { return cached.map(\.rectValue) }
        let box = link.bounds
        let text = (page.string ?? "") as NSString
        let slack = box.insetBy(dx: -0.5, dy: -0.5)
        func isSpace(_ i: Int) -> Bool {
            CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(text.character(at: i)) ?? " ")
        }
        // Padding around a link catches the edges of neighbouring words. Count a word as part of
        // the link only if more than half of its letters lie wholly inside the box.
        var glyphs: [CGRect] = []
        var seenWords = Set<Int>()
        if let selection = page.selection(for: box) {
            for r in 0..<selection.numberOfTextRanges(on: page) {
                let range = selection.range(at: r, on: page)
                guard range.location != NSNotFound else { continue }
                for index in range.location..<min(NSMaxRange(range), text.length) where !isSpace(index) {
                    var start = index, end = index
                    while start > 0 && !isSpace(start - 1) { start -= 1 }
                    while end + 1 < text.length && !isSpace(end + 1) { end += 1 }
                    guard seenWords.insert(start).inserted else { continue }
                    let letters = (start...end).map { page.characterBounds(at: $0) }
                    let inside = letters.filter { $0.width > 0 && slack.contains($0) }
                    if inside.count * 2 > letters.count { glyphs += inside }
                }
            }
        }
        // Merge the characters into one rectangle per line.
        var rects: [CGRect] = []
        for glyph in glyphs.sorted(by: { ($0.midY, -$0.minX) > ($1.midY, -$1.minX) }) {
            if let last = rects.last, abs(last.midY - glyph.midY) < max(last.height, glyph.height) / 2 {
                rects[rects.count - 1] = last.union(glyph)
            } else {
                rects.append(glyph)
            }
        }
        if rects.isEmpty { rects = [box] }  // a link over a figure rather than text
        linkTextCache.setObject(rects.map { NSValue(rect: $0) } as NSArray, forKey: link)
        return rects
    }

    /// The link whose text is under a page-space point.
    public static func link(at p: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.last { a in
            AnnotationKit.kind(a) == "link"
                && linkTextRects(of: a, on: page).contains { $0.insetBy(dx: -0.5, dy: -1).contains(p) }
        }
    }

    /// A picture of the text at a destination: the column it lands in, from the target line down.
    public static func previewImage(of destination: PDFDestination, height: CGFloat = 130, maxWidth: CGFloat = 540) -> NSImage? {
        guard let page = destination.page else { return nil }
        let box = page.bounds(for: .cropBox)
        let specified = { (v: CGFloat) in abs(v) < 1e5 }
        let top = min((specified(destination.point.y) ? destination.point.y : box.maxY) + 2, box.maxY)
        var x0 = box.minX + 18, x1 = box.maxX - 18
        // Narrow to the column holding the target line, so two-column papers show one column.
        if specified(destination.point.x),
           let line = page.selectionForLine(at: CGPoint(x: destination.point.x + 6, y: top - 14))?.bounds(for: page),
           line.width > 60 {
            x0 = max(box.minX, line.minX - 8)
            x1 = min(box.maxX, line.maxX + 8)
        }
        let rect = CGRect(x: x0, y: max(box.minY, top - height), width: x1 - x0, height: min(height, top - box.minY))
        guard rect.width > 10, rect.height > 10 else { return nil }
        let scale = min(1.4, maxWidth / rect.width)
        return NSImage(size: NSSize(width: rect.width * scale, height: rect.height * scale), flipped: false) { bounds in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            NSColor.white.setFill()
            bounds.fill()
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -(rect.minX - box.minX), y: -(rect.minY - box.minY))
            page.draw(with: .cropBox, to: ctx)
            return true
        }
    }

    // MARK: Export

    /// Every highlight and note as Markdown, in reading order. Returns the text and how many items it holds.
    public static func markdownSummary(of pdf: PDFDocument, title: String, date: Date = Date()) -> (text: String, count: Int) {
        var blocks: [String] = []
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            let label = "p. " + (page.label ?? String(i + 1))
            let midX = page.bounds(for: .cropBox).midX
            // Reading order: left column before right, then top to bottom.
            let items = page.annotations
                .filter { AnnotationKit.isMarkup($0) || AnnotationKit.isNote($0) }
                .sorted { a, b in
                    let ca = a.bounds.minX > midX ? 1 : 0, cb = b.bounds.minX > midX ? 1 : 0
                    return ca != cb ? ca < cb : a.bounds.maxY > b.bounds.maxY
                }
            for a in items {
                let note = (a.contents ?? "").trimmed
                if AnnotationKit.isMarkup(a) {
                    let quote = AnnotationKit.quotedText(of: a, on: page, limit: .max)
                    guard !quote.isEmpty else { continue }
                    var block = "> \(quote) (\(label))"
                    if !note.isEmpty { block += "\n\n" + note }
                    blocks.append(block)
                } else if !note.isEmpty {
                    blocks.append("**Note, \(label):** \(note)")
                }
            }
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        let header = "# \(title)\n\n*Highlights and notes exported from Saltbush, \(formatter.string(from: date)).*"
        return (([header] + blocks).joined(separator: "\n\n") + "\n", blocks.count)
    }
}
