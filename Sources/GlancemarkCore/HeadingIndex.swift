import Foundation
import Markdown

public struct HeadingIndex {
    public struct Entry: Equatable, Identifiable {
        public let id: String
        public let title: String
        public let level: Int
        public let sourceRange: Range<Int>
    }

    public let entries: [Entry]

    public init(snapshot: MarkdownSnapshot) {
        var slugger = GitHubHeadingSlugger()
        var result: [Entry] = []

        func visit(_ node: any Markup) {
            if let heading = node as? Heading, let range = snapshot.byteRange(of: heading) {
                let title = Self.headingText(heading)
                result.append(Entry(id: slugger.next(title), title: title, level: heading.level, sourceRange: range))
            } else if node is HTMLBlock, let range = snapshot.byteRange(of: node),
                      let raw = snapshot.source(of: node), let block = SafeHTML.textBlock(raw),
                      let level = block.headingLevel {
                let title = block.runs.map(\.text).joined()
                result.append(Entry(id: slugger.next(title), title: title, level: level, sourceRange: range))
            }
            for child in node.children { visit(child) }
        }
        visit(snapshot.document)
        entries = result
    }

    private static func headingText(_ node: any Markup) -> String {
        switch node {
        case let text as Markdown.Text: return text.string
        case let code as InlineCode: return code.code
        case is InlineHTML: return ""
        case is SoftBreak: return " "
        case is LineBreak: return "\n"
        default: return node.children.map(headingText).joined()
        }
    }
}

/// Heading IDs use the same byte identity as URL fragments. Swift String keys
/// compare canonically equivalent Unicode spellings, which would incorrectly
/// merge a decomposed heading with a separately encoded composed heading.
struct GitHubHeadingSlugger {
    private static let casing = Locale(identifier: "en_US_POSIX")
    private var occurrences: [Data: Int] = [:]

    mutating func next(_ text: String) -> String {
        let base = Self.base(text)
        let original = Data(base.utf8)
        var candidate = base
        var key = original
        while occurrences[key] != nil {
            occurrences[original, default: 0] += 1
            candidate = "\(base)-\(occurrences[original, default: 0])"
            key = Data(candidate.utf8)
        }
        occurrences[key] = 0
        return candidate
    }

    static func base(_ text: String) -> String {
        let lowercase = text.lowercased(with: casing)
        var result = String.UnicodeScalarView()
        for scalar in lowercase.unicodeScalars {
            if scalar == " " {
                result.append("-")
            } else if GitHubHeadingScalars.contains(scalar.value) {
                result.append(scalar)
            }
        }
        return String(result)
    }
}
