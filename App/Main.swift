import AppKit

@main
enum GlancemarkApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        _ = NSDocumentController.shared
        app.mainMenu = makeMenus()
        app.run()
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
        file.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
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
        NSApp.windowsMenu = window
        for submenu in [application, file, edit, window] {
            let item = NSMenuItem()
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }
}
