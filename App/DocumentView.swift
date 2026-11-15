import AppKit
import GlancemarkCore
import SwiftUI

struct DocumentView: View {
    @ObservedObject var content: DocumentContent
    var undo: UndoManager?
    var reload: () -> Void
    var saveCopy: () -> Void
    var documentWindow: () -> NSWindow?
    var edit: (String) -> Void

    @StateObject private var formatting = EditorFormatting()
    @State private var showSource = false
    @State private var activeBlock: InlineDocumentBlock?
    @State private var showOutline = false

    private var activeRange: Range<Int>? { activeBlock?.range }
    @State private var activeEditorID = UUID()
    @State private var activeUndo = UndoManager()
    @State private var preparingFinderImages = false
    @State private var finderImageResult: String?
    @State private var showFinderImageResult = false

    var body: some View {
        VStack(spacing: 0) {
            DocumentToolbar(path: breadcrumbs, file: content.fileURL,
                            hasCustomFolder: content.navigatorRoot != nil || content.breadcrumbRoot != nil,
                            canPrepareFinderImages: content.fileURL != nil && !preparingFinderImages,
                            canFormat: activeRange != nil, showSource: $showSource, showOutline: $showOutline,
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
        .onChange(of: content.fragment) { _, _ in
            showSource = false
            activeBlock = nil
        }
        .onChange(of: showSource) { _, _ in activeBlock = nil }
        .onExitCommand { activeBlock = nil }
        .alert("Finder Images", isPresented: $showFinderImageResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(finderImageResult ?? "")
        }
    }

    private var documentSurface: some View {
        ZStack {
            SourceEditor(text: content.source.text, formatted: false, active: showSource, undo: undo, edit: edit)
                .opacity(showSource ? 1 : 0)
                .allowsHitTesting(showSource)
                .accessibilityHidden(!showSource)
            if !showSource {
                ReadingView(snapshot: content.source.parse(), links: resolver, showOutline: showOutline,
                            initialFragment: content.fragment, activeEditRange: activeRange,
                            onEditBlock: beginEditing, activeEditor: { AnyView(inlineEditor) }, openLocal: open)
            }
        }
        .onAppear {
            if content.source.text.isEmpty { beginEditing(0..<0) }
        }
    }

    @ViewBuilder private var inlineEditor: some View {
        if let block = activeBlock, let text = block.text(in: content.source.text) {
            SourceEditor(text: text, formatted: true, active: true, undo: activeUndo,
                         formatting: formatting, focusOnCreation: true, inline: true, edit: replaceActiveBlock)
                .id(activeEditorID)
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

    private func beginEditing(_ range: Range<Int>) {
        let block = InlineDocumentBlock(range: range)
        guard activeRange != range, block.text(in: content.source.text) != nil else { return }
        activeUndo = UndoManager()
        activeEditorID = UUID()
        activeBlock = block
    }

    private func replaceActiveBlock(_ text: String) {
        guard var block = activeBlock, let result = block.replace(in: content.source.text, with: text) else { return }
        activeBlock = block
        edit(result)
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
