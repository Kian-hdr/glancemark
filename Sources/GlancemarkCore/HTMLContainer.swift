import Foundation
import Markdown

extension SafeHTML {
    enum ContainerItem {
        case text(TextBlock)
        case image(ReaderImage)
        case divider
    }

    struct Container {
        let items: [ContainerItem]
        let consumed: Int
    }

    /// A complete HTML-only div can span several CommonMark blocks.
    static func container(at index: Int, in nodes: [any Markup], snapshot: MarkdownSnapshot) -> Container? {
        guard nodes[index] is HTMLBlock, let first = snapshot.source(of: nodes[index]),
              first.prefixMatch(of: #/(?i)\s*<div(?:\s|>)/#) != nil,
              let start = snapshot.byteRange(of: nodes[index])?.lowerBound else { return nil }
        var depth = 0
        for i in index..<nodes.count {
            guard nodes[i] is HTMLBlock, let html = snapshot.source(of: nodes[i]),
                  let span = snapshot.byteRange(of: nodes[i]), span.upperBound - start <= 65_536 else { return nil }
            for tag in html.matches(of: #/(?i)<(/?)div(?:\s[^<>]*)?>/#) {
                depth += tag.1 == "/" ? -1 : 1
                if depth == 0 {
                    guard html[tag.range.upperBound...].allSatisfy(\.isWhitespace),
                          let raw = snapshot.source(in: start..<span.upperBound),
                          let items = containerItems(raw) else { return nil }
                    return Container(items: items, consumed: i - index + 1)
                }
            }
        }
        return nil
    }

    struct MarkdownContainer {
        let alignment: TextBlock.Alignment
        let content: [any Markup]
        let consumed: Int
    }

    static func markdownContainer(at index: Int, in nodes: [any Markup], snapshot: MarkdownSnapshot) -> MarkdownContainer? {
        guard nodes[index] is HTMLBlock, let first = snapshot.source(of: nodes[index]),
              let opening = first.wholeMatch(of: #/(?i)\s*<div(?:\s+align\s*=\s*(?:"(left|center|right)"|'(left|center|right)'|(left|center|right)))?\s*>\s*/#)
        else { return nil }
        let direction = String(opening.1 ?? opening.2 ?? opening.3 ?? "left").lowercased()
        var depth = 1
        for i in (index + 1)..<nodes.count {
            guard nodes[i] is HTMLBlock, let raw = snapshot.source(of: nodes[i]) else { continue }
            for tag in raw.matches(of: #/(?i)<(/?)div(?:\s[^<>]*)?>/#) {
                depth += tag.1 == "/" ? -1 : 1
                if depth == 0 {
                    guard raw.wholeMatch(of: #/(?i)\s*<\/div\s*>\s*/#) != nil else { return nil }
                    return MarkdownContainer(alignment: TextBlock.Alignment(rawValue: direction) ?? .left,
                                             content: Array(nodes[(index + 1)..<i]), consumed: i - index + 1)
                }
            }
        }
        return nil
    }

    static func containerItems(_ raw: String) -> [ContainerItem]? {
        guard raw.utf8.count <= 65_536, !raw.contains("<!"), !raw.contains("<?") else { return nil }
        let xml = raw.replacingOccurrences(of: "&nbsp;", with: "&#160;")
            .replacingOccurrences(of: #"&(?!amp;|lt;|gt;|quot;|apos;|#[0-9]+;|#x[0-9a-fA-F]+;)"#,
                                  with: "&amp;", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<((?:img|br|hr)\b(?:[^"'<>]|"[^"]*"|'[^']*')*?)(?<!/)>"#,
                                  with: "<$1/>", options: .regularExpression)
        let parser = XMLParser(data: Data(xml.utf8))
        let receiver = NativeHTMLContainer()
        parser.shouldResolveExternalEntities = false
        parser.delegate = receiver
        guard parser.parse(), !receiver.invalid, !receiver.items.isEmpty else { return nil }
        return receiver.items
    }

    /// CommonMark can put several adjacent HTML elements in one block.
    /// HTML paragraphs may end at the next block element or at the fragment's end.
    static func paragraphFragment(_ raw: String) -> [ContainerItem]? {
        guard raw.utf8.count <= 65_536,
              raw.prefixMatch(of: #/(?i)\s*<(?:p|h[1-6]|br)(?:\s|\/?>)/#) != nil else { return nil }
        let tags = #/<(\/?)([A-Za-z][A-Za-z0-9]*)(?:\s+(?:[^"'<>]|"[^"]*"|'[^']*')*)?\s*\/?>/#
        var output = "<div>"
        var start = raw.startIndex
        var openParagraph: Substring?
        for token in raw.matches(of: tags) {
            output += raw[start..<token.range.lowerBound]
            let name = token.2.lowercased()
            if token.1 == "/", name == "p" {
                openParagraph = nil
            } else if token.1.isEmpty && ["p", "h1", "h2", "h3", "h4", "h5", "h6", "div", "hr"].contains(name) {
                if let openParagraph { output += "</\(openParagraph)>" }
                openParagraph = name == "p" && !token.0.hasSuffix("/>") ? token.2 : nil
            }
            output += token.0
            start = token.range.upperBound
        }
        output += raw[start...]
        if let openParagraph { output += "</\(openParagraph)>" }
        return containerItems(output + "</div>")
    }
}

private final class NativeHTMLContainer: NSObject, XMLParserDelegate {
    typealias Block = SafeHTML.TextBlock

    private struct Frame {
        var tag: String
        var alignment: Block.Alignment
        var level: Int?
        var style: Block.Style?
        var href: String?
    }

    private var stack: [Frame] = []
    private var runs: [Block.Run] = []
    private var elementCount = 0
    var items: [SafeHTML.ContainerItem] = []
    var invalid = false

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        guard stack.count < 24, elementCount < 1_000, namespaceURI == nil else { reject(parser); return }
        elementCount += 1
        let tag = element.lowercased()
        if stack.isEmpty && tag != "div" { reject(parser); return }

        let level = tag.count == 2 && tag.hasPrefix("h") ? tag.last?.wholeNumberValue : nil
        var next = Frame(tag: tag, alignment: stack.last?.alignment ?? .left,
                         level: stack.last?.level, style: nil, href: stack.last?.href)
        switch tag {
        case "div", "p", "h1", "h2", "h3", "h4", "h5", "h6":
            guard attributes.keys.allSatisfy({ $0 == "align" || $0 == "dir" }) else { reject(parser); return }
            flush()
            next.alignment = attributes["align"].flatMap { Block.Alignment(rawValue: $0.lowercased()) } ?? next.alignment
            next.level = level
        case "a":
            guard next.href == nil, let href = attributes["href"],
                  attributes.keys.allSatisfy({ $0 == "href" || $0 == "title" })
            else { reject(parser); return }
            next.href = href
        case "img":
            guard let source = attributes["src"], !source.isEmpty,
                  attributes.keys.allSatisfy({ ["src", "alt", "width", "height", "title"].contains($0) })
            else { reject(parser); return }
            flush()
            items.append(.image(ReaderImage(source: source, alt: attributes["alt"] ?? "", destination: next.href,
                                            width: dimension(attributes["width"]), height: dimension(attributes["height"]),
                                            centered: next.alignment == .center)))
        case "hr", "br":
            guard attributes.isEmpty else { reject(parser); return }
            if tag == "hr" { flush(); items.append(.divider) }
            else if !runs.isEmpty { append("\n", lineBreak: true) }
        default:
            guard attributes.isEmpty else { reject(parser); return }
            switch tag {
            case "b", "strong": next.style = .bold
            case "i", "em": next.style = .italic
            case "u", "ins": next.style = .underline
            case "s", "del", "strike": next.style = .strike
            case "sup": next.style = .superscript
            case "sub": next.style = .subscriptText
            case "code": next.style = .code
            case "span": break
            default: reject(parser); return
            }
        }
        stack.append(next)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard let frame = stack.last else { return }
        if frame.tag == "div" || frame.tag == "p" || frame.tag.hasPrefix("h") { flush() }
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty, !["img", "hr", "br"].contains(stack.last?.tag ?? "") else { return }
        append(string)
    }

    private func append(_ string: String, lineBreak: Bool = false) {
        var text = lineBreak ? string : string.replacingOccurrences(of: #"[ \r\n\t]+"#, with: " ", options: .regularExpression)
        if runs.last?.text.last?.isWhitespace != false, text.hasPrefix(" ") { text.removeFirst() }
        guard !text.isEmpty else { return }
        let styles = Set(stack.compactMap(\.style))
        let link = stack.last?.href
        if let last = runs.last, last.styles == styles, last.link == link {
            runs[runs.count - 1].text += text
        } else {
            runs.append(.init(text: text, styles: styles, link: link))
        }
    }

    private func flush() {
        if runs.contains(where: { !$0.text.allSatisfy(\.isWhitespace) }) {
            items.append(.text(Block(headingLevel: stack.last?.level, alignment: stack.last?.alignment ?? .left, runs: runs)))
        }
        runs.removeAll(keepingCapacity: true)
    }

    private func dimension(_ raw: String?) -> Double? {
        raw.flatMap(Double.init).flatMap { $0.isFinite && (1...16_384).contains($0) ? $0 : nil }
    }

    private func reject(_ parser: XMLParser) {
        invalid = true
        parser.abortParsing()
    }
}
