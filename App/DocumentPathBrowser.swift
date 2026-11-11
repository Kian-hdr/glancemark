import SwiftUI

struct DocumentPathBrowser: View {
    let root: URL
    let selected: URL?
    let open: (URL) -> Void

    @State private var folder: URL
    @State private var listing: Result<[DocumentNavigatorItem], Error>?

    init(root: URL, folder: URL, selected: URL?, open: @escaping (URL) -> Void) {
        self.root = root.standardizedFileURL
        self.selected = selected?.standardizedFileURL
        self.open = open
        _folder = State(initialValue: folder.standardizedFileURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let parent = Self.parentFolder(of: folder, within: root) {
                    Button { navigate(to: parent) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("Parent folder")
                    .accessibilityLabel("Parent folder")
                }
                Label(folder.lastPathComponent.isEmpty ? "/" : folder.lastPathComponent, systemImage: "folder")
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .padding(12)
            Divider()
            switch listing {
            case let .success(entries) where !entries.isEmpty:
                List(entries) { item in
                    let isCurrent = item.url.standardizedFileURL == selected
                    Button {
                        if item.isFolder { navigate(to: item.url) }
                        else { open(item.url) }
                    } label: {
                        HStack {
                            Label(item.name, systemImage: item.isFolder ? "folder" : "doc.text")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if item.isFolder || isCurrent {
                                Image(systemName: item.isFolder ? "chevron.right" : "checkmark")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
                    .accessibilityHint(item.isFolder ? "Browse folder" : "Open Markdown document")
                }
                .listStyle(.plain)
                .frame(height: min(CGFloat(entries.count) * 28 + 8, 300))
            case .success:
                Text("No folders or Markdown files").foregroundStyle(.secondary).padding(12)
            case .failure:
                Text("This folder couldn’t be opened.").foregroundStyle(.secondary).padding(12)
            case nil:
                ProgressView().controlSize(.small).padding(12)
            }
        }
        .frame(width: 290, alignment: .leading)
        .task(id: folder) {
            let directory = folder
            let result = await Task.detached(priority: .userInitiated) {
                Result { try DocumentNavigatorItem.contents(of: directory) }
            }.value
            if !Task.isCancelled { listing = result }
        }
    }

    private func navigate(to url: URL) {
        listing = nil
        folder = url.standardizedFileURL
    }

    static func parentFolder(of folder: URL, within root: URL) -> URL? {
        let directory = folder.standardizedFileURL
        let base = root.standardizedFileURL.pathComponents
        let current = directory.pathComponents
        guard current.count > base.count, current.starts(with: base) else { return nil }
        return directory.deletingLastPathComponent()
    }

    static func breadcrumbs(file: URL?, root: URL?) -> [URL] {
        guard let file = file?.standardizedFileURL else { return [] }
        let directory = file.deletingLastPathComponent()
        let requestedRoot = root?.standardizedFileURL
        let components = directory.pathComponents
        let base = requestedRoot.flatMap { components.starts(with: $0.pathComponents) ? $0 : nil } ?? directory
        return components.dropFirst(base.pathComponents.count).reduce(into: [base]) { path, component in
            if let parent = path.last {
                path.append(parent.appendingPathComponent(component, isDirectory: true))
            }
        } + [file]
    }
}
