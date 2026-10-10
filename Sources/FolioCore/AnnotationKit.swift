import AppKit
import PDFKit

/// An annotation together with the page it lives on.
public struct PageAnnotation {
    public let annotation: PDFAnnotation
    public let page: PDFPage

    public init(_ annotation: PDFAnnotation, _ page: PDFPage) {
        self.annotation = annotation
        self.page = page
    }
}

public extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Creating and inspecting highlights and notes. Everything here writes standard
/// PDF annotations, so other readers (PDF Expert, Acrobat, Preview) see the same marks.
public enum AnnotationKit {
    public static func kind(_ a: PDFAnnotation) -> String {
        (a.type ?? "").replacingOccurrences(of: "/", with: "").lowercased()
    }

    /// Text markup: highlights, plus underlines and strike-outs made in other apps.
    public static func isMarkup(_ a: PDFAnnotation) -> Bool {
        ["highlight", "underline", "strikeout", "squiggly"].contains(kind(a))
    }

    /// A sticky note placed on the page.
    public static func isSticky(_ a: PDFAnnotation) -> Bool { kind(a) == "text" }

    public static func isNote(_ a: PDFAnnotation) -> Bool { ["text", "freetext"].contains(kind(a)) }

    /// One highlight annotation per page, with one quad per line of the selection.
    public static func makeHighlights(for selection: PDFSelection, color: NSColor, author: String?) -> [PageAnnotation] {
        var pages: [PDFPage] = []
        var rectsByPage: [ObjectIdentifier: [CGRect]] = [:]
        for line in selection.selectionsByLine() {
            guard !(line.string ?? "").trimmed.isEmpty else { continue }
            for page in line.pages {
                let r = line.bounds(for: page)
                guard r.width > 0.5, r.height > 0.5 else { continue }
                let id = ObjectIdentifier(page)
                if rectsByPage[id] == nil {
                    pages.append(page)
                    rectsByPage[id] = []
                }
                rectsByPage[id]!.append(r)
            }
        }
        return pages.map { page in
            let rects = rectsByPage[ObjectIdentifier(page)]!
            let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            let a = PDFAnnotation(bounds: union, forType: .highlight, withProperties: nil)
            // PDFKit wants quad points relative to the annotation's origin,
            // ordered top-left, top-right, bottom-left, bottom-right.
            a.quadrilateralPoints = rects.flatMap { r -> [NSValue] in
                let x0 = r.minX - union.minX, x1 = r.maxX - union.minX
                let y0 = r.minY - union.minY, y1 = r.maxY - union.minY
                return [NSPoint(x: x0, y: y1), NSPoint(x: x1, y: y1), NSPoint(x: x0, y: y0), NSPoint(x: x1, y: y0)]
                    .map { NSValue(point: $0) }
            }
            a.color = color
            a.userName = author
            a.modificationDate = Date()
            return PageAnnotation(a, page)
        }
    }

    public static func makeStickyNote(at point: CGPoint, text: String, color: NSColor, author: String?) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18),
                              forType: .text, withProperties: nil)
        a.iconType = .note
        a.contents = text
        a.color = color
        a.userName = author
        a.modificationDate = Date()
        return a
    }

    /// The page-space rectangles a markup annotation covers, one per line.
    public static func rects(of a: PDFAnnotation) -> [CGRect] {
        guard let quads = a.quadrilateralPoints, quads.count >= 4 else { return [a.bounds] }
        let bounds = a.bounds.insetBy(dx: -2, dy: -2)
        var out: [CGRect] = []
        for i in stride(from: 0, through: quads.count - 4, by: 4) {
            let pts = quads[i..<i + 4].map { $0.pointValue }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let raw = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            // Quads are normally relative to the bounds origin; tolerate files that store them absolute.
            let relative = raw.offsetBy(dx: a.bounds.minX, dy: a.bounds.minY)
            out.append(bounds.contains(relative) || !bounds.contains(raw) ? relative : raw)
        }
        return out
    }

    /// The topmost markup or note annotation under a page-space point.
    public static func annotation(at p: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.reversed().first { a in
            if isSticky(a) { return a.bounds.insetBy(dx: -3, dy: -3).contains(p) }
            return isMarkup(a) && rects(of: a).contains { $0.contains(p) }
        }
    }

    /// The text under a markup annotation, as a selection.
    public static func textSelection(of a: PDFAnnotation, on page: PDFPage) -> PDFSelection? {
        var result: PDFSelection?
        for r in rects(of: a) {
            guard let s = page.selection(for: r.insetBy(dx: 0, dy: r.height * 0.2)) else { continue }
            if let result { result.add(s) } else { result = s }
        }
        return result
    }

    public static func quotedText(of a: PDFAnnotation, on page: PDFPage, limit: Int = 160) -> String {
        let s = (textSelection(of: a, on: page)?.string ?? "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return s.count > limit ? String(s.prefix(limit)) + "…" : s
    }
}
