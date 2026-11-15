import Foundation
import Markdown

struct WikiLink {
    let path: String
    let heading: String?
    let label: String
    let range: Range<String.Index>

    private static let syntax = #/\[\[([^\[\]\r\n]+)\]\]/#
    private static let protectedPipe: Character = "\u{001F}"

    static func protectTableAliases(in source: String, document: Document, lineStarts: [Int]) -> String? {
        var bytes = Data(source.utf8)
        var changed = false
        func protectLine(_ index: Int) {
            let start = lineStarts[index]
            let end = index + 1 < lineStarts.count ? lineStarts[index + 1] : bytes.count
            let line = String(decoding: bytes[start..<end], as: UTF8.self)
            guard line.contains("[["), line.contains("|") else { return }
            // Parse the row on its own so table splitting cannot hide inline code or
            // existing Markdown links that contain bracketed text.
            func visitInline(_ node: any Markup) {
                if node is Markdown.Link || node is Markdown.Image { return }
                if let text = node as? Markdown.Text, let range = text.range,
                   range.lowerBound.line == 1, range.upperBound.line == 1 {
                    let rawStart = range.lowerBound.column - 1
                    let rawEnd = range.upperBound.column - 1
                    guard rawStart >= 0, rawEnd >= rawStart, rawEnd <= line.utf8.count,
                          let raw = String(bytes: bytes[(start + rawStart)..<(start + rawEnd)], encoding: .utf8) else { return }
                    for token in raw.matches(of: syntax) {
                        guard isActive(raw[..<token.range.lowerBound]),
                              let pipe = token.1.firstIndex(of: "|"),
                              raw[..<pipe].last != "\\" else { continue }
                        bytes[start + rawStart + raw[..<pipe].utf8.count] = 0x1F
                        changed = true
                    }
                } else {
                    for child in node.children { visitInline(child) }
                }
            }
            visitInline(Document(parsing: line))
        }
        func visit(_ node: any Markup) {
            if node is Markdown.Table, let range = node.range {
                for line in max(0, range.lowerBound.line - 1)..<min(range.upperBound.line, lineStarts.count) {
                    protectLine(line)
                }
            } else {
                for child in node.children { visit(child) }
            }
        }
        visit(document)
        return changed ? String(decoding: bytes, as: UTF8.self) : nil
    }

    private static func isActive(_ prefix: Substring) -> Bool {
        prefix.last != "!" && prefix.reversed().prefix(while: { $0 == "\\" }).count.isMultiple(of: 2)
    }

    static func restoreTablePipes(in text: Substring) -> Substring {
        guard text.contains(protectedPipe) else { return text }
        return Substring(text.replacingOccurrences(of: String(protectedPipe), with: "|"))
    }

    static func matches(in text: Markdown.Text, snapshot: MarkdownSnapshot) -> [Self] {
        guard text.string.contains("[[") else { return [] }
        var ancestor = text.parent
        var cell: Markdown.Table.Cell?
        while let node = ancestor {
            // An existing Markdown link owns its entire label.
            if node is Markdown.Link || node is Markdown.Image { return [] }
            if let tableCell = node as? Markdown.Table.Cell { cell = tableCell }
            ancestor = node.parent
        }
        let source: String?
        if let cell, let cellRange = snapshot.byteRange(of: cell),
           let textRange = snapshot.byteRange(of: text), textRange.lowerBound >= cellRange.lowerBound,
           let original = snapshot.source(of: cell), original.contains("\\|") {
            // cmark removes the backslash before a table pipe before parsing cell inlines.
            // Their columns refer to that intermediate form; other escapes must stay intact.
            let bytes = Array(original.replacingOccurrences(of: "\\|", with: "|").utf8)
            let start = textRange.lowerBound - cellRange.lowerBound
            let end = textRange.upperBound - cellRange.lowerBound
            source = end <= bytes.count ? String(bytes: bytes[start..<end], encoding: .utf8) : nil
        } else {
            source = snapshot.source(of: text)
        }
        guard let source else { return [] }
        let raw = source.matches(of: syntax)
        let rendered = text.string.matches(of: syntax)
        guard raw.count == rendered.count else { return [] }
        return zip(raw, rendered).compactMap { token, display in
            guard isActive(source[..<token.range.lowerBound]) else { return nil }

            let fields = restoreTablePipes(in: display.1).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let target = fields[0].trimmingCharacters(in: .whitespaces)
            let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first else { return nil }
            let path = first.trimmingCharacters(in: .whitespaces)
            let heading = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
            guard !path.isEmpty || !(heading ?? "").isEmpty,
                  !path.contains(":"), !path.contains("\\"), !path.contains("\0"),
                  !path.hasPrefix("//"),
                  heading.map({ !$0.isEmpty && !$0.hasPrefix("^") && !$0.contains("#") }) ?? true
            else { return nil }

            let alias = fields.count == 2 ? fields[1].trimmingCharacters(in: .whitespaces) : ""
            let filename = path.split(separator: "/").last.map(String.init) ?? path
            let name = filename.lowercased().hasSuffix(".md") ? String(filename.dropLast(3)) : filename
            let defaultLabel = heading.map { path.isEmpty ? $0 : "\(name) › \($0)" } ?? name
            return Self(path: path, heading: heading, label: alias.isEmpty ? defaultLabel : alias,
                        range: display.range)
        }
    }

    var fragment: String? { heading.map(GitHubHeadingSlugger.base) }
}
