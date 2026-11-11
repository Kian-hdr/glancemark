import Foundation
import SwiftUI

struct DocumentNavigatorItem: Identifiable, Sendable {
    let url: URL
    let children: [Self]?

    var id: URL { url }
    var isFolder: Bool { children != nil }
    var name: String { url.lastPathComponent }

    static func contents(of directory: URL) throws -> [Self] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        return entries.compactMap { url in
            guard let info = try? url.resourceValues(forKeys: keys),
                  info.isSymbolicLink != true, info.isPackage != true else { return nil }
            if info.isDirectory == true { return Self(url: url, children: []) }
            if info.isRegularFile == true, isMarkdown(url) { return Self(url: url, children: nil) }
            return nil
        }.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func load(_ root: URL) -> [Self] {
        var remaining = 1_500
        func scan(_ directory: URL, depth: Int) -> [Self] {
            guard depth < 8, remaining > 0, let entries = try? contents(of: directory) else { return [] }
            var result: [Self] = []
            for entry in entries {
                guard remaining > 0 else { break }
                remaining -= 1
                let children = entry.isFolder ? scan(entry.url, depth: depth + 1) : nil
                result.append(Self(url: entry.url, children: children))
            }
            return result
        }
        return scan(root, depth: 0)
    }

    static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    func matching(_ filter: String) -> Self? {
        if name.localizedCaseInsensitiveContains(filter) { return self }
        guard let children else { return nil }
        let retained = children.compactMap { $0.matching(filter) }
        return retained.isEmpty ? nil : Self(url: url, children: retained)
    }

    var files: [Self] { children?.flatMap(\.files) ?? [self] }
}

struct DocumentFileNavigator: View {
    let items: [DocumentNavigatorItem]
    let selected: URL?
    let open: (URL) -> Void
    @State private var filter = ""

    private var filtered: [DocumentNavigatorItem] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? items : items.compactMap { $0.matching(query) }.flatMap(\.files)
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                OutlineGroup(filtered, children: \.children) { item in
                    if item.isFolder {
                        Label(item.name, systemImage: "folder")
                            .lineLimit(1)
                    } else {
                        Button { open(item.url) } label: {
                            Label(item.name, systemImage: "doc.text")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(item.url == selected ? Color.accentColor.opacity(0.16) : Color.clear)
                        .accessibilityAddTraits(item.url == selected ? [.isSelected] : [])
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            TextField("Filter files", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(8)
        }
        .accessibilityLabel("Files")
        .frame(width: 225)
        .background(.regularMaterial)
    }
}
