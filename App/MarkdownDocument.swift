import AppKit
import GlancemarkCore
import SwiftUI

final class DocumentContent: ObservableObject {
    @Published var source = MarkdownSource(text: "")
    @Published var fileURL: URL? {
        didSet {
            if fileURL != oldValue {
                repositoryRoot = fileURL.flatMap(RepositoryLinks.nearestRepositoryRoot(for:))
                wikiRoot = fileURL.flatMap(RepositoryLinks.nearestWikiRoot(for:))
            }
        }
    }
    private(set) var repositoryRoot: URL?
    @Published var wikiRoot: URL?
    @Published var fragment: String?
    @Published var navigatorRoot: URL?
    @Published var breadcrumbRoot: URL?
    @Published var hasExternalConflict = false
}

final class MarkdownDocument: NSDocument {
    let content = DocumentContent()
    private var baseline: Data?
    private var hasPresentedWindow = false
    let editorUndo = UndoManager()

    override init() {
        super.init()
        // TextKit owns undo grouping; edits update the document count from saved bytes.
        hasUndoManager = false
    }

    override class var autosavesInPlace: Bool { true }

    override var fileURL: URL? {
        didSet { content.fileURL = fileURL }
    }

    override func read(from data: Data, ofType typeName: String) throws {
        content.source = try MarkdownSource(bytes: data)
        baseline = data
        content.hasExternalConflict = false
    }

    override func data(ofType typeName: String) throws -> Data {
        content.source.bytes
    }

    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        let next = content.source.bytes
        let inPlace = sameDocument(as: url)
        if inPlace, let baseline {
            // Check the real destination before AppKit starts a safe replacement.
            // The lower-level write method can receive a temporary URL.
            let disk = try? Data(contentsOf: url)
            if disk == next {
                self.baseline = next
                setExternalConflict(false)
                return
            }
            guard disk == baseline else {
                setExternalConflict(true)
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSLocalizedDescriptionKey: "This file changed outside Glancemark.",
                                         NSLocalizedRecoverySuggestionErrorKey: "Reload the disk version or save your edits as a copy."])
            }
        }
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        if saveOperation == .saveOperation || saveOperation == .saveAsOperation || saveOperation == .autosaveInPlaceOperation {
            baseline = next
            setExternalConflict(false)
        }
    }

    private func sameDocument(as url: URL) -> Bool {
        fileURL?.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func setExternalConflict(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.content.hasExternalConflict = value
        }
    }

    private func reloadDiskVersion() {
        guard let url = fileURL, let type = fileType else { return }
        let alert = NSAlert()
        alert.messageText = "Reload the disk version?"
        alert.informativeText = "Reloading discards the unsaved edits in this window."
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Cancel")
        let reload: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try self.revert(toContentsOf: url, ofType: type)
                self.editorUndo.removeAllActions()
                self.updateChangeCount(.changeCleared)
            } catch {
                self.presentError(error)
            }
        }
        if let window = windowForSheet { alert.beginSheetModal(for: window, completionHandler: reload) }
        else { reload(alert.runModal()) }
    }

    private func saveConflictCopy() {
        guard let url = fileURL, let type = fileType else { return }
        let panel = NSSavePanel()
        panel.directoryURL = url.deletingLastPathComponent()
        let suffix = url.pathExtension.isEmpty ? "md" : url.pathExtension
        panel.nameFieldStringValue = "\(url.deletingPathExtension().lastPathComponent) Copy.\(suffix)"
        let save: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            guard !self.sameDocument(as: destination) else {
                self.presentError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                          userInfo: [NSLocalizedDescriptionKey: "Choose a different file for the copy."]))
                return
            }
            self.save(to: destination, ofType: type, for: .saveToOperation) { error in
                if let error { self.presentError(error) }
            }
        }
        if let window = windowForSheet { panel.beginSheetModal(for: window, completionHandler: save) }
        else { save(panel.runModal()) }
    }

    func applyEditorText(_ text: String) {
        var source = content.source
        guard !text.utf8.elementsEqual(source.text.utf8) else { return }
        do {
            try source.replace(NSRange(location: 0, length: (source.text as NSString).length), with: text)
            content.source = source
            updateChangeCount(source.bytes == (baseline ?? Data()) ? .changeCleared : .changeDone)
        } catch {
            presentError(error)
        }
    }

    override func showWindows() {
        let source = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
            .first(where: { $0 is MarkdownDocumentWindow })
            ?? NSApp.orderedWindows.first(where: { $0 is MarkdownDocumentWindow && $0.isVisible })
        showAsTab(beside: source)
    }

    func showAsTab(beside source: NSWindow?) {
        if windowControllers.isEmpty { makeWindowControllers() }
        if !hasPresentedWindow, let source, let window = windowControllers.first?.window,
           source.isVisible, source != window, !window.isVisible, (window.tabbedWindows?.count ?? 0) < 2 {
            source.addTabbedWindow(window, ordered: .above)
        }
        presentWindows()
    }

    func showInNewWindow() {
        if windowControllers.isEmpty { makeWindowControllers() }
        let window = windowControllers.first?.window
        window?.tabbingMode = .disallowed
        presentWindows()
        window?.tabbingMode = .preferred
    }

    private func presentWindows() {
        hasPresentedWindow = true
        NSApp.setActivationPolicy(.regular)
        super.showWindows()
        (windowControllers.first?.window as? MarkdownDocumentWindow)?.keepTabBarVisible()
    }

    override func makeWindowControllers() {
        let root = DocumentView(content: content, undo: editorUndo, reload: { [weak self] in self?.reloadDiskVersion() },
                                saveCopy: { [weak self] in self?.saveConflictCopy() },
                                documentWindow: { [weak self] in self?.windowControllers.first?.window },
                                edit: { [weak self] in self?.applyEditorText($0) })
        let window = MarkdownDocumentWindow(contentViewController: NSHostingController(rootView: root))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.tabbingIdentifier = "GlancemarkDocument"
        window.tabbingMode = .preferred
        window.setContentSize(NSSize(width: 880, height: 680))
        window.center()
        addWindowController(NSWindowController(window: window))
    }
}

private final class MarkdownDocumentWindow: NSWindow {
    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabGroupObservation: NSKeyValueObservation?

    override func becomeKey() {
        super.becomeKey()
        keepTabBarVisible()
    }

    func keepTabBarVisible() {
        // AppKit can replace the tab group while a native drag finishes.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tabbingMode != .disallowed, let group = self.tabGroup else { return }
            if self.observedTabGroup !== group {
                self.observedTabGroup = group
                self.tabGroupObservation = group.observe(\.windows, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.keepTabBarVisible() }
                }
            }
            if self.isVisible, !group.isTabBarVisible { self.toggleTabBar(nil) }
        }
    }

    override func newWindowForTab(_ sender: Any?) {
        do {
            let document = try NSDocumentController.shared.openUntitledDocumentAndDisplay(false)
            (document as? MarkdownDocument)?.showAsTab(beside: self)
        } catch {
            NSApp.presentError(error)
        }
    }
}
