import AppKit
import SaltbushCore
import PDFKit

final class ReaderPDFView: PDFView {
    weak var controller: ReaderWindowController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.contextMenu(for: event)
    }

    // PDFKit leaves the arrow over text. Show the I-beam over pages, and a hand over links and note circles.
    override func setCursorFor(_ area: PDFAreaOfInterest) {
        guard let window else { return super.setCursorFor(area) }
        cursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)).set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        cursor(at: p).set()
        controller?.hover(atViewPoint: p)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        controller?.endHover()
    }

    override func scrollWheel(with event: NSEvent) {
        controller?.endHover()
        super.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        controller?.endHover()
        super.mouseDown(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    func cursor(at p: NSPoint) -> NSCursor {
        guard bounds.contains(p), let page = page(for: p, nearest: false) else { return .arrow }
        let pagePoint = convert(p, to: page)
        if AnnotationKit.noteBadge(at: pagePoint, on: page) != nil { return .pointingHand }
        if let a = page.annotation(at: pagePoint), AnnotationKit.kind(a) == "link" { return .pointingHand }
        return .iBeam
    }
}

final class ReaderWindowController: NSWindowController, NSWindowDelegate, PDFPageOverlayViewProvider {
    let pdfView = ReaderPDFView()
    let hud = HUDView()
    let pageCounter = PageCounterView()
    let markerViews = NSMapTable<PDFPage, NoteMarkerView>.weakToWeakObjects()
    var noteEditor: NoteEditor?
    var lastRecoloured: (targets: [PageAnnotation], time: Date)?
    var contextPoint: NSPoint?
    var contextTarget: PageAnnotation?
    /// The highlight just made with h, so that n, x and c apply to it without reselecting.
    var recentHighlight: PageAnnotation?
    var hoveredLink: PDFAnnotation?
    var previewWork: DispatchWorkItem?
    var linkPopover: NSPopover?
    var pasteboard = NSPasteboard.general
    var backStack: [Location] = []
    var forwardStack: [Location] = []
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var mouseDownPoint: NSPoint?
    private var lastQuery = ""
    private var searchAnchor: PDFSelection?
    private var overlay: NSView?
    private(set) var readerMode = false
    // The page view sits below the title bar normally and under it in reader mode.
    private var topBelowTitleBar: NSLayoutConstraint!
    private var topAtWindowEdge: NSLayoutConstraint!

    var pdfDoc: PDFDoc? { document as? PDFDoc }
    var pdf: PDFDocument? { pdfView.document }
    var undo: UndoManager? { pdfDoc?.undoManager }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 1000),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 320, height: 240)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        window.setFrameAutosaveName("SaltbushReader")

        let container = NSView()
        window.contentView = container
        for view in [pdfView, hud, pageCounter] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            // Messages appear at the bottom centre, clear of the find bar; the page counter sits bottom right.
            hud.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -76),
            pageCounter.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            pageCounter.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        pageCounter.isHidden = UserDefaults.standard.bool(forKey: "pageCounterOff")
        topBelowTitleBar = pdfView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor)
        topAtWindowEdge = pdfView.topAnchor.constraint(equalTo: container.topAnchor)
        topBelowTitleBar.isActive = true

        pdfView.controller = self
        pdfView.autoScales = true
        // One page per screen by default; the arrow keys turn pages.
        pdfView.displayMode = .singlePage
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = Self.surround
        pdfView.pageOverlayViewProvider = self
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                               name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged),
                                               name: .PDFViewSelectionChanged, object: pdfView)
        installMonitors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Called once the document has loaded (and again after a revert).
    func attach() {
        guard let pdf = pdfDoc?.pdf else { return }
        if pdf.isLocked && !unlock(pdf) {
            DispatchQueue.main.async { self.pdfDoc?.close() }
            return
        }
        pdfView.document = pdf
        applyReaderMode(UserDefaults.standard.bool(forKey: "readerMode"))
        // Themes use Core Image filters, which need the page view to be in its window first.
        applyTheme()
        DispatchQueue.main.async {
            self.updatePageCounter()
            self.restorePosition()
            self.window?.makeFirstResponder(self.pdfView)
            // The first time Saltbush opens, show what the keys do.
            if !UserDefaults.standard.bool(forKey: "shortcutsShown") {
                UserDefaults.standard.set(true, forKey: "shortcutsShown")
                self.showShortcuts()
            }
            #if DEBUG
            self.startTestScriptIfRequested()
            #endif
        }
    }

    private func unlock(_ pdf: PDFDocument) -> Bool {
        while true {
            let alert = NSAlert()
            alert.messageText = "This PDF is password-protected."
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if pdf.unlock(withPassword: field.stringValue) { return true }
        }
    }

    // MARK: Keyboard and mouse

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  !(window.firstResponder is NSText) else { return event }
            return self.handleKey(event) ? nil : event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .leftMouseDown {
                self.mouseDownPoint = event.locationInWindow
                self.recordJumpIfLink(atWindowPoint: event.locationInWindow)
                if let overlay = self.overlay,
                   !overlay.frame.contains(overlay.superview!.convert(event.locationInWindow, from: nil)) {
                    self.dismissOverlay()
                }
            } else if let start = self.mouseDownPoint, event.clickCount == 1, self.overlay == nil,
                      hypot(start.x - event.locationInWindow.x, start.y - event.locationInWindow.y) < 3 {
                let point = event.locationInWindow
                DispatchQueue.main.async { self.handleClick(at: point) }
            }
            return event
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        endHover()
        if overlay is ShortcutsView {
            dismissOverlay()
            return true
        }
        switch event.keyCode {
        case 53: // Escape
            recentHighlight = nil
            if overlay != nil { dismissOverlay() } else { pdfView.clearSelection() }
            return true
        case 51, 117: // Delete, Forward Delete
            removeAnnotations()
            return true
        case 49 where event.modifierFlags.contains(.shift): // Shift-Space
            scrollScreens(-1)
            return true
        case 124: // Right arrow: always the next page
            turnPage(forward: true)
            return true
        case 123: // Left arrow: always the previous page
            turnPage(forward: false)
            return true
        case 125 where !isContinuous: // Down arrow: scroll a zoomed page, otherwise turn it
            scrollLines(1)
            return true
        case 126 where !isContinuous: // Up arrow
            scrollLines(-1)
            return true
        default:
            break
        }
        guard let chars = event.characters, let index = Commands.byKey[chars] else { return false }
        NSCursor.setHiddenUntilMouseMoves(true)
        Commands.all[index].run(self)
        return true
    }

    @objc func performCommand(_ sender: NSMenuItem) {
        guard Commands.all.indices.contains(sender.tag) else { return }
        Commands.all[sender.tag].run(self)
    }

    /// Clicking a note circle opens the note; clicking a highlight selects it; clicking a sticky note opens it.
    private func handleClick(at windowPoint: NSPoint) {
        let point = pdfView.convert(windowPoint, from: nil)
        if let page = pdfView.page(for: point, nearest: false),
           let a = AnnotationKit.noteBadge(at: pdfView.convert(point, to: page), on: page) {
            editNote(a, on: page)
            return
        }
        guard let hit = annotation(atViewPoint: point) else { return }
        if AnnotationKit.isMarkup(hit.annotation) { select(hit.annotation, on: hit.page) }
        if AnnotationKit.isSticky(hit.annotation) { editNote(hit.annotation, on: hit.page) }
    }

    @objc private func selectionChanged() {
        if textSelection != nil { recentHighlight = nil }
    }

    /// Saltbush's own commands stand aside while you're typing in a note or the find bar,
    /// so ⌘↑, ⌘↓ and the rest do what they do in any text field.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(performCommand(_:)) else { return true }
        return noteEditor == nil && !(window?.firstResponder is NSText)
    }

    // MARK: Scrolling and pages

    private var scrollView: NSScrollView? { pdfView.documentView?.enclosingScrollView }

    func scrollLines(_ n: Int) {
        guard let sv = scrollView else { return }
        scroll(by: CGFloat(n) * 60 / max(sv.magnification, 0.01), animated: false)
    }

    func scrollScreens(_ fraction: CGFloat) {
        guard let sv = scrollView else { return }
        let height = sv.contentView.bounds.height
        let overlap = 48 / max(sv.magnification, 0.01)
        scroll(by: fraction * max(height - overlap, height * 0.5), animated: true)
    }

    /// In one-page-per-screen mode, scrolling past the edge of a page turns it,
    /// so space and the arrow keys read straight through a document.
    private func scroll(by dy: CGFloat, animated: Bool) {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let clip = sv.contentView
        var target = clip.bounds
        target.origin.y += doc.isFlipped ? dy : -dy
        target = clip.constrainBoundsRect(target)
        if !isContinuous, abs(target.origin.y - clip.bounds.origin.y) < 1 {
            turnPage(forward: dy > 0, landAtBottom: dy < 0)
            return
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                clip.animator().setBoundsOrigin(target.origin)
            }
        } else {
            clip.setBoundsOrigin(target.origin)
        }
        sv.reflectScrolledClipView(clip)
    }

    var isContinuous: Bool {
        pdfView.displayMode == .singlePageContinuous || pdfView.displayMode == .twoUpContinuous
    }

    func turnPage(forward: Bool, landAtBottom: Bool = false) {
        if forward {
            guard pdfView.canGoToNextPage else { return }
            pdfView.goToNextPage(nil)
        } else {
            guard pdfView.canGoToPreviousPage else { return }
            pdfView.goToPreviousPage(nil)
            // Scrolling up off the top of a zoomed page should arrive at the bottom of the one before.
            if landAtBottom { DispatchQueue.main.async { self.scrollToBottom() } }
        }
    }

    private func scrollToBottom() {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let clip = sv.contentView
        var target = clip.bounds
        target.origin.y = doc.isFlipped ? doc.bounds.maxY : doc.bounds.minY
        clip.setBoundsOrigin(clip.constrainBoundsRect(target).origin)
        sv.reflectScrolledClipView(clip)
    }

    var currentPageIndex: Int {
        guard let pdf, let page = pdfView.currentPage else { return 0 }
        return pdf.index(for: page)
    }

    func goToPageIndex(_ i: Int) {
        recordJump()
        guard let pdf, pdf.pageCount > 0, let page = pdf.page(at: min(max(i, 0), pdf.pageCount - 1)) else { return }
        pdfView.go(to: page)
    }

    func pageLabel(_ i: Int) -> String {
        "p. " + (pdf?.page(at: i)?.label ?? String(i + 1))
    }

    @objc private func pageChanged() {
        endHover()
        updatePageCounter()
        // With the counter switched off, flash the page number instead.
        if pageCounter.isHidden, let text = pageText { hud.show(text) }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(savePosition), object: nil)
        perform(#selector(savePosition), with: nil, afterDelay: 1)
    }

    /// "12 / 30", or "p. 245 · 12 / 30" when the printed page number differs.
    var pageText: String? {
        guard let pdf, let page = pdfView.currentPage else { return nil }
        let i = pdf.index(for: page) + 1
        if let label = page.label, label != String(i) { return "p. \(label)  ·  \(i) / \(pdf.pageCount)" }
        return "\(i) / \(pdf.pageCount)"
    }

    func updatePageCounter() {
        pageCounter.text = pageText ?? ""
    }

    func togglePageCounter() {
        pageCounter.isHidden.toggle()
        UserDefaults.standard.set(pageCounter.isHidden, forKey: "pageCounterOff")
        updatePageCounter()
        hud.show(pageCounter.isHidden ? "Page number off" : "Page number on")
    }

    // MARK: View modes

    func toggleReaderMode() {
        applyReaderMode(!readerMode)
        UserDefaults.standard.set(readerMode, forKey: "readerMode")
    }

    /// Reader mode: the window keeps its size and place, but loses its title bar,
    /// buttons and scroll bars, leaving only the pages.
    func applyReaderMode(_ on: Bool) {
        readerMode = on
        guard let window else { return }
        // The window never changes size; the pages simply extend into the title bar's space.
        topBelowTitleBar.isActive = !on
        topAtWindowEdge.isActive = on
        window.titlebarAppearsTransparent = on
        window.titleVisibility = on ? .hidden : .visible
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = on
        }
        if let sv = scrollView {
            sv.scrollerStyle = .overlay
            sv.hasVerticalScroller = !on
            sv.hasHorizontalScroller = !on
            sv.automaticallyAdjustsContentInsets = false
            sv.contentInsets = NSEdgeInsetsZero
        }
        refit()
    }

    /// Re-applies fit-to-window after the visible area changes size.
    private func refit() {
        guard pdfView.autoScales else { return }
        DispatchQueue.main.async {
            self.pdfView.autoScales = false
            self.pdfView.autoScales = true
        }
    }

    func toggleSpread() {
        let spread = pdfView.displayMode == .twoUp || pdfView.displayMode == .twoUpContinuous
        setDisplay(spread: !spread, continuous: isContinuous)
    }

    func toggleContinuous() {
        let spread = pdfView.displayMode == .twoUp || pdfView.displayMode == .twoUpContinuous
        setDisplay(spread: spread, continuous: !isContinuous)
        hud.show(isContinuous ? "Continuous scrolling" : "One page per screen")
    }

    private func setDisplay(spread: Bool, continuous: Bool) {
        pdfView.displayMode = spread ? (continuous ? .twoUpContinuous : .twoUp) : (continuous ? .singlePageContinuous : .singlePage)
        pdfView.autoScales = true
    }

    // MARK: Overlays

    enum Placement { case top, bottom, centre }

    private func present(_ view: NSView, at placement: Placement, width: CGFloat, height: CGFloat, focus: NSView) {
        dismissOverlay(restoreFocus: false)
        guard let container = window?.contentView else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        let preferredWidth = view.widthAnchor.constraint(equalToConstant: width)
        preferredWidth.priority = .defaultHigh
        let preferredHeight = view.heightAnchor.constraint(equalToConstant: height)
        preferredHeight.priority = .defaultHigh
        let vertical: NSLayoutConstraint
        switch placement {
        case .top: vertical = view.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 16)
        case .bottom: vertical = view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24)
        case .centre: vertical = view.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        }
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            preferredWidth,
            view.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32),
            preferredHeight,
            view.heightAnchor.constraint(lessThanOrEqualTo: container.heightAnchor, constant: -32),
            vertical,
        ])
        overlay = view
        window?.makeFirstResponder(focus)
    }

    func dismissOverlay(restoreFocus: Bool = true) {
        overlay?.removeFromSuperview()
        overlay = nil
        if restoreFocus { window?.makeFirstResponder(pdfView) }
    }

    private func showPrompt(_ label: String, initial: String, staysOpen: Bool = false, onChange: ((String) -> Void)?,
                            onSubmit: @escaping (String, Bool) -> Void) {
        let bar = PromptBar(label: label, text: initial)
        bar.onChange = onChange
        bar.onSubmit = { [weak self] text, shift in
            if !staysOpen { self?.dismissOverlay() }
            onSubmit(text, shift)
        }
        bar.onCancel = { [weak self] in self?.dismissOverlay() }
        present(bar, at: .bottom, width: 440, height: 40, focus: bar.field)
        bar.field.currentEditor()?.selectAll(nil)
    }

    private func showPalette(_ placeholder: String, items: [PaletteView.Item], selected: Int = 0) {
        let palette = PaletteView(placeholder: placeholder, items: items, selected: selected)
        palette.onPick = { [weak self] item in
            self?.dismissOverlay()
            item.run()
        }
        palette.onCancel = { [weak self] in self?.dismissOverlay() }
        let height = CGFloat(min(items.count, 12)) * PaletteView.rowHeight + 60
        present(palette, at: .top, width: 620, height: height, focus: palette.field)

    }

    /// The keyboard shortcuts sheet. Any key or a click outside closes it.
    func showShortcuts() {
        present(ShortcutsView(), at: .centre, width: 820, height: 640, focus: pdfView)
    }

    // MARK: Find and go to page

    func beginFind() {
        recordJump()
        searchAnchor = pdfView.currentPage?.selection(for: NSRange(location: 0, length: 1))
        // Return and ⇧Return step through matches; Esc closes and leaves the match selected for h.
        showPrompt("Find", initial: lastQuery, staysOpen: true, onChange: { [weak self] query in
            self?.lastQuery = query
            self?.findLive(query)
        }, onSubmit: { [weak self] query, shift in
            guard let self else { return }
            self.lastQuery = query
            self.findNext(backwards: shift)
        })
    }

    /// Smart case: an all-lowercase query ignores case.
    private func searchOptions(_ query: String, backwards: Bool = false) -> NSString.CompareOptions {
        var options: NSString.CompareOptions = [.diacriticInsensitive]
        if query == query.lowercased() { options.insert(.caseInsensitive) }
        if backwards { options.insert(.backwards) }
        return options
    }

    private func findLive(_ query: String) {
        guard let pdf, !query.isEmpty else {
            pdfView.clearSelection()
            return
        }
        let options = searchOptions(query)
        reveal(pdf.findString(query, fromSelection: searchAnchor, withOptions: options)
            ?? pdf.findString(query, fromSelection: nil, withOptions: options))
    }

    func findNext(backwards: Bool) {
        guard let pdf, !lastQuery.isEmpty else {
            beginFind()
            return
        }
        let options = searchOptions(lastQuery, backwards: backwards)
        let from = pdfView.currentSelection ?? pdfView.currentPage?.selection(for: NSRange(location: 0, length: 1))
        reveal(pdf.findString(lastQuery, fromSelection: from, withOptions: options)
            ?? pdf.findString(lastQuery, fromSelection: nil, withOptions: options))
    }

    private func reveal(_ selection: PDFSelection?) {
        guard let selection else {
            hud.show("Not found")
            return
        }
        pdfView.setCurrentSelection(selection, animate: false)
        pdfView.go(to: selection)
    }

    func promptPage() {
        showPrompt("Page", initial: "", onChange: nil) { [weak self] text, _ in self?.goToPage(label: text) }
    }

    /// Accepts the printed page label (e.g. "245" in a journal article) before the physical page number.
    private func goToPage(label: String) {
        guard let pdf else { return }
        let target = label.trimmed
        if let i = (0..<pdf.pageCount).first(where: { pdf.page(at: $0)?.label == target }) {
            goToPageIndex(i)
        } else if let n = Int(target) {
            goToPageIndex(n - 1)
        } else {
            hud.show("No page \(target)")
        }
    }

    // MARK: Palettes

    func showCommandPalette() {
        showPalette("Command", items: Commands.all.map { cmd in
            PaletteView.Item(title: cmd.title, detail: cmd.hint) { [weak self] in
                if let self { cmd.run(self) }
            }
        })
    }

    func showOutline() {
        guard let pdf, let root = pdf.outlineRoot, root.numberOfChildren > 0 else {
            hud.show("This PDF has no contents")
            return
        }
        var items: [PaletteView.Item] = []
        var selected = 0
        let current = currentPageIndex
        func walk(_ node: PDFOutline, depth: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                let pageIndex = destination?.page.map { pdf.index(for: $0) }
                if let pageIndex, pageIndex <= current { selected = items.count }
                let title = String(repeating: "     ", count: depth) + (child.label ?? "Untitled")
                items.append(PaletteView.Item(title: title, detail: pageIndex.map(pageLabel) ?? "") { [weak self] in
                    if let destination {
                        self?.recordJump()
                        self?.pdfView.go(to: destination)
                    }
                })
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        showPalette("Contents", items: items, selected: selected)
    }

    func showAnnotations() {
        guard let pdf else { return }
        var items: [PaletteView.Item] = []
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            for a in page.annotations where AnnotationKit.isMarkup(a) || AnnotationKit.isNote(a) {
                let note = (a.contents ?? "").trimmed.split(whereSeparator: \.isNewline).joined(separator: " ")
                let quote = AnnotationKit.isMarkup(a) ? AnnotationKit.quotedText(of: a, on: page) : ""
                let title = note.isEmpty ? "“\(quote)”" : note
                let detail = note.isEmpty || quote.isEmpty ? pageLabel(i) : "“\(quote)”   \(pageLabel(i))"
                items.append(PaletteView.Item(title: title, detail: detail) { [weak self] in
                    self?.revealAnnotation(a, on: page)
                })
            }
        }
        guard !items.isEmpty else {
            hud.show("No highlights or notes yet")
            return
        }
        showPalette("Highlights and notes", items: items)
    }

    func showRecent() {
        let urls = NSDocumentController.shared.recentDocumentURLs
        guard !urls.isEmpty else {
            hud.show("No recent documents")
            return
        }
        showPalette("Open recent", items: urls.map { url in
            PaletteView.Item(title: url.deletingPathExtension().lastPathComponent,
                             detail: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath) {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            }
        })
    }

    // MARK: Remembering your place

    @objc func savePosition() {
        guard let url = pdfDoc?.fileURL, let pdf, let destination = pdfView.currentDestination,
              let page = destination.page else { return }
        var all = UserDefaults.standard.dictionary(forKey: "positions") ?? [:]
        all[url.path] = [
            "page": pdf.index(for: page),
            "x": Double(destination.point.x),
            "y": Double(destination.point.y),
            "scale": Double(pdfView.scaleFactor),
            "auto": pdfView.autoScales,
            "mode": pdfView.displayMode.rawValue,
        ] as [String: Any]
        UserDefaults.standard.set(all, forKey: "positions")
    }

    private func restorePosition() {
        guard let url = pdfDoc?.fileURL, let pdf,
              let entry = UserDefaults.standard.dictionary(forKey: "positions")?[url.path] as? [String: Any],
              let index = entry["page"] as? Int, index < pdf.pageCount, let page = pdf.page(at: index) else { return }
        if let raw = entry["mode"] as? Int, let mode = PDFDisplayMode(rawValue: raw) { pdfView.displayMode = mode }
        if entry["auto"] as? Bool == false, let scale = entry["scale"] as? Double { pdfView.scaleFactor = scale }
        let x = entry["x"] as? Double ?? 0, y = entry["y"] as? Double ?? 0
        if abs(x) < 1e6, abs(y) < 1e6 {
            pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: x, y: y)))
        } else {
            pdfView.go(to: page)
        }
    }

    // MARK: NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }

    func windowWillClose(_ notification: Notification) {
        savePosition()
        for monitor in [keyMonitor, mouseMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        mouseMonitor = nil
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let marker = NoteMarkerView(page: page, box: page.bounds(for: view.displayBox))
        markerViews.setObject(marker, forKey: page)
        return marker
    }
}
