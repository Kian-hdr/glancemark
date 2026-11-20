import Foundation

public struct RepositoryLinks {
    public enum Destination: Equatable {
        case fragment(String)
        case local(URL, fragment: String?)
        case web(URL)
    }

    let document: URL
    private let allowedFolder: URL
    public let repositoryRoot: URL?
    public let wikiRoot: URL?
    let offersPreviewHandoff: Bool

    public init(document: URL, allowedFolder: URL, repositoryRoot: URL? = nil, wikiRoot: URL? = nil,
                offersPreviewHandoff: Bool = false) {
        let document = document.resolvingSymlinksInPath().standardizedFileURL
        self.document = document
        self.allowedFolder = allowedFolder.resolvingSymlinksInPath().standardizedFileURL
        self.offersPreviewHandoff = offersPreviewHandoff
        let wikiRoot = wikiRoot?.resolvingSymlinksInPath().standardizedFileURL
        self.wikiRoot = wikiRoot.flatMap { Self.contains(document, in: $0) ? $0 : nil }
        let root = repositoryRoot?.resolvingSymlinksInPath().standardizedFileURL
        if let root, Self.contains(self.document, in: root), Self.contains(root, in: self.allowedFolder) {
            self.repositoryRoot = root
        } else if root == nil {
            self.repositoryRoot = Self.findRoot(above: self.document, within: self.allowedFolder)
        } else {
            self.repositoryRoot = nil
        }
    }

    public static func nearestRepositoryRoot(for document: URL) -> URL? {
        guard document.isFileURL else { return nil }
        return findRoot(above: document.resolvingSymlinksInPath().standardizedFileURL,
                        within: URL(fileURLWithPath: "/", isDirectory: true))
    }

    public static func nearestWikiRoot(for document: URL) -> URL? {
        guard document.isFileURL else { return nil }
        let document = document.resolvingSymlinksInPath().standardizedFileURL
        var folder = document.deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser
        while folder.path != "/", folder != home {
            if [".obsidian", "INDEX.md"].contains(where: {
                FileManager.default.isReadableFile(atPath: folder.appendingPathComponent($0).path)
            }) { return folder }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    func resolveWikiLink(_ link: WikiLink) -> Destination? {
        resolveWikiReference(wikiReference(link))
    }

    public func resolveWikiReference(_ reference: String) -> Destination? {
        guard let parts = URLComponents(string: reference), parts.scheme == nil, parts.host == nil,
              parts.user == nil, parts.password == nil, !reference.hasPrefix("//") else { return nil }
        let path = parts.path
        let relative = resolve(reference)
        if path.isEmpty || path.hasPrefix("./") || path.hasPrefix("../") { return relative }
        let root = wikiRoot ?? repositoryRoot
        let rooted = root.flatMap {
            resolvePath(path.hasPrefix("/") ? String(path.dropFirst()) : path,
                        relativeTo: $0, within: $0, fragment: parts.fragment)
        }
        let candidates = path.contains("/") ? [rooted, relative] : [relative, rooted]
        for destination in candidates {
            guard let destination else { continue }
            if case let .local(url, fragment) = destination {
                if url == document, let fragment { return .fragment(fragment) }
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
                   !directory.boolValue { return destination }
            } else {
                return destination
            }
        }
        // Quick Look may be unable to probe a sibling file until the user opens it.
        return candidates.compactMap { $0 }.first
    }

    func wikiReference(_ link: WikiLink) -> String {
        var parts = URLComponents()
        parts.path = wikiPath(link)
        parts.fragment = link.fragment
        return parts.string ?? ""
    }

    private func wikiPath(_ link: WikiLink) -> String {
        var path = link.path
        if !path.isEmpty, (path as NSString).pathExtension.isEmpty { path += ".md" }
        return path
    }

    func unavailableLocalLink(_ reference: String) -> URL? {
        guard offersPreviewHandoff, !reference.hasPrefix("//"), !reference.contains("\\"),
              let parts = URLComponents(string: reference), parts.scheme == nil, parts.host == nil,
              parts.user == nil, parts.password == nil,
              !parts.path.isEmpty, !parts.path.contains("\0"), !parts.path.contains("\\"),
              resolve(reference) == nil else { return nil }
        return URL(string: "glancemark-unavailable-local:")
    }

    public func resolve(_ reference: String) -> Destination? {
        guard let parts = Self.referenceComponents(reference) else { return nil }
        if parts.scheme != nil || parts.path.isEmpty { return Self.nonFileDestination(parts) }

        let base: URL
        let path: String
        if parts.path.hasPrefix("/") {
            guard let repositoryRoot else { return nil }
            base = repositoryRoot
            path = String(parts.path.dropFirst())
        } else {
            base = document.deletingLastPathComponent()
            path = parts.path
        }
        return resolvePath(path, relativeTo: base, within: allowedFolder, fragment: parts.fragment)
    }

    public static func resolveNonFile(_ reference: String) -> Destination? {
        referenceComponents(reference).flatMap(nonFileDestination)
    }

    private static func referenceComponents(_ reference: String) -> URLComponents? {
        guard !reference.hasPrefix("//"), !reference.contains("\\"),
              let parts = URLComponents(string: reference), parts.user == nil, parts.password == nil,
              parts.scheme != nil || parts.host == nil else { return nil }
        return parts
    }

    private static func nonFileDestination(_ parts: URLComponents) -> Destination? {
        if let scheme = parts.scheme?.lowercased() {
            guard ["https", "http", "mailto"].contains(scheme), let url = parts.url,
                  scheme == "mailto" || parts.host?.isEmpty == false else { return nil }
            return .web(url)
        }
        guard parts.path.isEmpty else { return nil }
        return parts.fragment.map(Destination.fragment)
    }

    private func resolvePath(_ path: String, relativeTo base: URL, within boundary: URL,
                             fragment: String?) -> Destination? {
        guard !path.contains("\0"), !path.contains("\\") else { return nil }
        var candidate = base
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": candidate.deleteLastPathComponent()
            default:
                candidate.appendPathComponent(String(component))
                // Resolve each ancestor even when the requested leaf does not exist.
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
                    let target = candidate.resolvingSymlinksInPath()
                    guard target.path != candidate.path else { return nil }
                    candidate = target
                }
            }
            guard Self.contains(candidate, in: boundary) else { return nil }
        }
        return .local(candidate, fragment: fragment)
    }

    private static func findRoot(above file: URL, within folder: URL) -> URL? {
        var ancestor = file.deletingLastPathComponent()
        while contains(ancestor, in: folder) {
            let marker = ancestor.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: marker.path) { return ancestor }
            guard ancestor.pathComponents.count > folder.pathComponents.count else { break }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.pathComponents.count < ancestor.pathComponents.count else { break }
            ancestor = parent
        }
        return nil
    }

    private static func contains(_ item: URL, in directory: URL) -> Bool {
        item.pathComponents.starts(with: directory.pathComponents)
    }
}
