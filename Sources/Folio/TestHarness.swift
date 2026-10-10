#if DEBUG
import AppKit
import FolioCore
import PDFKit

/// Debug-only scripted driver. Set FOLIO_TEST_SCRIPT to a file of steps and
/// FOLIO_TEST_LOG to an output file; the first window to open runs the script.
/// Keys go through the same path as real typing (key monitor, then the window).
///
/// Steps: key <char|esc|ret|sret|down|up|del|space|sspace> · type <text> · wait <s>
///        select <page> <start> <length> · snap <png> · state · undo · quit
extension ReaderWindowController {
    private static var started = false

    func startTestScriptIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard !Self.started, let path = env["FOLIO_TEST_SCRIPT"], let log = env["FOLIO_TEST_LOG"],
              let script = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        Self.started = true
        FileManager.default.createFile(atPath: log, contents: nil)
        let steps = script.split(separator: "\n").map(String.init).filter { !$0.trimmed.isEmpty && !$0.hasPrefix("#") }
        window?.contentView?.wantsLayer = true
        // Scripted steps never end an event cycle, so rely on Folio's explicit per-edit groups only.
        undo?.groupsByEvent = false
        run(steps[...], log: log)
    }

    private func run(_ steps: ArraySlice<String>, log: String) {
        guard let step = steps.first else { return }
        let parts = step.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        var delay = 0.15
        switch parts[0] {
        case "key": sendKey(arg)
        case "type": arg.forEach { sendKey(String($0)) }
        case "wait": delay = Double(arg) ?? 0.5
        case "select":
            let n = arg.split(separator: " ").compactMap { Int($0) }
            if n.count == 3, let page = pdf?.page(at: n[0]) {
                pdfView.setCurrentSelection(page.selection(for: NSRange(location: n[1], length: n[2])), animate: false)
            }
        case "snap": snapshot(to: arg)
        case "undo": undo?.undo()
        case "undoinfo":
            append(log, "undoinfo manager=\(undo.map { "\(ObjectIdentifier($0))" } ?? "nil") window=\(window?.undoManager.map { "\(ObjectIdentifier($0))" } ?? "nil") canUndo=\(undo?.canUndo ?? false) level=\(undo?.groupingLevel ?? -1) name=\(undo?.undoActionName ?? "") edited=\(pdfDoc?.isDocumentEdited ?? false)")
        case "state": append(log, step + " " + stateJSON())
        case "quit":
            pdfDoc?.save(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
            return
        default: append(log, "unknown step \(step)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.run(steps.dropFirst(), log: log) }
    }

    private func sendKey(_ spec: String) {
        let named: [String: (String, UInt16, Bool)] = [
            "esc": ("\u{1b}", 53, false), "ret": ("\r", 36, false), "sret": ("\r", 36, true),
            "down": ("\u{F701}", 125, false), "up": ("\u{F700}", 126, false), "del": ("\u{7f}", 51, false),
            "space": (" ", 49, false), "sspace": (" ", 49, true),
        ]
        let (chars, code, shift) = named[spec] ?? (spec, 0, spec.uppercased() == spec && spec.lowercased() != spec)
        // Popovers live in their own window; send keys to whichever window holds focus.
        let target = noteEditor?.view.window ?? window!
        // Synthetic key events are unreliable inside text input; insert printable text directly.
        if named[spec] == nil, let text = target.firstResponder as? NSTextView {
            text.insertText(spec, replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: target.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
        else { return }
        if target === window, !(target.firstResponder is NSText), handleKey(event) { return }
        target.sendEvent(event)
    }

    private func stateJSON() -> String {
        var marks: [[String: Any]] = []
        if let pdf {
            for i in 0..<pdf.pageCount {
                for a in pdf.page(at: i)!.annotations where AnnotationKit.isMarkup(a) || AnnotationKit.isNote(a) {
                    marks.append(["page": i + 1, "kind": AnnotationKit.kind(a), "note": a.contents ?? "",
                                  "colour": Self.colours.first { $0.color == a.color }?.name ?? "other"])
                }
            }
        }
        let state: [String: Any] = [
            "page": currentPageIndex + 1,
            "selection": pdfView.currentSelection?.string?.prefix(60).description ?? "",
            "annotations": marks,
            "readerMode": readerMode,
            "titlebarHidden": window?.titlebarAppearsTransparent ?? false,
            "firstResponder": window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil",
            "noteEditorOpen": noteEditor != nil,
            "overlay": window?.contentView?.subviews.compactMap { v -> String? in
                v is PaletteView || v is PromptBar ? String(describing: type(of: v)) : nil
            }.first ?? "",
            "edited": pdfDoc?.isDocumentEdited ?? false,
            "scale": Double(pdfView.scaleFactor),
            "spread": pdfView.displayMode == .twoUpContinuous,
            "marker": pdf?.page(at: currentPageIndex).flatMap { markerViews.object(forKey: $0) }.map { m in
                "bounds=\(m.bounds) frame=\(m.frame) flipped=\(m.isFlipped) box=\(pdf!.page(at: currentPageIndex)!.bounds(for: pdfView.displayBox)) super=\(m.superview.map { String(describing: type(of: $0)) } ?? "-") superFlipped=\(m.superview?.isFlipped ?? false) transform=\(m.layer?.affineTransform() ?? .identity)"
            } ?? "none",
        ]
        let data = try! JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func snapshot(to path: String) {
        var images: [(NSView, String)] = [(window!.contentView!.superview ?? window!.contentView!, path)]
        if let popoverView = noteEditor?.view.window?.contentView {
            images.append((popoverView, path.replacingOccurrences(of: ".png", with: "-note.png")))
        }
        for (view, file) in images {
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            let scale = window!.backingScaleFactor
            let size = view.bounds.size
            guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.scaleBy(x: scale, y: scale)
            layer.render(in: ctx)
            if let image = ctx.makeImage() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: file))
            }
        }
    }

    private func append(_ path: String, _ line: String) {
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write((line + "\n").data(using: .utf8)!)
        handle.closeFile()
    }
}
#endif
