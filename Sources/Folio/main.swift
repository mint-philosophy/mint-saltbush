import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MenuBuilder.mainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched without a file: go straight to the open panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if NSDocumentController.shared.documents.isEmpty {
                NSDocumentController.shared.openDocument(nil)
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

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
