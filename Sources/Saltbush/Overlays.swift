import AppKit
import SaltbushCore
import PDFKit

private func styleAsPanel(_ view: NSVisualEffectView, radius: CGFloat) {
    view.material = .popover
    view.blendingMode = .withinWindow
    view.state = .active
    view.wantsLayer = true
    view.layer?.cornerRadius = radius
    view.layer?.masksToBounds = true
}

private func plainField(_ field: NSTextField, size: CGFloat) {
    field.font = .systemFont(ofSize: size)
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.usesSingleLineMode = true
    field.cell?.isScrollable = true
    field.cell?.wraps = false
}

/// A small label in the corner that fades out: page numbers, confirmations.
final class HUDView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private var generation = 0

    init() {
        super.init(frame: .zero)
        styleAsPanel(self, radius: 7)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, for seconds: TimeInterval = 1.1) {
        label.stringValue = text
        alphaValue = 1
        generation += 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == current else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self.animator().alphaValue = 0
            }
        }
    }
}

/// The page number in the bottom-right corner. On by default; it fades away while
/// the pointer is over it, so it never hides the text beneath.
final class PageCounterView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        styleAsPanel(self, radius: 7)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Clicks pass through to the page.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) { fade(to: 0) }
    override func mouseExited(with event: NSEvent) { fade(to: 1) }

    private func fade(to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            animator().alphaValue = alpha
        }
    }
}

/// A one-line input at the bottom of the window, used by Find and Go to Page.
final class PromptBar: NSVisualEffectView, NSTextFieldDelegate {
    let field = NSTextField()
    var onChange: ((String) -> Void)?
    var onSubmit: ((String, Bool) -> Void)?
    var onCancel: (() -> Void)?

    init(label: String, text: String) {
        super.init(frame: .zero)
        styleAsPanel(self, radius: 10)
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.setContentHuggingPriority(.required, for: .horizontal)
        plainField(field, size: 15)
        field.stringValue = text
        field.delegate = self
        let stack = NSStackView(views: [title, field])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            onSubmit?(field.stringValue, NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}

/// A filterable list: commands, contents, highlights and notes, recent files.
final class PaletteView: NSVisualEffectView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        let title: String
        let detail: String
        let run: () -> Void
    }

    static let rowHeight: CGFloat = 28
    let field = NSTextField()
    var onPick: ((Item) -> Void)?
    var onCancel: (() -> Void)?
    private let table = NSTableView()
    private let items: [Item]
    private var shown: [Item]

    init(placeholder: String, items: [Item], selected: Int) {
        self.items = items
        self.shown = items
        super.init(frame: .zero)
        styleAsPanel(self, radius: 12)

        plainField(field, size: 16)
        field.placeholderString = placeholder
        field.delegate = self

        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let divider = NSBox()
        divider.boxType = .separator
        for view in [field, divider, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            divider.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        table.reloadData()
        DispatchQueue.main.async { self.select(selected) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? PaletteRow ?? PaletteRow(identifier: id)
        cell.show(shown[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { EmphasisedRow() }

    func controlTextDidChange(_ obj: Notification) {
        let tokens = field.stringValue.lowercased().split(separator: " ").map(String.init)
        shown = tokens.isEmpty ? items : items.filter { item in
            let haystack = (item.title + " " + item.detail).lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
        table.reloadData()
        select(0)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            select(table.selectedRow - 1)
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            select(table.selectedRow + 1)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            select(table.selectedRow - 10)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            select(table.selectedRow + 10)
        case #selector(NSResponder.insertNewline(_:)):
            pick(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
        default:
            return false
        }
        return true
    }

    @objc private func clicked() { pick(table.clickedRow) }

    private func pick(_ row: Int) {
        guard shown.indices.contains(row) else { return }
        onPick?(shown[row])
    }

    private func select(_ row: Int) {
        guard !shown.isEmpty else { return }
        let r = min(max(row, 0), shown.count - 1)
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }
}

/// Keeps the palette's selection blue while focus stays in the filter field.
private final class EmphasisedRow: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

private final class PaletteRow: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.alignment = .right
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 16),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: PaletteView.Item) {
        title.stringValue = item.title
        detail.stringValue = item.detail
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            title.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
            detail.textColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        }
    }
}

/// Text view for notes: standard editing keys throughout; ⌘Return saves and closes.
final class NoteTextView: NSTextView {
    var onDone: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            onDone?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The note editor. It edits like any Mac text field (Return is a new line, ⌥/⌘ arrows move
/// by word and line); Esc or ⌘Return saves and closes, as does clicking elsewhere.
final class NoteEditor: NSViewController, NSTextViewDelegate, NSPopoverDelegate {
    let popover = NSPopover()
    var onCommit: ((String) -> Void)?
    private let initialText: String
    private var textView: NSTextView!
    /// Typing undo stays inside the editor rather than mixing into the document's history.
    private let typingUndo = UndoManager()

    init(text: String) {
        initialText = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 150))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let noteView = NoteTextView(frame: scroll.contentView.bounds)
        noteView.minSize = .zero
        noteView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        noteView.isVerticallyResizable = true
        noteView.isHorizontallyResizable = false
        noteView.autoresizingMask = [.width]
        noteView.textContainer?.widthTracksTextView = true
        noteView.onDone = { [weak self] in self?.popover.performClose(nil) }
        scroll.documentView = noteView
        textView = noteView
        textView.string = initialText
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.delegate = self
        view = scroll
        preferredContentSize = scroll.frame.size
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        popover.contentViewController = self
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    func undoManager(for view: NSTextView) -> UndoManager? { typingUndo }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            popover.performClose(nil)
            return true
        default:
            return false
        }
    }

    func popoverDidClose(_ notification: Notification) {
        let commit = onCommit
        onCommit = nil
        commit?(textView.string)
    }
}

/// Draws a circle in the margin beside each highlight that carries a note; click it to open the note.
/// This is the only on-page sign of a note: no margin bars, no reflowed margins.
final class NoteMarkerView: NSView {
    private weak var page: PDFPage?
    private let box: NSRect

