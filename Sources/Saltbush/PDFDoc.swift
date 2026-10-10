import AppKit
import PDFKit

/// One open PDF. NSDocument gives us safe saving, autosave in place, Versions,
/// Open Recent, and handling of files changed by other apps.
@objc(PDFDoc)
final class PDFDoc: NSDocument {
    private(set) var pdf: PDFDocument?

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let controller = ReaderWindowController()
        addWindowController(controller)
        controller.attach()
    }

    // Read the whole file into memory rather than mapping it, so that saving
    // over the file can never pull the rug out from under the open document.
    override func read(from data: Data, ofType typeName: String) throws {
        guard let document = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        pdf = document
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let data = pdf?.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        for case let controller as ReaderWindowController in windowControllers { controller.attach() }
    }
}
