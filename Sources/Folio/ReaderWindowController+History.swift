import AppKit
import FolioCore
import PDFKit

/// Back and forward through jumps: following links, going to a page, jumping from the
/// contents or notes list, and starting a search. Turning pages isn't a jump, so Back
/// returns to where you were reading, not to the previous page.
extension ReaderWindowController {
    struct Location: Equatable {
        let pageIndex: Int
        let point: NSPoint

        func isNear(_ other: Location) -> Bool {
            pageIndex == other.pageIndex && abs(point.y - other.point.y) < 40
        }
    }

    var currentLocation: Location? {
        guard let pdf, let destination = pdfView.currentDestination, let page = destination.page else { return nil }
        return Location(pageIndex: pdf.index(for: page), point: destination.point)
    }

    /// Call just before a jump.
    func recordJump() {
        guard let here = currentLocation else { return }
        if let last = backStack.last, last.isNear(here) { return }
        backStack.append(here)
        if backStack.count > 200 { backStack.removeFirst() }
        forwardStack.removeAll()
    }

    func goBack() {
        guard let target = backStack.popLast() else {
            hud.show("No earlier location")
            return
        }
        if let here = currentLocation { forwardStack.append(here) }
        go(to: target)
    }

    func goForward() {
        guard let target = forwardStack.popLast() else {
            hud.show("No later location")
            return
        }
        if let here = currentLocation { backStack.append(here) }
        go(to: target)
    }

    private func go(to location: Location) {
        guard let pdf, let page = pdf.page(at: min(location.pageIndex, pdf.pageCount - 1)) else { return }
        if abs(location.point.x) < 1e6, abs(location.point.y) < 1e6 {
            pdfView.go(to: PDFDestination(page: page, at: location.point))
        } else {
            pdfView.go(to: page)
        }
    }

    /// A click on a link that leads elsewhere in the document is a jump.
    func recordJumpIfLink(atWindowPoint windowPoint: NSPoint) {
        let p = pdfView.convert(windowPoint, from: nil)
        guard pdfView.bounds.contains(p), let page = pdfView.page(for: p, nearest: false),
              let a = page.annotation(at: pdfView.convert(p, to: page)),
              AnnotationKit.kind(a) == "link", ReadingKit.internalDestination(of: a) != nil else { return }
        recordJump()
    }
}
