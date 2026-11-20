import AppKit
import GlancemarkCore
import SwiftUI

enum DocumentMode {
    case edit, preview, source
}

struct DocumentView: View {
    @ObservedObject var content: DocumentContent
    var undo: UndoManager?
    var reload: () -> Void
    var saveCopy: () -> Void
    var documentWindow: () -> NSWindow?
    var edit: (String) -> Void

    @StateObject private var formatting = EditorFormatting()
    @State private var mode: DocumentMode = .edit
    @State private var showOutline = false
    @State private var preparingFinderImages = false
    @State private var finderImageResult: String?
    @State private var showFinderImageResult = false

    var body: some View {
        VStack(spacing: 0) {
            DocumentToolbar(path: breadcrumbs, file: content.fileURL,
                            hasCustomFolder: content.navigatorRoot != nil || content.breadcrumbRoot != nil,
                            canPrepareFinderImages: content.fileURL != nil && !preparingFinderImages,
                            mode: $mode, showOutline: $showOutline,
                            openDocument: { url, root in open(url, fragment: nil, breadcrumbRoot: root) },
                            revealInFinder: revealInFinder, chooseFolder: chooseFolder,
                            useDocumentFolder: useDocumentFolder, prepareFinderImages: prepareFinderImages,
                            format: formatting.perform)
            Divider()
            if content.hasExternalConflict {
                HStack(spacing: 10) {
                    Label("The file on disk changed.", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Reload…", action: reload)
                    Button("Save Copy…", action: saveCopy)
                }
                .padding(10)
                Divider()
            }
            documentSurface
        }
        .onChange(of: content.fragment, initial: true) { _, fragment in
            if fragment != nil { mode = .preview }
        }
        .alert("Finder Images", isPresented: $showFinderImageResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(finderImageResult ?? "")
        }
    }

    private var documentSurface: some View {
        ZStack {
            SourceEditor(text: content.source.text, formatted: mode != .source, active: mode != .preview,
                         undo: undo, formatting: formatting, focusOnCreation: content.fragment == nil,
                         openLink: followEditorLink, edit: edit)
                .opacity(mode == .preview ? 0 : 1)
                .allowsHitTesting(mode != .preview)
                .accessibilityHidden(mode == .preview)
            if mode == .preview {
                ReadingView(snapshot: content.source.parse(), links: resolver, showOutline: showOutline,
                            initialFragment: content.fragment, openLocal: open)
            }
        }
    }

    private var navigationRoot: URL? {
        content.navigatorRoot ?? content.breadcrumbRoot ?? content.fileURL?.deletingLastPathComponent()
    }

    private var breadcrumbs: [URL] {
        DocumentPathBrowser.breadcrumbs(file: content.fileURL, root: content.navigatorRoot ?? content.breadcrumbRoot)
    }

    private var resolver: RepositoryLinks? {
        guard let url = content.fileURL else { return nil }
        let root = content.navigatorRoot ?? content.repositoryRoot
        return RepositoryLinks(document: url, allowedFolder: root ?? navigationRoot ?? url.deletingLastPathComponent(),
                               repositoryRoot: root,
                               wikiRoot: content.navigatorRoot ?? content.wikiRoot)
    }

    private func revealInFinder() {
        guard let file = content.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    private func useDocumentFolder() {
        content.navigatorRoot = nil
        content.breadcrumbRoot = nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = navigationRoot
        if panel.runModal() == .OK, let url = panel.url {
            content.navigatorRoot = url
            content.breadcrumbRoot = nil
        }
    }

    private func prepareFinderImages() {
        guard let links = resolver, !preparingFinderImages else { return }
        let source = content.source
        preparingFinderImages = true
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                Result { try FinderImageCache.prepare(snapshot: source.parse(), links: links) }
            }.value
            switch result {
            case let .success(count) where count > 0:
                finderImageResult = "Prepared \(count) image\(count == 1 ? "" : "s"). Close and reopen Finder Quick Look to see them."
            case .success:
                finderImageResult = "No supported images referenced by this document were available."
            case .failure:
                finderImageResult = "Glancemark couldn’t open its signed Finder image cache."
            }
            preparingFinderImages = false
            showFinderImageResult = true
        }
    }

    private func followEditorLink(_ reference: String, editor: MarkdownTextView) -> Bool {
        let destination = resolver.map { $0.resolve(reference) } ?? RepositoryLinks.resolveNonFile(reference)
        switch destination {
        case let .web(url):
            return NSWorkspace.shared.open(url)
        case let .local(url, fragment):
            open(url, fragment: fragment)
            return true
        case let .fragment(fragment):
            guard let range = LiveMarkdownStyle(editor.string).headingRange(for: fragment) else { return false }
            editor.scrollRangeToVisible(range)
            return true
        case nil:
            return false
        }
    }

    private func open(_ url: URL, fragment: String?) {
        open(url, fragment: fragment, breadcrumbRoot: content.breadcrumbRoot)
    }

    private func open(_ url: URL, fragment: String?, breadcrumbRoot: URL?) {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        guard let destination = parts?.url else { return }
        guard DocumentNavigatorItem.isMarkdown(destination) else {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            return
        }
        let root = content.navigatorRoot
        let wikiRoot = resolver?.wikiRoot
        let sourceWindow = documentWindow()
        NSDocumentController.shared.openDocument(withContentsOf: destination, display: false) { doc, alreadyOpen, error in
            if let error { NSApp.presentError(error); return }
            guard let doc = doc as? MarkdownDocument else { return }
            if let root { doc.content.navigatorRoot = root }
            if let breadcrumbRoot { doc.content.breadcrumbRoot = breadcrumbRoot }
            if let wikiRoot, doc.content.wikiRoot == nil { doc.content.wikiRoot = wikiRoot }
            doc.content.fragment = fragment
            doc.showAsTab(beside: alreadyOpen ? nil : sourceWindow)
        }
    }
}
