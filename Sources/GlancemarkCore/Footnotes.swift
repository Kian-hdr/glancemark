import Foundation
import Markdown

struct FootnoteDefinition {
    let label: String
    let body: String
    let range: Range<Int>
}

struct FootnoteReference {
    let number: Int
    let occurrence: Int
    let range: Range<String.Index>
    let sourceOffset: Int
    var noteID: String { "glancemark-note-\(number)" }
    var returnID: String { "glancemark-note-ref-\(number)-\(occurrence)" }
}

struct Footnotes {
    struct Note {
        let definition: FootnoteDefinition
        let references: [FootnoteReference]
        var number: Int { references[0].number }
    }

    let notes: [Note]
    private let references: [Int: [FootnoteReference]]
    private static let marker = #/\[\^([^\s\[\]]+)\]/#
    private static let definition = #/^ {0,3}\[\^([^\s\[\]]+)\]:[ \t]*/#

    init(snapshot: MarkdownSnapshot, definitions: [FootnoteDefinition]) {
        let definitions = Dictionary(definitions.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [String] = []
        var numbers: [String: Int] = [:]
        var byLabel: [String: [FootnoteReference]] = [:]
        var byOffset: [Int: [FootnoteReference]] = [:]

        func visit(_ node: any Markup) {
            if node is Link || node is Image { return }
            if let text = node as? Markdown.Text, let offset = snapshot.byteRange(of: text)?.lowerBound,
               let source = snapshot.source(of: text) {
                let raw = source.matches(of: Self.marker)
                var rawIndex = 0
                for match in text.string.matches(of: Self.marker) {
                    let label = match.1.lowercased()
                    // Consume escaped markers too, so identical later markers keep their place.
                    guard rawIndex < raw.count, raw[rawIndex].1.lowercased() == label else { continue }
                    let token = raw[rawIndex]
                    rawIndex += 1
                    let slashes = source[..<token.range.lowerBound].reversed().prefix { $0 == "\\" }.count
                    guard slashes.isMultiple(of: 2), definitions[label] != nil else { continue }
                    let number = numbers[label] ?? (order.count + 1)
                    if numbers[label] == nil {
                        numbers[label] = number
                        order.append(label)
                    }
                    let reference = FootnoteReference(number: number, occurrence: byLabel[label, default: []].count + 1,
                                                      range: match.range, sourceOffset: offset + source[..<token.range.lowerBound].utf8.count)
                    byLabel[label, default: []].append(reference)
                    byOffset[offset, default: []].append(reference)
                }
            }
            for child in node.children { visit(child) }
        }

        visit(snapshot.document)
        notes = order.compactMap { label in
            guard let definition = definitions[label], let references = byLabel[label] else { return nil }
            return Note(definition: definition, references: references)
        }
        references = byOffset
    }

    func inText(_ node: any Markup, snapshot: MarkdownSnapshot) -> [FootnoteReference] {
        guard let offset = snapshot.byteRange(of: node)?.lowerBound else { return [] }
        return references[offset, default: []]
    }

    func returnOffset(for id: String) -> Int? {
        for note in notes {
            if let reference = note.references.first(where: { $0.returnID == id }) {
                return reference.sourceOffset
            }
        }
        return nil
    }

    func referencedNotes(in range: Range<Int>) -> [Note] {
        notes.filter { note in note.references.contains { range.contains($0.sourceOffset) } }
    }

    static func extract(from text: String, excluding: [Range<Int>]) -> (String, [FootnoteDefinition]) {
        var bytes = Array(text.utf8)
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
        var spans: [Range<Int>] = []
        var start = 0
        for line in lines {
            let end = start + line.utf8.count
            spans.append(start..<end)
            start = end
            if start < bytes.count {
                let crlf = bytes[start] == 13 && start + 1 < bytes.count && bytes[start + 1] == 10
                start += crlf ? 2 : 1
            }
        }
        var definitions: [FootnoteDefinition] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard !excluding.contains(where: { $0.contains(spans[i].lowerBound) }),
                  let match = line.prefixMatch(of: definition) else { i += 1; continue }
            let first = i
            var content = [String(line[match.range.upperBound...])]
            i += 1
            while i < lines.count {
                let continuation = lines[i]
                if continuation.hasPrefix("    ") {
                    content.append(String(continuation.dropFirst(4)))
                } else if continuation.hasPrefix("\t") {
                    content.append(String(continuation.dropFirst()))
                } else if continuation.isEmpty, i + 1 < lines.count,
                          lines[i + 1].hasPrefix("    ") || lines[i + 1].hasPrefix("\t") {
                    content.append("")
                } else { break }
                i += 1
            }
            let range = spans[first].lowerBound..<spans[i - 1].upperBound
            definitions.append(FootnoteDefinition(label: match.1.lowercased(), body: content.joined(separator: "\n"), range: range))
            for offset in range where bytes[offset] != 10 && bytes[offset] != 13 { bytes[offset] = 32 }
        }
        return (String(decoding: bytes, as: UTF8.self), definitions)
    }
}
