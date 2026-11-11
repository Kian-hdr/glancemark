import Foundation

extension SafeHTML {
    struct TextBlock {
        struct Run: Equatable {
            var text: String
            var styles: Set<Style>
            var link: String?
        }

        enum Style: String { case bold, italic, underline, strike, superscript, subscriptText, code }
        enum Alignment: String { case left, center, right }

        var headingLevel: Int?
        var alignment: Alignment
        var runs: [Run]
    }

    static func textBlock(_ raw: String) -> TextBlock? {
        guard raw.utf8.count <= 65_536, !raw.localizedCaseInsensitiveContains("<!"),
              !raw.localizedCaseInsensitiveContains("<?") else { return nil }
        let xml = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&nbsp;", with: "&#160;")
            .replacingOccurrences(of: "<br>", with: "<br/>", options: .caseInsensitive)
        let parser = XMLParser(data: Data(xml.utf8))
        let receiver = HTMLTextReceiver()
        parser.shouldResolveExternalEntities = false
        parser.delegate = receiver
        guard parser.parse(), !receiver.invalid, !receiver.runs.isEmpty else { return nil }
        return TextBlock(headingLevel: receiver.heading, alignment: receiver.alignment, runs: receiver.runs)
    }
}

private final class HTMLTextReceiver: NSObject, XMLParserDelegate {
    typealias Block = SafeHTML.TextBlock

    private var ancestors: [(style: Block.Style?, link: String?)] = []
    var invalid = false
    var heading: Int?
    var alignment = Block.Alignment.left
    var runs: [Block.Run] = []

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        let tag = element.lowercased()
        guard ancestors.count < 24, namespaceURI == nil else { reject(parser); return }
        if ancestors.isEmpty {
            let headingTag = tag.count == 2 && tag.hasPrefix("h") ? tag.last?.wholeNumberValue : nil
            guard tag == "p" || headingTag.map({ (1...6).contains($0) }) == true,
                  attributes.keys.allSatisfy({ $0 == "align" }) else { reject(parser); return }
            heading = headingTag
            if let raw = attributes["align"] { alignment = Block.Alignment(rawValue: raw.lowercased()) ?? .left }
            ancestors.append((nil, nil))
            return
        }

        let style: Block.Style?
        let link: String?
        if tag == "a" {
            guard let href = attributes["href"], attributes.keys.allSatisfy({ $0 == "href" || $0 == "title" }),
                  !ancestors.contains(where: { $0.link != nil }) else { reject(parser); return }
            style = nil
            link = href
        } else {
            guard attributes.isEmpty else { reject(parser); return }
            link = nil
            switch tag {
            case "b", "strong": style = .bold
            case "i", "em": style = .italic
            case "u", "ins": style = .underline
            case "s", "del", "strike": style = .strike
            case "sup": style = .superscript
            case "sub": style = .subscriptText
            case "code": style = .code
            case "span": style = nil
            case "br": style = nil; append("\n", lineBreak: true)
            default: reject(parser); return
            }
        }
        ancestors.append((style, link))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if !ancestors.isEmpty { ancestors.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }

    private func append(_ raw: String, lineBreak: Bool = false) {
        guard !ancestors.isEmpty, !raw.isEmpty else { return }
        let styles = Set(ancestors.compactMap(\.style))
        let link = ancestors.compactMap(\.link).last
        var text = lineBreak ? raw : raw.replacingOccurrences(of: #"[ \t\r\n]+"#, with: " ", options: .regularExpression)
        if runs.last?.text.last?.isWhitespace != false, text.hasPrefix(" ") { text.removeFirst() }
        guard !text.isEmpty else { return }
        if let last = runs.last, last.styles == styles, last.link == link {
            runs[runs.count - 1].text += text
        } else {
            runs.append(.init(text: text, styles: styles, link: link))
        }
    }

    private func reject(_ parser: XMLParser) {
        invalid = true
        parser.abortParsing()
    }
}
