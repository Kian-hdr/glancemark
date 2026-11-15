import Foundation
import Markdown

struct ReadingBlockGroup {
    enum Content {
        case disclosure(SafeHTML.Disclosure)
        case container(SafeHTML.Container)
        case markdownContainer(SafeHTML.MarkdownContainer)
        case node(any Markup)
    }

    let content: Content
    let range: Range<Int>?

    static func previews(_ groups: [Self], in active: Range<Int>, snapshot: MarkdownSnapshot) -> [Self] {
        guard !active.isEmpty else { return [] }
        return groups.filter { group in
            guard let range = group.range, active.lowerBound <= range.lowerBound,
                  range.upperBound <= active.upperBound else { return false }
            switch group.content {
            case .disclosure, .container, .markdownContainer:
                return true
            case let .node(node):
                if node is Markdown.Table { return true }
                if let code = node as? CodeBlock {
                    return ["mermaid", "math", "geojson", "topojson", "stl"].contains(code.language?.lowercased() ?? "")
                }
                if let raw = snapshot.source(of: node) {
                    if let paragraph = node as? Paragraph {
                        if paragraph.childCount == 1, let link = paragraph.child(at: 0) as? Markdown.Link,
                           let address = link.destination, GitHubVideo.attachment(address) != nil { return true }
                        return GitHubMath.display(raw) != nil || GitHubMath.inline(raw) != nil
                            || GitHubVideo.attachment(raw.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
                            || GitHubVideo.fromHTML(raw) != nil || SafeHTML.image(raw) != nil
                            || containsImage(node)
                    }
                    if node is HTMLBlock {
                        return SafeHTML.image(raw) != nil || SafeHTML.headingImage(raw) != nil || GitHubVideo.fromHTML(raw) != nil
                    }
                }
                return false
            }
        }
    }

    private static func containsImage(_ node: any Markup) -> Bool {
        node is Markdown.Image || node.children.contains(where: containsImage)
    }

    static func collect(_ nodes: [any Markup], in snapshot: MarkdownSnapshot) -> [Self] {
        var groups: [Self] = []
        var index = 0
        while index < nodes.count {
            let content: Content
            let consumed: Int
            if let disclosure = SafeHTML.disclosure(at: index, in: nodes, snapshot: snapshot) {
                content = .disclosure(disclosure)
                consumed = disclosure.consumed
            } else if let container = SafeHTML.container(at: index, in: nodes, snapshot: snapshot) {
                content = .container(container)
                consumed = container.consumed
            } else if let container = SafeHTML.markdownContainer(at: index, in: nodes, snapshot: snapshot) {
                content = .markdownContainer(container)
                consumed = container.consumed
            } else if nodes[index] is HTMLBlock, let raw = snapshot.source(of: nodes[index]),
                      SafeHTML.image(raw) == nil, SafeHTML.textBlock(raw) == nil, SafeHTML.headingImage(raw) == nil,
                      let items = SafeHTML.paragraphFragment(raw) {
                content = .container(SafeHTML.Container(items: items, consumed: 1))
                consumed = 1
            } else {
                content = .node(nodes[index])
                consumed = 1
            }
            let last = index + consumed - 1
            let range: Range<Int>?
            if let first = snapshot.byteRange(of: nodes[index]), let end = snapshot.byteRange(of: nodes[last]),
               first.lowerBound <= end.upperBound {
                range = first.lowerBound..<end.upperBound
            } else {
                range = nil
            }
            groups.append(Self(content: content, range: range))
            index += consumed
        }
        return groups
    }
}