    init(page: PDFPage, box: NSRect) {
        self.page = page
        self.box = box
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let page, box.width > 0, box.height > 0 else { return }
        let sx = bounds.width / box.width, sy = bounds.height / box.height
        for a in page.annotations where AnnotationKit.hasNote(a) {
            guard let r = AnnotationKit.noteBadgeRect(for: a, on: page) else { continue }
            let circle = NSBezierPath(ovalIn: NSRect(x: (r.minX - box.minX) * sx, y: (r.minY - box.minY) * sy,
                                                     width: r.width * sx, height: r.height * sy).insetBy(dx: 0.75, dy: 0.75))
            let colour = a.color.usingColorSpace(.sRGB) ?? a.color
            colour.setFill()
            circle.fill()
            (colour.blended(withFraction: 0.45, of: .black) ?? .gray).setStroke()
            circle.lineWidth = 1.2
            circle.stroke()
        }
    }
}

/// Every keyboard shortcut on one sheet, grouped. Shown on first launch and with ? or ⌘/.
/// Keys come from the command table, so the sheet stays in step with the app.
final class ShortcutsView: NSVisualEffectView {
    private static let layout: [[(group: String, titles: [String])]] = [
        [("Move around", ["Next Page", "Previous Page", "Screen Down", "Screen Up", "First Page", "Last Page",
                          "Go to Page…", "Previous Location", "Next Location"]),
         ("Search", ["Find…", "Find Next", "Find Previous"])],
        [("Highlights and notes", ["Highlight", "Add or Edit Note", "Remove Highlight", "Change Colour",
                                   "Copy Highlights and Notes", "Export Highlights and Notes…"]),
         ("Lists", ["Contents…", "Highlights and Notes…", "Recent Documents…", "All Commands"]),
         ("View", ["Reader Mode", "Page Number", "Change Theme", "Continuous Scrolling", "Two-Page Spread", "Zoom In", "Zoom Out", "Fit to Window",
                   "Full Screen", "Keyboard Shortcuts"])],
    ]

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        let byTitle = Dictionary(Commands.all.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        let title = NSTextField(labelWithString: "Keyboard shortcuts")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Press ? at any time to see this again. Press any key to close.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        let columns = Self.layout.map { groups -> NSStackView in
            let column = NSStackView(views: groups.map { Self.section($0.group, $0.titles.compactMap { byTitle[$0] }) })
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 18
            return column
        }
        let body = NSStackView(views: columns)
        body.orientation = .horizontal
        body.alignment = .top
        body.distribution = .fillEqually
        body.spacing = 36

        let tips = NSTextField(wrappingLabelWithString:
            "Select text, then press h to highlight it and n to add a note. In a note, Return starts a new line and Esc saves. "
            + "In search, Return and ⇧Return step through matches; Esc closes and leaves the match selected. "
            + "Click a note's circle in the margin to open it; right-click it to delete. "
            + "Hover over a citation or footnote to preview what it points to.")
        tips.font = .systemFont(ofSize: 12)
        tips.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, subtitle, body, tips])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(22, after: subtitle)
        stack.setCustomSpacing(22, after: body)
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 30, bottom: 26, right: 30)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -60),
            tips.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func section(_ name: String, _ commands: [Command]) -> NSView {
        let header = NSTextField(labelWithString: name.uppercased())
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .tertiaryLabelColor
        let rows = commands.map { cmd -> [NSView] in
            let keys = NSTextField(labelWithString: cmd.primaryHint)
            keys.font = .systemFont(ofSize: 13, weight: .semibold)
            let label = NSTextField(labelWithString: cmd.title.replacingOccurrences(of: "…", with: ""))
            label.font = .systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
            return [keys, label]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 5
        grid.columnSpacing = 14
        grid.column(at: 0).width = 150
        // Fixed row heights; otherwise the grid hands spare height to its first row.
        for i in 0..<grid.numberOfRows { grid.row(at: i).height = 20 }
        grid.yPlacement = .center
        grid.setContentHuggingPriority(.required, for: .vertical)
        let section = NSStackView(views: [header, grid])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        return section
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
