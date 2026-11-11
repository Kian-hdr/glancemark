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
    let offersPreviewHandoff: Bool

    public init(document: URL, allowedFolder: URL, repositoryRoot: URL? = nil, offersPreviewHandoff: Bool = false) {
        self.document = document.resolvingSymlinksInPath().standardizedFileURL
        self.allowedFolder = allowedFolder.resolvingSymlinksInPath().standardizedFileURL
        self.offersPreviewHandoff = offersPreviewHandoff
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

    func unavailableLocalLink(_ reference: String) -> URL? {
        guard offersPreviewHandoff, !reference.hasPrefix("//"), !reference.contains("\\"),
              let parts = URLComponents(string: reference), parts.scheme == nil, parts.host == nil,
              parts.user == nil, parts.password == nil,
              !parts.path.isEmpty, !parts.path.contains("\0"), !parts.path.contains("\\"),
              resolve(reference) == nil else { return nil }
        return URL(string: "glancemark-unavailable-local:")
    }

    public func resolve(_ reference: String) -> Destination? {
        guard !reference.hasPrefix("//"), !reference.contains("\\"),
              let parts = URLComponents(string: reference), parts.user == nil, parts.password == nil else {
            return nil
        }
        if let scheme = parts.scheme?.lowercased() {
            guard ["https", "http", "mailto"].contains(scheme), let url = parts.url,
                  scheme == "mailto" || parts.host?.isEmpty == false else { return nil }
            return .web(url)
        }
        guard parts.host == nil else { return nil }
        if parts.path.isEmpty {
            return parts.fragment.map(Destination.fragment)
        }

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
            guard Self.contains(candidate, in: allowedFolder) else { return nil }
        }
        return .local(candidate, fragment: parts.fragment)
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
