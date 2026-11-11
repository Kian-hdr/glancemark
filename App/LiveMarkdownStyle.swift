import AppKit
import GlancemarkCore
import Markdown

/// A read-only projection of the Markdown source into TextKit attributes.
struct LiveMarkdownStyle {
    static let hiddenMarker = NSAttributedString.Key("GlancemarkHiddenMarkdownMarker")
    private static let checkboxPattern = try! NSRegularExpression(pattern: #"^(?:[-+*]|\d{1,9}[.)])[ \t]+(\[[ xX]\])"#)

    private struct Style {
        var size: CGFloat = 15
        var traits: NSFontTraitMask = []
        var code = false
        var strike = false
        var tint: NSColor = .textColor
        var quoteDepth = 0
    }

    private let source: String
    private let snapshot: MarkdownSnapshot
    private let offsets: [Int]

    init(_ source: String) {
        self.source = source
        snapshot = MarkdownSource(text: source).parse()
        var offsets = Array(repeating: -1, count: source.utf8.count + 1)
        var utf8 = 0, utf16 = 0
        for scalar in source.unicodeScalars {
            offsets[utf8] = utf16
            utf8 += scalar.utf8.count
            utf16 += scalar.utf16.count
        }
        offsets[utf8] = utf16
        self.offsets = offsets
    }

    func apply(to storage: NSTextStorage) -> [NSRange] {
        var checkboxes: [NSRange] = []
        for node in snapshot.document.children {
            apply(node, to: storage, inherited: Style(), checkboxes: &checkboxes)
        }
        return checkboxes
    }

    private func apply(_ node: any Markup, to storage: NSTextStorage,
                       inherited: Style, checkboxes: inout [NSRange]) {
        var style = inherited
        switch node {
        case let heading as Heading:
            style.size = max(16, 32 - CGFloat(heading.level - 1) * 3)
            style.traits.insert(.boldFontMask)
        case is Strong: style.traits.insert(.boldFontMask)
        case is Emphasis: style.traits.insert(.italicFontMask)
        case is Strikethrough: style.strike = true
        case is Markdown.Link, is Markdown.Image: style.tint = .linkColor
        case is InlineCode, is CodeBlock:
            style.code = true
            style.size = 13
        case is BlockQuote:
            style.quoteDepth += 1
            style.tint = .secondaryLabelColor
        default: break
        }

        if let range = range(for: node), range.length > 0, NSMaxRange(range) <= storage.length {
            if node is Heading || node is Strong || node is Emphasis || node is Strikethrough
                || node is Markdown.Link || node is Markdown.Image || node is InlineCode || node is CodeBlock || node is BlockQuote {
                let base = style.code
                    ? NSFont.monospacedSystemFont(ofSize: style.size, weight: .regular)
                    : NSFont.systemFont(ofSize: style.size)
                let font = NSFontManager.shared.convert(base, toHaveTrait: style.traits)
                storage.addAttributes([.font: font, .foregroundColor: style.tint], range: range)
                if style.strike {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
                if style.code {
                    storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.10), range: range)
                }
                if node is BlockQuote {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.firstLineHeadIndent = CGFloat(style.quoteDepth * 10)
                    paragraph.headIndent = paragraph.firstLineHeadIndent
                    storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
                }
            }
            if node is Heading {
                let text = (source as NSString).substring(with: range)
                mark(#"^#{1,6}(?:[ \t]+|$)"#, in: text, at: range.location, storage: storage, hidden: true)
                mark(#"[ \t]+#+[ \t]*$"#, in: text, at: range.location, storage: storage, hidden: true)
                mark(#"(?:\r\n|\n|\r)[ \t]*(?:=+|-+)[ \t]*$"#, in: text, at: range.location,
                     storage: storage, hidden: false)
            }
            if let item = node as? ListItem, item.checkbox != nil {
                let text = (source as NSString).substring(with: range)
                let localRange = NSRange(location: 0, length: (text as NSString).length)
                if let match = Self.checkboxPattern.firstMatch(in: text, range: localRange) {
                    let local = match.range(at: 1)
                    let box = NSRange(location: range.location + local.location, length: local.length)
                    checkboxes.append(box)
                    storage.addAttributes([.foregroundColor: NSColor.controlAccentColor,
                                           .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)], range: box)
                }
            }
        }

        for child in node.children {
            apply(child, to: storage, inherited: style, checkboxes: &checkboxes)
        }
    }

    private func range(for node: any Markup) -> NSRange? {
        guard let bytes = snapshot.byteRange(of: node), bytes.lowerBound >= 0,
              bytes.upperBound < offsets.count else { return nil }
        let start = offsets[bytes.lowerBound]
        let end = offsets[bytes.upperBound]
        guard start >= 0, end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func mark(_ pattern: String, in text: String, at offset: Int,
                      storage: NSTextStorage, hidden: Bool) {
        guard let match = text.range(of: pattern, options: .regularExpression) else { return }
        let local = NSRange(match, in: text)
        let range = NSRange(location: offset + local.location, length: local.length)
        if hidden {
            storage.addAttribute(Self.hiddenMarker, value: true, range: range)
        } else {
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        }
    }
}
