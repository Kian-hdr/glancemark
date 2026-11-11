import CryptoKit
import Foundation
import Markdown

/// Copies only the document's recognized image references into the signed app group.
/// Finder does not gain access to the containing folder or to any original file.
public enum FinderImageCache {
    public struct Unavailable: Error {}
    private static let lock = NSLock()
    private static let fileLimit = 4 * 1024 * 1024
    private static let totalLimit = 32 * 1024 * 1024

    static func container() -> URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "GlancemarkAppearanceGroup") as? String,
              !group.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Finder_Images", isDirectory: true)
    }

    /// Call only in response to the user's explicit menu action in the document app.
    public static func prepare(snapshot: MarkdownSnapshot, links: RepositoryLinks) throws -> Int {
        guard let directory = container() else { throw Unavailable() }
        return try prepare(snapshot: snapshot, links: links, directory: directory, includeRemote: true)
    }

    static func prepare(snapshot: MarkdownSnapshot, links: RepositoryLinks, directory: URL,
                        includeRemote: Bool = false) throws -> Int {
        guard snapshot.byteCount <= 2 * 1024 * 1024 else { throw Unavailable() }
        var local: [(String, URL)] = []
        var remote: [(String, URL)] = []
        for reference in snapshot.imageReferences() {
            switch links.resolve(reference) {
            case let .local(url, _): local.append((reference, url))
            case let .web(url) where includeRemote && ReaderHTTPS.host(of: url) != nil: remote.append((reference, url))
            default: break
            }
        }
        let targets = Array(local.prefix(32)) + Array(remote.prefix(8))
        if targets.isEmpty { return 0 }

        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        var usage = files.reduce(0) { total, file in
            guard file.pathExtension == "asset",
                  let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  info.isRegularFile == true else { return total }
            return total + (info.fileSize ?? 0)
        }
        var count = 0
        for (reference, url) in targets {
            let data: Data?
            if url.isFileURL {
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= fileLimit {
                    data = try? ReaderRaster.loadBytes(url)
                } else {
                    data = nil
                }
            } else {
                data = try? ReaderHTTPS.fetch(url, limit: fileLimit, timeout: 4_000)
            }
            guard let bytes = data, bytes.count <= fileLimit,
                  (try? ReaderImagePayload.decode(bytes)) != nil else { continue }
            let target = cacheFile(document: links.document, identity: "reference:" + reference, directory: directory)
            let existing = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard usage - existing + bytes.count <= totalLimit else { continue }
            try bytes.write(to: target, options: .atomic)
            usage += bytes.count - existing
            count += 1
        }
        return count
    }

    static func load(document: URL, reference: String, legacyAsset: URL? = nil,
                     directory: URL? = container()) -> ReaderImagePayload? {
        guard let directory else { return nil }
        func read(_ identity: String) -> ReaderImagePayload? {
            let file = cacheFile(document: document, identity: identity, directory: directory)
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= fileLimit else { return nil }
            return try? ReaderImagePayload.load(file)
        }
        return read("reference:" + reference) ?? legacyAsset.flatMap { asset in
            read(asset.isFileURL ? asset.standardizedFileURL.path : asset.absoluteString)
        }
    }

    private static func cacheFile(document: URL, identity: String, directory: URL) -> URL {
        let key = document.standardizedFileURL.path + "\u{0}" + identity
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("asset")
    }
}

extension MarkdownSnapshot {
    fileprivate func imageReferences() -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        func insert(_ reference: String) {
            if result.count < 128 && seen.insert(reference).inserted { result.append(reference) }
        }
        func collect(_ image: ReaderImage) {
            insert(image.source)
            for variant in image.variants.values.sorted() { insert(variant) }
        }
        func walk(_ node: any Markup, depth: Int) {
            guard depth < 32, result.count < 128 else { return }
            if let image = node as? Markdown.Image, let source = image.source {
                insert(source)
            } else if node is HTMLBlock || node is Paragraph, let raw = source(of: node) {
                if let heading = SafeHTML.headingImage(raw) {
                    collect(heading.image)
                } else if let image = SafeHTML.image(raw) {
                    collect(image)
                } else if let group = SafeHTML.containerItems(raw) {
                    for item in group {
                        if case let .image(image) = item { collect(image) }
                    }
                }
            }
            for child in node.children { walk(child, depth: depth + 1) }
        }
        for group in ReadingBlockGroup.collect(Array(document.children), in: self) {
            switch group.content {
            case let .container(container):
                for item in container.items {
                    if case let .image(image) = item { collect(image) }
                }
            case let .markdownContainer(container):
                for node in container.content { walk(node, depth: 0) }
            case let .node(node):
                walk(node, depth: 0)
            case .disclosure:
                break
            }
        }
        return result
    }
}
