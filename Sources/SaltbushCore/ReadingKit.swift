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
