import AppKit
import GlancemarkCore
import Markdown

/// A read-only projection of the Markdown source into TextKit attributes.
struct LiveMarkdownStyle {
    static let hiddenMarker = NSAttributedString.Key("GlancemarkHiddenMarkdownMarker")
    static let displayGlyph = NSAttributedString.Key("GlancemarkDisplayGlyph")
    static let bodyParagraph = NSAttributedString.Key("GlancemarkBodyParagraph")
    static let listMarker = NSAttributedString.Key("GlancemarkListMarker")
    static let linkDestination = NSAttributedString.Key("GlancemarkLinkDestination")
    private static let listPattern = try! NSRegularExpression(
        pattern: #"^([-+*]|\d{1,9}[.)])(?:[ \t]+(\[[ xX]\](?=[ \t]|$))?|$)"#
    )
    private static let checkboxFont = NSFont(name: "Apple Symbols", size: 16)

    static func paragraphStyle(quoteDepth: Int = 0) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.firstLineHeadIndent = CGFloat(quoteDepth * 12)
        paragraph.headIndent = paragraph.firstLineHeadIndent
        return paragraph
    }

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

    func headingRange(for fragment: String) -> NSRange? {
        HeadingIndex(snapshot: snapshot).entries
            .first(where: { $0.id.utf8.elementsEqual(fragment.utf8) })
            .flatMap { range(for: $0.sourceRange) }
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
        case is Markdown.Link: style.tint = .linkColor
        case is InlineCode, is CodeBlock:
            style.code = true
            style.size = 13
        case is BlockQuote:
            style.quoteDepth += 1
            style.tint = .secondaryLabelColor
        default: break
        }

        if let range = range(for: node), range.length > 0, NSMaxRange(range) <= storage.length {
            if node is Paragraph, node.parent is Document {
                storage.addAttribute(Self.bodyParagraph, value: true, range: range)
            }
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
                    storage.addAttribute(.paragraphStyle, value: Self.paragraphStyle(quoteDepth: style.quoteDepth),
                                         range: range)
                }
            }
            if node is Heading {
                let text = (source as NSString).substring(with: range)
                mark(#"^#{1,6}(?:[ \t]+|$)"#, in: text, at: range.location, storage: storage, hidden: true)
                mark(#"[ \t]+#+[ \t]*$"#, in: text, at: range.location, storage: storage, hidden: true)
                mark(#"(?:\r\n|\n|\r)[ \t]*(?:=+|-+)[ \t]*$"#, in: text, at: range.location,
                     storage: storage, hidden: false)
            }
            if node is Strong || node is Emphasis || node is Strikethrough || node is Markdown.Link {
                let children = node.children.compactMap { self.range(for: $0) }
                if let first = children.first, let last = children.last,
                   first.location >= range.location, NSMaxRange(last) <= NSMaxRange(range),
                   first.location < NSMaxRange(last) {
                    let label = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
                    hide(NSRange(location: range.location, length: label.location - range.location), in: storage)
                    hide(NSRange(location: NSMaxRange(label), length: NSMaxRange(range) - NSMaxRange(label)), in: storage)
                    if let link = node as? Markdown.Link, let destination = link.destination, !destination.isEmpty {
                        storage.addAttributes([Self.linkDestination: destination,
                                               .underlineStyle: NSUnderlineStyle.single.rawValue], range: label)
                    }
                }
            }
            if node is InlineCode {
                let raw = (source as NSString).substring(with: range)
                let count = raw.prefix(while: { $0 == "`" }).count
                if count > 0, range.length > count * 2,
                   raw.suffix(count).allSatisfy({ $0 == "`" }) {
                    hide(NSRange(location: range.location, length: count), in: storage)
                    hide(NSRange(location: NSMaxRange(range) - count, length: count), in: storage)
                }
            }
            if let item = node as? ListItem {
                let sourceText = source as NSString
                var lineEnd = 0
                sourceText.getLineStart(nil, end: nil, contentsEnd: &lineEnd,
                                        for: NSRange(location: range.location, length: 0))
                let raw = sourceText.substring(with: NSRange(location: range.location, length: lineEnd - range.location))
                let local = NSRange(location: 0, length: (raw as NSString).length)
                if let match = Self.listPattern.firstMatch(in: raw, range: local) {
                    let marker = match.range(at: 1)
                    let checkbox = match.range(at: 2)
                    storage.addAttribute(Self.listMarker, value: true,
                                         range: NSRange(location: range.location, length: 1))
                    if item.checkbox != nil, checkbox.location != NSNotFound {
                        let box = NSRange(location: range.location + checkbox.location, length: checkbox.length)
                        checkboxes.append(box)
                        let checked = (raw as NSString).substring(with: checkbox) != "[ ]"
                        let tint: NSColor = checked ? .controlAccentColor : .secondaryLabelColor
                        storage.addAttribute(.foregroundColor, value: tint, range: box)
                        if let font = Self.checkboxFont {
                            storage.addAttribute(.font, value: font, range: box)
                            hide(NSRange(location: range.location, length: checkbox.location), in: storage)
                            storage.addAttribute(Self.displayGlyph, value: (checked ? "☑" : "☐") as NSString,
                                                 range: NSRange(location: box.location, length: 1))
                            hide(NSRange(location: box.location + 1, length: box.length - 1), in: storage)
                        }
                    } else if marker.length == 1 {
                        storage.addAttribute(Self.displayGlyph, value: "•" as NSString,
                                             range: NSRange(location: range.location + marker.location, length: 1))
                    }
                }
            }
        }

        for child in node.children {
            apply(child, to: storage, inherited: style, checkboxes: &checkboxes)
        }
    }

    private func range(for node: any Markup) -> NSRange? {
        snapshot.byteRange(of: node).flatMap { range(for: $0) }
    }

    private func range(for bytes: Range<Int>) -> NSRange? {
        guard bytes.lowerBound >= 0, bytes.upperBound < offsets.count else { return nil }
        let start = offsets[bytes.lowerBound]
        let end = offsets[bytes.upperBound]
        guard start >= 0, end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func hide(_ range: NSRange, in storage: NSTextStorage) {
        guard range.length > 0, (source as NSString).substring(with: range).rangeOfCharacter(from: .newlines) == nil
        else { return }
        storage.addAttribute(Self.hiddenMarker, value: true, range: range)
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
