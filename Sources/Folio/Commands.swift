import AppKit

/// Every action in Folio, in one table. The bare-key map, the menus, and the
/// command palette are all built from this list, so they can't drift apart.
struct Command {
    let title: String
    /// Bare key (no modifiers) that runs the command in the reading view.
    let key: String?
    let extraHint: String?
    let menu: String?
    let equivalent: String
    let modifiers: NSEvent.ModifierFlags
    let run: @MainActor (ReaderWindowController, Int?) -> Void

    init(_ title: String, key: String? = nil, hint: String? = nil, menu: String? = nil,
         _ equivalent: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
         run: @escaping @MainActor (ReaderWindowController, Int?) -> Void) {
        self.title = title
        self.key = key
        self.extraHint = hint
        self.menu = menu
        self.equivalent = equivalent
        self.modifiers = modifiers
        self.run = run
    }

    var hint: String {
        var parts: [String] = []
        if let key { parts.append(key == " " ? "space" : key) }
        if let extraHint { parts.append(extraHint) }
        if !equivalent.isEmpty { parts.append(Self.describe(equivalent, modifiers)) }
        return parts.joined(separator: "    ")
    }

    static func describe(_ key: String, _ mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        switch key.unicodeScalars.first?.value ?? 0 {
        case 0x08: s += "⌫"
        case 0xF700: s += "↑"
        case 0xF701: s += "↓"
        default: s += key.uppercased()
        }
        return s
    }
}

@MainActor
enum Commands {
    static let all: [Command] = [
        Command("Scroll Down", key: "j") { c, n in c.scrollLines(n ?? 1) },
        Command("Scroll Up", key: "k") { c, n in c.scrollLines(-(n ?? 1)) },
        Command("Half Screen Down", key: "d") { c, _ in c.scrollScreens(0.5) },
        Command("Half Screen Up", key: "u") { c, _ in c.scrollScreens(-0.5) },
        Command("Screen Down", key: " ") { c, _ in c.scrollScreens(1) },
        Command("Screen Up", hint: "⇧space") { c, _ in c.scrollScreens(-1) },
        Command("Next Page", key: "J", hint: "→", menu: "Go") { c, n in c.goToPageIndex(c.currentPageIndex + (n ?? 1)) },
        Command("Previous Page", key: "K", hint: "←", menu: "Go") { c, n in c.goToPageIndex(c.currentPageIndex - (n ?? 1)) },
        Command("First Page", hint: "gg", menu: "Go", "\u{F700}") { c, _ in c.goToPageIndex(0) },
        Command("Last Page", key: "G", hint: "12G = page 12", menu: "Go", "\u{F701}") { c, n in
            c.goToPageIndex(n.map { $0 - 1 } ?? Int.max)
        },
        Command("Go to Page…", key: ":", menu: "Go", "g", [.command, .option]) { c, _ in c.promptPage() },
        Command("Back", menu: "Go", "[") { c, _ in c.pdfView.goBack(nil) },
        Command("Forward", menu: "Go", "]") { c, _ in c.pdfView.goForward(nil) },
        Command("Contents…", key: "t", menu: "Go", "t", [.command, .option]) { c, _ in c.showOutline() },
        Command("Highlights and Notes…", key: ";", menu: "Go", "a", [.command, .option]) { c, _ in c.showAnnotations() },
        Command("Recent Documents…", key: "o", menu: "File", "o", [.command, .shift]) { c, _ in c.showRecent() },
        Command("Find…", key: "/", menu: "Edit", "f") { c, _ in c.beginFind() },
        Command("Find Next", key: "n", menu: "Edit", "g") { c, _ in c.findNext(backwards: false) },
        Command("Find Previous", key: "N", menu: "Edit", "g", [.command, .shift]) { c, _ in c.findNext(backwards: true) },
        Command("Highlight", key: "h", menu: "Annotate", "h", [.control, .command]) { c, _ in c.highlightSelection() },
        Command("Add or Edit Note", key: "a", menu: "Annotate", "n", [.control, .command]) { c, _ in c.addOrEditNote() },
        Command("Remove Highlight", key: "x", hint: "⌫", menu: "Annotate", "\u{8}", [.control, .command]) { c, _ in
            c.removeAnnotations()
        },
        Command("Change Colour", key: "c", menu: "Annotate") { c, _ in c.cycleColour() },
        Command("Reader Mode", key: "r", menu: "View", "r", [.command, .shift]) { c, _ in c.toggleReaderMode() },
        Command("Zoom In", key: "+", menu: "View", "=") { c, _ in c.pdfView.zoomIn(nil) },
        Command("Zoom Out", key: "-", menu: "View", "-") { c, _ in c.pdfView.zoomOut(nil) },
        Command("Fit to Window", key: "=", menu: "View", "0") { c, _ in c.pdfView.autoScales = true },
        Command("Two-Page Spread", key: "s", menu: "View", "2") { c, _ in c.toggleSpread() },
        Command("Continuous Scrolling", key: "w", menu: "View", "1") { c, _ in c.toggleContinuous() },
        Command("Full Screen", key: "f", hint: "⌃⌘F") { c, _ in c.window?.toggleFullScreen(nil) },
        Command("All Commands", key: "?", menu: "Help", "p", [.command, .shift]) { c, _ in c.showCommandPalette() },
    ]

    static let byKey: [String: Int] = {
        var map: [String: Int] = [:]
        for (i, c) in all.enumerated() { if let k = c.key { map[k] = i } }
        return map
    }()
}

@MainActor
enum MenuBuilder {
    static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }

        let app = submenu("Folio")
        app.addItem(withTitle: "About Folio", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Folio", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Folio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu("File")
        file.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let recent = NSMenu(title: "Open Recent")
        recent.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "").submenu = recent
        addCommands(in: "File", to: file)
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")

        let edit = submenu("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        addCommands(in: "Edit", to: edit)

        for name in ["View", "Go", "Annotate"] { addCommands(in: name, to: submenu(name)) }

        let window = submenu("Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        let help = submenu("Help")
        addCommands(in: "Help", to: help)
        NSApp.helpMenu = help
        return main
    }

    private static func addCommands(in menuName: String, to menu: NSMenu) {
        for (i, cmd) in Commands.all.enumerated() where cmd.menu == menuName {
            let item = NSMenuItem(title: cmd.title, action: #selector(ReaderWindowController.performCommand(_:)),
                                  keyEquivalent: cmd.equivalent)
            item.keyEquivalentModifierMask = cmd.modifiers
            item.tag = i
            menu.addItem(item)
        }
    }
}
