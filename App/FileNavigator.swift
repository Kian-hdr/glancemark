import Foundation

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

    static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

}
