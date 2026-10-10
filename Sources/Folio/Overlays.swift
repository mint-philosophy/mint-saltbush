import AppKit
import FolioCore
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

/// The note editor. Return or Escape saves and closes; Shift-Return starts a new line.
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
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 340, height: 130)
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        textView = scroll.documentView as? NSTextView
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
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                popover.performClose(nil)
            }
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

/// Draws a small dot at the end of each highlight that carries a note.
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
        for a in page.annotations where AnnotationKit.isMarkup(a) && !(a.contents ?? "").trimmed.isEmpty {
            // The last line: lowest on the page, then furthest right.
            guard let line = AnnotationKit.rects(of: a).min(by: { ($0.minY, -$0.maxX) < ($1.minY, -$1.maxX) }) else { continue }
            let r: CGFloat = 3
            let centre = NSPoint(x: (line.maxX - box.minX + r + 1.5) * sx, y: (line.maxY - box.minY - r) * sy)
            let colour = (a.color.usingColorSpace(.sRGB) ?? a.color).blended(withFraction: 0.45, of: .black) ?? .systemOrange
            colour.setFill()
            NSBezierPath(ovalIn: NSRect(x: centre.x - r * sx, y: centre.y - r * sy, width: 2 * r * sx, height: 2 * r * sy)).fill()
        }
    }
}
