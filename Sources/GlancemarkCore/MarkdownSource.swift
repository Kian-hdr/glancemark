import Foundation
import Markdown

/// The bytes that back a document. The parser is a read-only projection.
public struct MarkdownSource: Equatable {
    public enum Failure: Error { case invalidUTF8, invalidEditRange }

    public private(set) var text: String
    private let hasBOM: Bool

    public init(bytes: Data) throws {
        hasBOM = bytes.starts(with: [0xEF, 0xBB, 0xBF])
        let payload = hasBOM ? bytes.dropFirst(3) : bytes[...]
        guard let text = String(bytes: payload, encoding: .utf8) else { throw Failure.invalidUTF8 }
        self.text = text
    }

    public init(text: String) {
        self.text = text
        hasBOM = false
    }

    public var bytes: Data {
        var data = hasBOM ? Data([0xEF, 0xBB, 0xBF]) : Data()
        data.append(contentsOf: text.utf8)
        return data
    }

    /// Applies a Cocoa text edit without rebuilding unaffected Markdown blocks.
    public mutating func replace(_ range: NSRange, with replacement: String) throws {
        let value = text as NSString
        guard range.location != NSNotFound, range.location <= value.length,
              range.length <= value.length - range.location,
              isScalarBoundary(range.location, in: value),
              isScalarBoundary(NSMaxRange(range), in: value)
        else { throw Failure.invalidEditRange }
        text = value.replacingCharacters(in: range, with: replacement)
    }

    private func isScalarBoundary(_ index: Int, in value: NSString) -> Bool {
        guard index > 0, index < value.length else { return true }
        return !(0xDC00...0xDFFF).contains(value.character(at: index))
    }

    public func parse() -> MarkdownSnapshot { MarkdownSnapshot(text: text) }
}

public struct MarkdownSnapshot {
    public let document: Document

    /// Length of the UTF-8 document payload, excluding any file BOM.
    public var byteCount: Int { bytes.count }
    private let bytes: Data
    private let lineStarts: [Int]
    private let footnoteDefinitions: [FootnoteDefinition]
    var footnotes: Footnotes { Footnotes(snapshot: self, definitions: footnoteDefinitions) }

    init(text: String) {
        bytes = Data(text.utf8)
        var starts = [0]
        for i in bytes.indices {
            if bytes[i] == 10 || (bytes[i] == 13 && (i + 1 == bytes.count || bytes[i + 1] != 10)) {
                starts.append(i + 1)
            }
        }
        lineStarts = starts
        let original = Document(parsing: text)
        if text.contains("[^") {
            var excluded: [Range<Int>] = []
            func visit(_ node: any Markup) {
                if node is CodeBlock || node is HTMLBlock, let range = node.range,
                   range.lowerBound.line > 0, range.upperBound.line <= starts.count {
                    let start = starts[range.lowerBound.line - 1]
                    let end = range.upperBound.line < starts.count ? starts[range.upperBound.line] : text.utf8.count
                    excluded.append(start..<end)
                } else {
                    for child in node.children { visit(child) }
                }
            }
            visit(original)
            let (masked, definitions) = Footnotes.extract(from: text, excluding: excluded)
            footnoteDefinitions = definitions
            document = definitions.isEmpty ? original : Document(parsing: masked)
        } else {
            footnoteDefinitions = []
            document = original
        }
    }

    public func byteRange(of node: any Markup) -> Range<Int>? {
        guard let range = node.range, let start = offset(range.lowerBound),
              let end = offset(range.upperBound), start <= end else { return nil }
        return start..<end
    }

    public func source(of node: any Markup) -> String? {
        guard let range = byteRange(of: node) else { return nil }
        return source(in: range)
    }

    func source(in range: Range<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return nil }
        return String(data: bytes[range], encoding: .utf8)
    }

    private func offset(_ location: SourceLocation) -> Int? {
        guard location.line > 0, location.line <= lineStarts.count, location.column > 0 else {
            return nil
        }
        let start = lineStarts[location.line - 1]
        let end = location.line < lineStarts.count ? lineStarts[location.line] : bytes.count
        guard location.column - 1 <= end - start else { return nil }
        return start + location.column - 1
    }
}
