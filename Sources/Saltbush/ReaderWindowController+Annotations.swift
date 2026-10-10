import AppKit
import SaltbushCore
import PDFKit

/// Highlights and notes. Every command acts on the current text selection first,
/// then on whatever annotation is under the pointer.
extension ReaderWindowController {
    static let colours: [(name: String, color: NSColor)] = [
        ("yellow", NSColor(srgbRed: 1.00, green: 0.85, blue: 0.24, alpha: 1)),
        ("green", NSColor(srgbRed: 0.56, green: 0.87, blue: 0.47, alpha: 1)),
        ("blue", NSColor(srgbRed: 0.53, green: 0.76, blue: 1.00, alpha: 1)),
        ("pink", NSColor(srgbRed: 1.00, green: 0.61, blue: 0.76, alpha: 1)),
    ]

    var colourIndex: Int {
        get { UserDefaults.standard.integer(forKey: "highlightColour") % Self.colours.count }
        set { UserDefaults.standard.set(newValue, forKey: "highlightColour") }
    }

    var currentColour: NSColor { Self.colours[colourIndex].color }

    var textSelection: PDFSelection? {
        guard let selection = pdfView.currentSelection, !(selection.string ?? "").trimmed.isEmpty else { return nil }
        return selection
    }

    // MARK: Commands

    func highlightSelection() {
        guard textSelection != nil else {
            hud.show("Select some text first")
            return
        }
        let created = makeHighlight()
        pdfView.clearSelection()
        recentHighlight = created.first
    }

    /// Highlights the selection. Existing highlights it overlaps are merged into the new one,
    /// keeping their colour and notes, so highlighting again extends rather than stacks.
    @discardableResult
    private func makeHighlight() -> [PageAnnotation] {
        guard let selection = textSelection?.copy() as? PDFSelection else { return [] }
        let touching = annotationsTouchingSelection()
        for t in touching {
            if let s = AnnotationKit.textSelection(of: t.annotation, on: t.page) { selection.add(s) }
        }
        let colour = touching.first?.annotation.color ?? currentColour
        let created = AnnotationKit.makeHighlights(for: selection, color: colour, author: NSFullUserName())
        let notes = touching.compactMap { $0.annotation.contents?.trimmed }.filter { !$0.isEmpty }
        if let first = created.first, !notes.isEmpty { first.annotation.contents = notes.joined(separator: "\n\n") }
        replace(touching, with: created, name: "Highlight")
        return created
    }

