import SwiftUI

struct DocumentToolbar: View {
    let path: [URL]
    let file: URL?
    let hasCustomFolder: Bool
    let canPrepareFinderImages: Bool
    let canFormat: Bool

    @Binding var showSource: Bool
    @Binding var showOutline: Bool

    let openDocument: (URL, URL) -> Void
    let revealInFinder: () -> Void
    let chooseFolder: () -> Void
    let useDocumentFolder: () -> Void
    let prepareFinderImages: () -> Void
    let format: (EditorFormatting.Command) -> Void

    @State private var openBreadcrumb: URL?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            toolbarRow(path, compact: false)
            toolbarRow(Array(path.suffix(2)), compact: false)
            toolbarRow(Array(path.suffix(1)), compact: true)
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func toolbarRow(_ visiblePath: [URL], compact: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(visiblePath, id: \.self) { crumb in
                    if crumb != visiblePath.first {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    breadcrumb(crumb, isFile: crumb == file?.standardizedFileURL)
                }
                if visiblePath.isEmpty { Label("Untitled", systemImage: "doc.text").lineLimit(1) }
            }
            .fixedSize(horizontal: !compact, vertical: false)
            documentOptions
            Spacer(minLength: 4)
            if !showSource {
                if compact { formattingMenu }
                else { formattingBar }
                Divider().frame(height: 14)
            }
            Toggle(isOn: $showSource) {
                Label("Source", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .toggleStyle(.button)
            .fixedSize()
            .help("Show or hide Markdown source")
        }
    }

    private var documentOptions: some View {
        Menu {
            if file != nil {
                Button("Show in Finder", action: revealInFinder)
            }
            Button("Choose Folder…", action: chooseFolder)
            if hasCustomFolder {
                Button("Use Document Folder", action: useDocumentFolder)
            }
            Divider()
            Toggle("Show Outline", isOn: $showOutline)
            Button("Prepare Images for Finder", action: prepareFinderImages)
                .disabled(!canPrepareFinderImages)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Document and folder options")
        .accessibilityLabel("Document and folder options")
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
            DocumentPathBrowser(root: path.first ?? folder, folder: folder, selected: file) { destination in
                openBreadcrumb = nil
                if destination.standardizedFileURL != file?.standardizedFileURL {
                    openDocument(destination, path.first ?? folder)
                }
            }
        }
    }

    private var formattingBar: some View {
        HStack(spacing: 10) {
            Menu("Style") { styleActions }.menuStyle(.borderlessButton)
            HStack(spacing: 11) {
                formatButton("Bold", symbol: "bold", command: .bold)
                formatButton("Italic", symbol: "italic", command: .italic)
                formatButton("Strikethrough", symbol: "strikethrough", command: .strikethrough)
            }
            Divider().frame(height: 14)
            formatButton("Link", symbol: "link", command: .link)
            Menu { listActions } label: {
                Image(systemName: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .help("List")
            .accessibilityLabel("List")
        }
        .buttonStyle(.borderless)
        .disabled(!canFormat)
        .fixedSize()
        .accessibilityLabel("Formatting")
    }

    private var formattingMenu: some View {
        Menu {
            Menu("Style") { styleActions }
            Button("Bold") { format(.bold) }
            Button("Italic") { format(.italic) }
            Button("Strikethrough") { format(.strikethrough) }
            Button("Link") { format(.link) }
            Menu("List") { listActions }
        } label: {
            Label("Formatting", systemImage: "textformat")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .help("Formatting")
        .disabled(!canFormat)
        .fixedSize()
    }

    @ViewBuilder private var styleActions: some View {
        Button("Paragraph") { format(.paragraph) }
        ForEach(1...6, id: \.self) { level in
            Button("Heading \(level)") { format(.heading(level)) }
        }
    }

    @ViewBuilder private var listActions: some View {
        Button("Bulleted List") { format(.bulletList) }
        Button("Numbered List") { format(.numberedList) }
        Button("Task List") { format(.taskList) }
    }

    private func formatButton(_ label: String, symbol: String, command: EditorFormatting.Command) -> some View {
        Button { format(command) } label: { Image(systemName: symbol) }
            .help(label)
            .accessibilityLabel(label)
    }
}
