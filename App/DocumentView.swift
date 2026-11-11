import AppKit
import GlancemarkCore
import SwiftUI

struct DocumentView: View {
    @ObservedObject var content: DocumentContent
    var undo: UndoManager?
    var reload: () -> Void
    var saveCopy: () -> Void
    var edit: (String) -> Void

    @StateObject private var formatting = EditorFormatting()
    @State private var showSource = false
    @State private var activeBlock: InlineDocumentBlock?
    @State private var showOutline = false

    private var activeRange: Range<Int>? { activeBlock?.range }
    @State private var activeEditorID = UUID()
    @State private var activeUndo = UndoManager()
    @State private var items: [DocumentNavigatorItem] = []
    @State private var openBreadcrumb: URL?
    @State private var preparingFinderImages = false
    @State private var finderImageResult: String?
    @State private var showFinderImageResult = false

    var body: some View {
        VStack(spacing: 0) {
            pathBar
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
            HStack(spacing: 0) {
                if content.showNavigator {
                    DocumentFileNavigator(items: items, selected: content.fileURL) { open($0, fragment: nil) }
                    Divider()
                }
                VStack(spacing: 0) {
                    if !showSource { formattingBar }
                    documentSurface
                }
            }
        }
        .task(id: content.showNavigator ? navigationRoot : nil) {
            guard content.showNavigator, let root = navigationRoot else { items = []; return }
            let result = await Task.detached(priority: .utility) { DocumentNavigatorItem.load(root) }.value
            if !Task.isCancelled { items = result }
        }
        .onChange(of: content.fragment) { _, _ in
            showSource = false
            activeBlock = nil
        }
        .onExitCommand { activeBlock = nil }
        .alert("Finder Images", isPresented: $showFinderImageResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(finderImageResult ?? "")
        }
    }

    private var pathBar: some View {
        let path = breadcrumbs
        return HStack(spacing: 10) {
            Button { content.showNavigator.toggle() } label: {
                Image(systemName: "sidebar.left")
            }
            .help(content.showNavigator ? "Hide file navigator" : "Show file navigator")
            .accessibilityLabel(content.showNavigator ? "Hide file navigator" : "Show file navigator")

            ForEach(path, id: \.self) { crumb in
                if crumb != path.first {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                breadcrumb(crumb, isFile: crumb == content.fileURL?.standardizedFileURL)
            }
            if content.fileURL == nil {
                Label("Untitled", systemImage: "doc.text").lineLimit(1)
            }
            Menu {
                Button("Choose Folder…", action: chooseFolder)
                if content.navigatorRoot != nil || content.breadcrumbRoot != nil {
                    Button("Use Document Folder") {
                        content.navigatorRoot = nil
                        content.breadcrumbRoot = nil
                    }
                }
                Divider()
                Toggle("Show Outline", isOn: $showOutline)
                Button("Prepare Images for Finder", action: prepareFinderImages)
                    .disabled(resolver == nil || preparingFinderImages)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Document and folder options")
            .accessibilityLabel("Document and folder options")

            Spacer()
            Toggle(isOn: $showSource) {
                Label("Source", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .toggleStyle(.button)
            .help("Show or hide Markdown source")
            .onChange(of: showSource) { _, _ in activeBlock = nil }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func breadcrumb(_ url: URL, isFile: Bool) -> some View {
        let folder = isFile ? url.deletingLastPathComponent() : url
        let isPresented = Binding(
            get: { openBreadcrumb == url },
            set: { if !$0 && openBreadcrumb == url { openBreadcrumb = nil } }
        )
        return Button { openBreadcrumb = url } label: {
            Label(url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent,
                  systemImage: isFile ? "doc.text" : "folder")
                .lineLimit(1)
                .truncationMode(.middle)
                .fontWeight(isFile ? .medium : .regular)
        }
        .help("Browse \(folder.path)")
        .popover(isPresented: isPresented, arrowEdge: .bottom) {
            DocumentPathBrowser(root: breadcrumbs.first ?? folder, folder: folder, selected: content.fileURL) { destination in
                openBreadcrumb = nil
                if destination.standardizedFileURL != content.fileURL?.standardizedFileURL {
                    open(destination, fragment: nil, breadcrumbRoot: breadcrumbs.first ?? folder)
                }
            }
        }
    }

    private var formattingBar: some View {
        HStack(spacing: 10) {
            Spacer()
            Menu("Style") {
                Button("Paragraph") { formatting.perform(.paragraph) }
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") { formatting.perform(.heading(level)) }
                }
            }.menuStyle(.borderlessButton)
            HStack(spacing: 11) {
                formatButton("Bold", symbol: "bold", command: .bold)
                formatButton("Italic", symbol: "italic", command: .italic)
                formatButton("Strikethrough", symbol: "strikethrough", command: .strikethrough)
            }
            Divider().frame(height: 14)
            formatButton("Link", symbol: "link", command: .link)
            Menu {
                Button("Bulleted List") { formatting.perform(.bulletList) }
                Button("Numbered List") { formatting.perform(.numberedList) }
                Button("Task List") { formatting.perform(.taskList) }
            } label: {
                Image(systemName: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .help("List")
            .accessibilityLabel("List")
        }
        .buttonStyle(.borderless)
        .disabled(activeRange == nil)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityLabel("Formatting")
    }

    private func formatButton(_ label: String, symbol: String, command: EditorFormatting.Command) -> some View {
        Button { formatting.perform(command) } label: { Image(systemName: symbol) }
            .help(label)
            .accessibilityLabel(label)
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
                               repositoryRoot: root)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = navigationRoot
        if panel.runModal() == .OK, let url = panel.url {
            content.navigatorRoot = url
            content.breadcrumbRoot = nil
            content.showNavigator = true
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
        let navigator = content.showNavigator
        NSDocumentController.shared.openDocument(withContentsOf: destination, display: true) { doc, _, error in
            if let error { NSApp.presentError(error); return }
            guard let doc = doc as? MarkdownDocument else { return }
            if let root { doc.content.navigatorRoot = root }
            if let breadcrumbRoot { doc.content.breadcrumbRoot = breadcrumbRoot }
            if navigator { doc.content.showNavigator = true }
            doc.content.fragment = fragment
        }
    }
}
