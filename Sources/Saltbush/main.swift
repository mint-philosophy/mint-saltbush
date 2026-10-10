import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        migrateSettingsFromFolio()
        NSApp.mainMenu = MenuBuilder.mainMenu()
    }

    /// Saltbush was called Folio until October 2026. Bring its settings across once.
    private func migrateSettingsFromFolio() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromFolio"),
              let old = UserDefaults(suiteName: "org.mintresearch.folio") else { return }
        for key in ["positions", "readerMode", "theme", "highlightColour", "shortcutsShown"] {
            if let value = old.object(forKey: key), defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
        if let frame = old.string(forKey: "NSWindow Frame FolioReader") {
            defaults.set(frame, forKey: "NSWindow Frame SaltbushReader")
        }
        defaults.set(true, forKey: "migratedFromFolio")
    }

    // AppKit asks for an untitled document only when Saltbush launches with no file
    // and no restored windows; show the open panel instead.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.openDocument(nil)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.openDocument(nil) }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        for doc in NSDocumentController.shared.documents {
            for case let controller as ReaderWindowController in doc.windowControllers { controller.savePosition() }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
