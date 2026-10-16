import AppKit
import SaltbushCore
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

    /// Follows a clicked link. Links within the document count as jumps; web links open in the browser.
    func follow(_ link: PDFAnnotation) {
        if let destination = ReadingKit.internalDestination(of: link) {
            recordJump()
            pdfView.go(to: destination)
        } else if let action = link.action {
            pdfView.perform(action)
        } else if let url = link.url {
            NSWorkspace.shared.open(url)
        }
    }
}
