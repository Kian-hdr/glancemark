import AppKit
import CoreServices

@main
enum GlancemarkApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = GlancemarkAppDelegate()
        app.delegate = delegate
        NSWindow.allowsAutomaticWindowTabbing = true
        _ = NSDocumentController.shared
        app.mainMenu = makeMenus()
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor private static func makeMenus() -> NSMenu {
        let menu = NSMenu()
        let application = NSMenu()
        application.addItem(withTitle: "About Glancemark", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        application.addItem(.separator())
        let settings = application.addItem(withTitle: "Settings…", action: #selector(AppearanceSettingsController.show(_:)), keyEquivalent: ",")
        settings.target = AppearanceSettingsController.shared
        application.addItem(.separator())
        application.addItem(withTitle: "Quit Glancemark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Tab", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "t")
        let newWindow = file.addItem(withTitle: "New Window", action: #selector(GlancemarkAppDelegate.newWindow(_:)), keyEquivalent: "n")
        newWindow.target = NSApp.delegate
        file.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        file.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"),
            ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")
        ] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(.separator())
        window.addItem(withTitle: "Move Tab to New Window", action: #selector(NSWindow.moveTabToNewWindow(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        for submenu in [application, file, edit, window] {
            let item = NSMenuItem()
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }
}

private final class GlancemarkAppDelegate: NSObject, NSApplicationDelegate {
    @objc func newWindow(_ sender: Any?) {
        do {
            let document = try NSDocumentController.shared.openUntitledDocumentAndDisplay(false)
            (document as? MarkdownDocument)?.showInNewWindow()
        } catch {
            NSApp.presentError(error)
        }
    }

    private var isLoginEvent: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
                == AEKeyword(keyAELaunchedAsLogInItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginSettings.shared.configureDefault()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !isLoginEvent
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            NSDocumentController.shared.newDocument(nil)
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard LoginSettings.shared.isEnabled else { return true }
        sender.setActivationPolicy(.accessory)
        return false
    }
}
