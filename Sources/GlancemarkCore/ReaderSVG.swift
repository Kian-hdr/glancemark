import Foundation

/// Rebuilds a static SVG subset from XML. The renderer never receives the original XML.
final class ReaderSVG: NSObject, XMLParserDelegate {
    private static let elements: Set<String> = [
        "svg", "g", "defs", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon",
        "text", "tspan", "title", "desc", "linearGradient", "radialGradient", "stop",
        "clipPath", "mask", "pattern", "symbol", "filter", "feGaussianBlur", "image"
    ]
    private static let attributes: Set<String> = [
        "id", "width", "height", "viewBox", "preserveAspectRatio", "version", "x", "y", "x1", "x2", "y1", "y2",
        "cx", "cy", "fx", "fy", "fr", "r", "rx", "ry", "d", "points", "transform", "opacity", "fill", "fill-opacity",
        "fill-rule", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit",
        "stroke-dasharray", "stroke-dashoffset", "font-family", "font-size", "font-weight", "font-style", "text-anchor",
        "dominant-baseline", "alignment-baseline", "textLength", "lengthAdjust", "dx", "dy", "letter-spacing",
        "gradientUnits", "gradientTransform", "spreadMethod", "offset", "stop-color", "stop-opacity",
        "clip-path", "clip-rule", "clipPathUnits", "mask", "maskUnits", "maskContentUnits", "patternUnits",
        "patternContentUnits", "patternTransform", "shape-rendering", "aria-label", "role", "vector-effect",
        "filter", "stdDeviation", "text-rendering"
    ]
    private static let paints: Set<String> = ["fill", "stroke", "clip-path", "mask", "filter"]
    private static let staticStyles: Set<String> = [
        "fill", "fill-rule", "fill-opacity", "clip-rule", "opacity",
        "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin",
        "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset"
    ]
    private var output = ""
    private var depth = 0
    private var count = 0
    private var valid = true
    private let permitsEmbeddedImages: Bool
    private var embeddedImages: [(token: String, href: String)] = []

    private init(permitsEmbeddedImages: Bool) {
        self.permitsEmbeddedImages = permitsEmbeddedImages
    }

    static func sanitize(_ data: Data) throws -> Data {
        try sanitize(data, permitsEmbeddedImages: true)
    }

    private static func sanitize(_ data: Data, permitsEmbeddedImages: Bool) throws -> Data {
        guard data.count <= 512 * 1024, let raw = String(data: data, encoding: .utf8) else {
            throw ReaderRaster.InvalidImage()
        }
        // Strip the standard SVG 1.1 external declaration without loading the DTD.
        let text = raw.replacingOccurrences(of: #"<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">"#, with: "")
        guard !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw ReaderRaster.InvalidImage() }
        let xml = XMLParser(data: Data(text.utf8))
        let sanitizer = ReaderSVG(permitsEmbeddedImages: permitsEmbeddedImages)
        xml.delegate = sanitizer
        xml.shouldResolveExternalEntities = false
        guard xml.parse(), sanitizer.valid, sanitizer.count > 0, sanitizer.depth == 0 else {
            throw ReaderRaster.InvalidImage()
        }
        var result = sanitizer.output
        // XMLParser cannot re-enter parsing from a delegate callback. Resolve embedded documents after the outer parse.
        for image in sanitizer.embeddedImages {
            guard let safe = embeddedSVG(image.href) else { throw ReaderRaster.InvalidImage() }
            result = result.replacingOccurrences(of: image.token, with: safe)
        }
        return Data(result.utf8)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes originalAttributes: [String: String]) {
        guard Self.elements.contains(name), depth < 48, count < 6_000,
              depth == 0 ? name == "svg" : name != "svg" else { reject(parser); return }
        var attributes = originalAttributes
        if let style = attributes["style"], style.utf8.count <= 4_096 {
            for declaration in style.split(separator: ";") {
                let pair = declaration.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { continue }
                let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.staticStyles.contains(key), Self.allowed(key, value: value) { attributes[key] = value }
            }
        }
        count += 1
        let root = depth == 0
        depth += 1
        let embedded: String?
        if name == "image" {
            guard permitsEmbeddedImages, embeddedImages.count < 16,
                  let href = attributes["href"] ?? attributes["xlink:href"],
                  href.hasPrefix("data:image/svg+xml;base64,"), href.utf8.count <= 24_000
            else { reject(parser); return }
            let token = "glancemark-embedded-\(UUID().uuidString)"
            embeddedImages.append((token, href))
            embedded = token
        } else {
            embedded = nil
        }
        output += "<\(name)"
        if root {
            output += " xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\""
            if let box = attributes["viewBox"]?.split(whereSeparator: { $0.isWhitespace || $0 == "," }),
               box.count == 4 {
                for (key, index) in [("width", 2), ("height", 3)] where attributes[key]?.hasSuffix("%") == true {
                    attributes[key] = String(box[index])
                }
            }
            for key in ["width", "height"] {
                if let value = attributes[key],
                   let number = Double(value.hasSuffix("px") ? String(value.dropLast(2)) : value),
                   !number.isFinite || number > 16_384 || number <= 0 {
                    reject(parser)
                    return
                }
            }
        }
        for key in attributes.keys.sorted() {
            guard let value = attributes[key], Self.attributes.contains(key),
                  Self.allowed(key, value: value) else { continue }
            output += " \(key)=\"\(Self.escape(value))\""
        }
        if let embedded { output += " xlink:href=\"\(embedded)\"" }
        output += ">"
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        output += "</\(name)>"
        depth -= 1
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if depth > 0 { output += Self.escape(string) }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if let text = String(data: data, encoding: .utf8), depth > 0 { output += Self.escape(text) }
    }

    private static func embeddedSVG(_ href: String) -> String? {
        let prefix = "data:image/svg+xml;base64,"
        guard href.hasPrefix(prefix), href.utf8.count <= 24_000,
              let bytes = Data(base64Encoded: String(href.dropFirst(prefix.count))),
              bytes.count <= 16_384,
              let sanitized = try? sanitize(bytes, permitsEmbeddedImages: false)
        else { return nil }
        return prefix + sanitized.base64EncodedString()
    }

    private static func allowed(_ key: String, value: String) -> Bool {
        guard value.utf8.count <= 100_000 else { return false }
        if key == "stdDeviation" {
            let values = value.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            return (1...2).contains(values.count) && values.allSatisfy {
                guard let number = Double($0) else { return false }
                return (0...32).contains(number)
            }
        }
        if paints.contains(key) {
            return value.wholeMatch(of: #/url\(#[A-Za-z0-9_.:-]+\)/#) != nil
                || value.wholeMatch(of: #/[#A-Za-z0-9 .,%+\-]+/#) != nil
                || value.wholeMatch(of: #/rgba?\([0-9.,% ]+\)/#) != nil
        }
        return !value.contains("\\") && !value.localizedCaseInsensitiveContains("url(")
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func reject(_ parser: XMLParser) {
        valid = false
        parser.abortParsing()
    }
}
