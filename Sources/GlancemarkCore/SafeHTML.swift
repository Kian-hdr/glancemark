import Foundation
import Markdown

/// Only translates recognized markup into native reading elements.
enum SafeHTML {
    enum InlineStyle: String {
        case underline = "ins", u, superscript = "sup", subscriptText = "sub"
        case strong, b, emphasis = "em", i, strike = "s", deletion = "del"

        static func tag(_ source: String) -> (style: Self, closes: Bool)? {
            guard let token = source.wholeMatch(of: #/(?i)<(/?)(ins|u|sup|sub|strong|b|em|i|s|del)\s*>/#),
                  let style = Self(rawValue: token.2.lowercased()) else { return nil }
            return (style, token.1 == "/")
        }
    }

    struct Disclosure {
        let summary: String
        let body: String
        let isOpen: Bool
        let consumed: Int
    }

    static func anchor(_ source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = trimmed.wholeMatch(of: #/(?i)<a\s+(?:name|id)\s*=\s*(?:"([^"<>\s]+)"|'([^'<>\s]+)'|([A-Za-z0-9_.:-]+))\s*>\s*</a\s*>/#)
        else { return nil }
        return String(token.1 ?? token.2 ?? token.3 ?? "")
    }

    static func disclosure(at index: Int, in nodes: [any Markup], snapshot: MarkdownSnapshot) -> Disclosure? {
        guard nodes[index] is HTMLBlock,
              let first = snapshot.source(of: nodes[index]),
              let opening = first.prefixMatch(of: #/(?i)\s*<details(\s+open(?:\s*=\s*(?:"open"|'open'|open|""))?)?\s*>/#),
              let firstRange = snapshot.byteRange(of: nodes[index])
        else { return nil }

        var depth = 0
        for i in index..<nodes.count {
            guard nodes[i] is HTMLBlock, let html = snapshot.source(of: nodes[i]),
                  let span = snapshot.byteRange(of: nodes[i]) else { continue }
            for tag in html.matches(of: #/(?i)<(/?)details(?:\s[^<>]*)?>/#) {
                if tag.1 == "/" {
                    depth -= 1
                    if depth == 0 {
                        guard html[tag.range.upperBound...].allSatisfy(\.isWhitespace) else { return nil }
                        let end = span.lowerBound + html[..<tag.range.lowerBound].utf8.count
                        let start = firstRange.lowerBound + first[..<opening.range.upperBound].utf8.count
                        guard end >= start, let inner = snapshot.source(in: start..<end) else { return nil }
                        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let summary = trimmed.prefixMatch(of: #/(?is)<summary\s*>(.*?)</summary\s*>/#) {
                            return Disclosure(summary: String(summary.1), body: String(trimmed[summary.range.upperBound...])
                                .trimmingCharacters(in: .whitespacesAndNewlines), isOpen: opening.1 != nil, consumed: i - index + 1)
                        }
                        return Disclosure(summary: "Details", body: trimmed, isOpen: opening.1 != nil, consumed: i - index + 1)
                    }
                } else {
                    depth += 1
                }
            }
        }
        return nil
    }
}