    /// n: the note goes on the selected passage (highlighting it if needed), else on the
    /// highlight just made, else on the highlight under the pointer, else on the page at the pointer.
    func addOrEditNote() {
        if let hit = annotationsTouchingSelection().first {
            editNote(hit.annotation, on: hit.page)
        } else if textSelection != nil, let hit = makeHighlight().first {
            pdfView.clearSelection()
            recentHighlight = hit
            editNote(hit.annotation, on: hit.page)
        } else if let hit = liveRecentHighlight {
            editNote(hit.annotation, on: hit.page)
        } else if let hit = annotationUnderMouse() {
            editNote(hit.annotation, on: hit.page)
        } else if let window {
            let p = pdfView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            addStickyNote(atViewPoint: pdfView.bounds.contains(p) ? p : NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY))
        }
    }

    /// The highlight made by the last h, if it still exists.
    var liveRecentHighlight: PageAnnotation? {
        guard let r = recentHighlight, r.page.annotations.contains(where: { $0 === r.annotation }) else { return nil }
        return r
    }

    func removeAnnotations() {
        var targets = annotationsTouchingSelection()
        if targets.isEmpty, let hit = liveRecentHighlight { targets = [hit] }
        if targets.isEmpty, let hit = annotationUnderMouse() { targets = [hit] }
        guard !targets.isEmpty else {
            hud.show("Nothing to remove here")
            return
        }
        replace(targets, with: [], name: targets.count == 1 ? "Remove Highlight" : "Remove Highlights")
        pdfView.clearSelection()
        recentHighlight = nil
    }

    func cycleColour() {
        var targets = annotationsTouchingSelection()
        if targets.isEmpty, let last = lastRecoloured, Date().timeIntervalSince(last.time) < 4 { targets = last.targets }
        if targets.isEmpty, let hit = liveRecentHighlight { targets = [hit] }
        if targets.isEmpty, let hit = annotationUnderMouse(), AnnotationKit.isMarkup(hit.annotation) { targets = [hit] }
        guard let first = targets.first else {
            colourIndex = (colourIndex + 1) % Self.colours.count
            hud.show("Highlight colour: \(Self.colours[colourIndex].name)")
            return
        }
        let next = (Self.colourIndex(of: first.annotation.color) + 1) % Self.colours.count
        recolour(targets, to: Array(repeating: Self.colours[next].color, count: targets.count))
        colourIndex = next
        lastRecoloured = (targets, Date())
        pdfView.clearSelection()
        hud.show(Self.colours[next].name.capitalized)
    }

    // MARK: Note editing

    func editNote(_ a: PDFAnnotation, on page: PDFPage) {
        // Notes on highlights open from their circle in the margin.
        let anchor = AnnotationKit.noteBadgeRect(for: a, on: page) ?? a.bounds
        pdfView.go(to: anchor, on: page)
        let rect = pdfView.convert(anchor, from: page)
        openEditor(text: a.contents ?? "", anchor: rect) { [weak self] text in
            guard let self else { return }
            if text.trimmed.isEmpty && AnnotationKit.isSticky(a) {
                self.replace([PageAnnotation(a, page)], with: [], name: "Delete Note")
            } else {
                self.setNote(a, on: page, to: text.trimmed.isEmpty ? nil : text)
            }
        }
    }

    /// The note is only created once something has been typed into it.
    func addStickyNote(atViewPoint p: NSPoint) {
        guard let page = pdfView.page(for: p, nearest: true) else { return }
        let pagePoint = pdfView.convert(p, to: page)
        openEditor(text: "", anchor: NSRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)) { [weak self] text in
            guard let self, !text.trimmed.isEmpty else { return }
            let note = AnnotationKit.makeStickyNote(at: pagePoint, text: text, color: self.currentColour,
                                                    author: NSFullUserName())
            self.replace([], with: [PageAnnotation(note, page)], name: "Add Note")
        }
    }

    private func openEditor(text: String, anchor: NSRect, commit: @escaping (String) -> Void) {
        noteEditor?.popover.close()
        let editor = NoteEditor(text: text)
        editor.onCommit = { [weak self] text in
            commit(text)
            self?.noteEditor = nil
            self?.window?.makeFirstResponder(self?.pdfView)
        }
        noteEditor = editor
        let visible = anchor.intersection(pdfView.bounds)
        editor.show(relativeTo: visible.isNull ? NSRect(x: pdfView.bounds.midX, y: pdfView.bounds.midY, width: 1, height: 1) : anchor,
                    of: pdfView)
    }

    func revealAnnotation(_ a: PDFAnnotation, on page: PDFPage) {
        recordJump()
        pdfView.go(to: a.bounds, on: page)
        if AnnotationKit.isMarkup(a) { select(a, on: page) }
        if AnnotationKit.isSticky(a) || !(a.contents ?? "").trimmed.isEmpty {
            DispatchQueue.main.async { self.editNote(a, on: page) }
        }
    }

    // MARK: Context menu

    /// Right-click: note circles and sticky notes offer Edit and Delete; selected text and
    /// highlights offer highlighting and note actions; empty page offers a note there.
    func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = pdfView.convert(event.locationInWindow, from: nil)
        contextPoint = point
        contextTarget = nil
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }

        if let page = pdfView.page(for: point, nearest: false),
           let a = AnnotationKit.noteBadge(at: pdfView.convert(point, to: page), on: page) {
            contextTarget = PageAnnotation(a, page)
            add("Edit Note", #selector(contextEditTarget))
            add("Delete Note", #selector(contextDeleteNote))
            menu.addItem(.separator())
            add("Remove Highlight and Note", #selector(contextRemoveTarget))
            return menu
        }
        if let hit = annotation(atViewPoint: point), AnnotationKit.isSticky(hit.annotation) {
            contextTarget = hit
            add("Edit Note", #selector(contextEditTarget))
            add("Delete Note", #selector(contextRemoveTarget))
            return menu
        }

        if textSelection == nil, let hit = annotation(atViewPoint: point), AnnotationKit.isMarkup(hit.annotation) {
            select(hit.annotation, on: hit.page)
        }
        if textSelection != nil {
            let touching = annotationsTouchingSelection()
            add("Highlight", #selector(contextHighlight))
            add(touching.isEmpty || !touching.contains { AnnotationKit.hasNote($0.annotation) } ? "Add Note" : "Edit Note",
                #selector(contextNote))
            if let noted = touching.first(where: { AnnotationKit.hasNote($0.annotation) }) {
                contextTarget = noted
                add("Delete Note", #selector(contextDeleteNote))
            }
            if !touching.isEmpty { add("Remove Highlight", #selector(contextRemove)) }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        } else {
            add("Add Note Here", #selector(contextAddSticky))
        }
        return menu
    }

    @objc private func contextHighlight() { highlightSelection() }
    @objc private func contextNote() { addOrEditNote() }
    @objc private func contextRemove() { removeAnnotations() }
    @objc private func contextAddSticky() { if let p = contextPoint { addStickyNote(atViewPoint: p) } }
    @objc private func contextEditTarget() { if let t = contextTarget { editNote(t.annotation, on: t.page) } }
    /// Deletes the note but keeps the highlight.
    @objc private func contextDeleteNote() {
        if let t = contextTarget { setNote(t.annotation, on: t.page, to: nil) }
    }
    @objc private func contextRemoveTarget() {
        if let t = contextTarget { replace([t], with: [], name: AnnotationKit.isSticky(t.annotation) ? "Delete Note" : "Remove Highlight") }
    }

    // MARK: Undoable edits

    func replace(_ old: [PageAnnotation], with new: [PageAnnotation], name: String) {
        for item in old { item.page.removeAnnotation(item.annotation) }
        for item in new { item.page.addAnnotation(item.annotation) }
        changed((old + new).map { $0.page })
        registerUndo(name) { $0.replace(new, with: old, name: name) }
    }

    func setNote(_ a: PDFAnnotation, on page: PDFPage, to text: String?) {
        let old = a.contents
        guard (old ?? "") != (text ?? "") else { return }
        a.contents = text
        a.modificationDate = Date()
        changed([page])
        registerUndo("Edit Note") { $0.setNote(a, on: page, to: old) }
    }

    func recolour(_ targets: [PageAnnotation], to colours: [NSColor]) {
        let old = targets.map { $0.annotation.color }
        for (t, c) in zip(targets, colours) { t.annotation.color = c }
        changed(targets.map { $0.page })
        registerUndo("Change Colour") { $0.recolour(targets, to: old) }
    }

    /// Each edit is its own explicit undo group, so registering never depends on
    /// being inside an event cycle (deferred callbacks, popover closes).
    private func registerUndo(_ name: String, _ handler: @escaping (ReaderWindowController) -> Void) {
        guard let undo else { return }
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self, handler: handler)
        undo.setActionName(name)
        undo.endUndoGrouping()
    }

    private func changed(_ pages: [PDFPage]) {
        for page in pages {
            pdfView.annotationsChanged(on: page)
            markerViews.object(forKey: page)?.needsDisplay = true
        }
    }

    // MARK: Finding annotations

    func annotationsTouchingSelection() -> [PageAnnotation] {
        guard let selection = textSelection else { return [] }
        var out: [PageAnnotation] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let r = line.bounds(for: page)
                for a in page.annotations where AnnotationKit.isMarkup(a) && !out.contains(where: { $0.annotation === a }) {
                    let overlaps = AnnotationKit.rects(of: a).contains { rect in
                        let i = rect.intersection(r)
                        return !i.isNull && i.width > 1 && i.height > r.height * 0.4
                    }
                    if overlaps { out.append(PageAnnotation(a, page)) }
                }
            }
        }
        return out
    }

    func annotationUnderMouse() -> PageAnnotation? {
        guard let window else { return nil }
        return annotation(atViewPoint: pdfView.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    func annotation(atViewPoint p: NSPoint) -> PageAnnotation? {
        guard pdfView.bounds.contains(p), let page = pdfView.page(for: p, nearest: false) else { return nil }
        return AnnotationKit.annotation(at: pdfView.convert(p, to: page), on: page).map { PageAnnotation($0, page) }
    }

    func select(_ a: PDFAnnotation, on page: PDFPage) {
        pdfView.setCurrentSelection(AnnotationKit.textSelection(of: a, on: page), animate: false)
    }

    private static func colourIndex(of colour: NSColor) -> Int {
        guard let c = colour.usingColorSpace(.sRGB) else { return -1 }
        let distances = colours.map { entry -> CGFloat in
            let e = entry.color
            return abs(e.redComponent - c.redComponent) + abs(e.greenComponent - c.greenComponent)
                + abs(e.blueComponent - c.blueComponent)
        }
        guard let best = distances.enumerated().min(by: { $0.element < $1.element }), best.element < 0.3 else { return -1 }
        return best.offset
    }
}
