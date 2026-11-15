import Foundation
import SwiftUI

/// A local note reference kept relative until the Finder preview handles the click.
public struct PreviewMarkdownLink: Equatable {
    static let scheme = "glancemark-preview-note"
    public let reference: String
    public let isWiki: Bool

    init?(reference: String, isWiki: Bool) {
        guard let parts = URLComponents(string: reference), parts.scheme == nil, parts.host == nil,
              parts.user == nil, parts.password == nil, !reference.hasPrefix("//"),
              !parts.path.contains("\\"), !parts.path.contains("\0"),
              ["md", "markdown"].contains((parts.path as NSString).pathExtension.lowercased()) else { return nil }
        self.reference = reference
        self.isWiki = isWiki
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme, let path = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["wiki", "markdown"].contains(path.path),
              let reference = path.queryItems?.first(where: { $0.name == "ref" })?.value else { return nil }
        self.init(reference: reference, isWiki: path.path == "wiki")
    }

    var url: URL? {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.path = isWiki ? "wiki" : "markdown"
        parts.queryItems = [URLQueryItem(name: "ref", value: reference)]
        return parts.url
    }

    public func resolve(in links: RepositoryLinks) -> RepositoryLinks.Destination? {
        isWiki ? links.resolveWikiReference(reference) : links.resolve(reference)
    }
}

private struct PreviewMarkdownLinkAction: EnvironmentKey {
    static let defaultValue: ((PreviewMarkdownLink) -> Void)? = nil
}

public extension EnvironmentValues {
    var onPreviewMarkdownLink: ((PreviewMarkdownLink) -> Void)? {
        get { self[PreviewMarkdownLinkAction.self] }
        set { self[PreviewMarkdownLinkAction.self] = newValue }
    }
}
