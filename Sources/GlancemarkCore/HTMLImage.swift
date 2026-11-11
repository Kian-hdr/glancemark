import Foundation

extension SafeHTML {
    struct HeadingImage {
        var anchors: [String]
        var image: ReaderImage
    }

    /// GitHub README mastheads commonly combine an empty anchor and a heading-wrapped picture in one HTML block.
    static func headingImage(_ source: String) -> HeadingImage? {
        var body = source.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        var anchors: [String] = []
        while let match = body.prefixMatch(of: #/(?i)<a\s+(?:name|id)\s*=\s*(?:"[^"<>\s]+"|'[^'<>\s]+'|[A-Za-z0-9_.:-]+)\s*>\s*<\/a\s*>/#),
              let name = anchor(String(body[match.range])) {
            anchors.append(name)
            body = body[match.range.upperBound...].drop(while: \.isWhitespace)
        }
        guard let opening = body.prefixMatch(of: #/(?i)<h([1-6])(?:\s+align\s*=\s*["']?(left|center|right)["']?)?\s*>/#),
              let closing = body.range(of: "</h\(opening.1)>", options: [.caseInsensitive, .backwards]),
              opening.range.upperBound <= closing.lowerBound,
              body[closing.upperBound...].allSatisfy(\.isWhitespace),
              var picture = image(String(body[opening.range.upperBound..<closing.lowerBound]))
        else { return nil }
        if opening.2?.lowercased() == "center" { picture.centered = true }
        return HeadingImage(anchors: anchors, image: picture)
    }

    static func image(_ source: String) -> ReaderImage? {
        var input = source[...].drop(while: \.isWhitespace)
        let paragraph = takeTag("p", from: &input)
        var link: String?
        if let anchor = takeTag("a", from: &input) {
            guard let href = anchor["href"], !href.isEmpty else { return nil }
            link = href
        }

        var variants: [ReaderImage.Theme: String] = [:]
        let isPicture = takeTag("picture", from: &input) != nil
        if isPicture {
            while let attributes = takeTag("source", from: &input) {
                guard let media = attributes["media"], let srcset = attributes["srcset"],
                      let reference = srcset.split(whereSeparator: { $0.isWhitespace || $0 == "," }).first
                else { continue }
                let expression = media.lowercased().filter { !$0.isWhitespace }
                if expression == "(prefers-color-scheme:dark)", variants[.dark] == nil {
                    variants[.dark] = String(reference)
                } else if expression == "(prefers-color-scheme:light)", variants[.light] == nil {
                    variants[.light] = String(reference)
                }
            }
        }
        guard let attributes = takeTag("img", from: &input),
              let address = attributes["src"], !address.isEmpty else { return nil }
        if isPicture && !takeClose("picture", from: &input) { return nil }
        if link != nil && !takeClose("a", from: &input) { return nil }
        if paragraph != nil && !takeClose("p", from: &input) { return nil }
        guard input.isEmpty else { return nil }

        func dimension(_ key: String) -> Double? {
            attributes[key].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 && $0 <= 16_384 ? $0 : nil }
        }
        return ReaderImage(source: address, alt: attributes["alt"] ?? "", destination: link,
                           width: dimension("width"), height: dimension("height"),
                           centered: paragraph?["align"]?.lowercased() == "center", variants: variants)
    }

    private static func takeTag(_ name: String, from input: inout Substring) -> [String: String]? {
        guard let tag = input.prefixMatch(of: #/(?i)<([a-z]+)(\s[^<>]*?)?\s*\/?>/#),
              tag.1.lowercased() == name else { return nil }
        var attributes: [String: String] = [:]
        var pending = (tag.2 ?? "")[...]
        while !pending.allSatisfy(\.isWhitespace) {
            guard let attribute = pending.prefixMatch(of: #/\s+([A-Za-z][A-Za-z0-9_-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/#)
            else { return nil }
            let key = attribute.1.lowercased()
            let accepted = ["src", "alt", "width", "height", "title", "srcset", "media", "type", "href", "align"]
            guard accepted.contains(key), attributes[key] == nil else { return nil }
            let raw = String(attribute.2 ?? attribute.3 ?? attribute.4 ?? "")
            attributes[key] = raw.replacingOccurrences(of: "&amp;", with: "&")
            pending = pending[attribute.range.upperBound...]
        }
        input = input[tag.range.upperBound...].drop(while: \.isWhitespace)
        return attributes
    }

    private static func takeClose(_ name: String, from input: inout Substring) -> Bool {
        guard let tag = input.prefixMatch(of: #/(?i)<\/([a-z]+)\s*>/#),
              tag.1.lowercased() == name else { return false }
        input = input[tag.range.upperBound...].drop(while: \.isWhitespace)
        return true
    }
}
