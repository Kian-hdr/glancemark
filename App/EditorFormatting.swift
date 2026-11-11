import AppKit
import SwiftUI

@MainActor
final class EditorFormatting: ObservableObject {
    enum Command: Equatable {
        case paragraph, heading(Int), bold, italic, strikethrough
        case bulletList, numberedList, taskList, link
    }

    private weak var editor: MarkdownTextView?

    func attach(_ editor: MarkdownTextView) {
        self.editor = editor
    }

    func detach(_ editor: MarkdownTextView) {
        if self.editor === editor { self.editor = nil }
    }

    func perform(_ command: Command) {
        guard let editor, editor.isEditable, !editor.hasMarkedText() else { return }
        editor.window?.makeFirstResponder(editor)
        editor.applyFormatting(command)
    }
}

enum MarkdownFormatting {
    struct Change {
        let range: NSRange
        let text: String
        let selection: NSRange
    }

    static func change(_ command: EditorFormatting.Command, in text: String, selection: NSRange) -> Change? {
        let source = text as NSString
        guard selection.location >= 0, selection.location <= source.length,
              selection.length >= 0, selection.length <= source.length - selection.location,
              isScalarBoundary(selection.location, in: source),
              isScalarBoundary(NSMaxRange(selection), in: source) else { return nil }
        switch command {
        case .bold: return inline("**", source: source, selection: selection)
        case .italic: return inline("*", source: source, selection: selection)
        case .strikethrough: return inline("~~", source: source, selection: selection)
        case .link: return link(source, selection: selection)
        case .paragraph, .heading, .bulletList, .numberedList, .taskList:
            return block(command, source: source, selection: selection)
        }
    }

    private static func isScalarBoundary(_ location: Int, in source: NSString) -> Bool {
        guard location > 0, location < source.length else { return true }
        return !(0xDC00...0xDFFF).contains(source.character(at: location))
    }

    private static func inline(_ marker: String, source: NSString, selection: NSRange) -> Change {
        let count = (marker as NSString).length
        let end = NSMaxRange(selection)
        let before = selection.location - count
        let after = end + count
        let selected = source.substring(with: selection)
        if before >= 0, after <= source.length,
           source.substring(with: NSRange(location: before, length: count)) == marker,
           source.substring(with: NSRange(location: end, length: count)) == marker,
           (selection.length == 0
            ? isExactMarker(marker, source: source, from: before, to: after)
            : isExactMarker(marker, source: source, from: before, to: selection.location)
                && isExactMarker(marker, source: source, from: end, to: after)) {
            return Change(range: NSRange(location: before, length: selection.length + 2 * count),
                          text: selected, selection: NSRange(location: before, length: selection.length))
        }
        if selected.hasPrefix(marker), selected.hasSuffix(marker), selection.length >= 2 * count,
           isExactMarker(marker, source: source, from: selection.location, to: selection.location + count),
           isExactMarker(marker, source: source, from: end - count, to: end) {
            let inner = (selected as NSString).substring(with: NSRange(location: count, length: selection.length - 2 * count))
            return Change(range: selection, text: inner,
                          selection: NSRange(location: selection.location, length: selection.length - 2 * count))
        }
        return Change(range: selection, text: marker + selected + marker,
                      selection: NSRange(location: selection.location + count, length: selection.length))
    }

    private static func isExactMarker(_ marker: String, source: NSString, from start: Int, to end: Int) -> Bool {
        let character = (marker as NSString).character(at: 0)
        return (start == 0 || source.character(at: start - 1) != character)
            && (end == source.length || source.character(at: end) != character)
    }

    private static func link(_ source: NSString, selection: NSRange) -> Change {
        var label = source.substring(with: selection)
        if label.isEmpty { label = "Link text" }
        label = label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let target = "https://"
        let prefix = "[\(label)]("
        return Change(range: selection, text: prefix + target + ")",
                      selection: NSRange(location: selection.location + (prefix as NSString).length,
                                         length: (target as NSString).length))
    }

    private static let indentation = try? NSRegularExpression(pattern: #"^[ \t]*"#)
    private static let linePrefix = try? NSRegularExpression(
        pattern: #"^(?:#{1,6}(?:[ \t]+|$)|(?:[-+*]|[0-9]{1,9}[.)])[ \t]+(?:\[[ xX]\](?:[ \t]+|$))?)"#
    )

    private static func block(_ command: EditorFormatting.Command, source: NSString, selection: NSRange) -> Change? {
        let end = NSMaxRange(selection)
        let lastCharacter = selection.length > 0 ? end - 1 : selection.location
        let firstLine = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let lastLine = source.lineRange(for: NSRange(location: lastCharacter, length: 0))
        let whole = NSRange(location: firstLine.location, length: NSMaxRange(lastLine) - firstLine.location)
        var lines: [(text: String, removed: NSRange, inserted: Int)] = []
        var location = whole.location
        var number = 1
        repeat {
            var lineStart = 0, lineEnd = 0, contentEnd = 0
            source.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentEnd,
                                for: NSRange(location: location, length: 0))
            let content = source.substring(with: NSRange(location: lineStart, length: contentEnd - lineStart)) as NSString
            let indent = indentation?.firstMatch(in: content as String, range: NSRange(location: 0, length: content.length))?.range.length ?? 0
            let afterIndent = content.substring(from: indent)
            let markerLength = linePrefix?.firstMatch(in: afterIndent, range: NSRange(location: 0, length: (afterIndent as NSString).length))?.range.length ?? 0
            let oldMarker = content.substring(with: NSRange(location: indent, length: markerLength))
            let newline = source.substring(with: NSRange(location: contentEnd, length: lineEnd - contentEnd))
            if afterIndent.isEmpty && whole.length > firstLine.length {
                lines.append((content as String + newline, NSRange(location: lineStart + indent, length: 0), 0))
            } else {
                let prefix: String
                switch command {
                case .paragraph: prefix = ""
                case let .heading(level): prefix = String(repeating: "#", count: min(6, max(1, level))) + " "
                case .bulletList: prefix = "- "
                case .numberedList:
                    prefix = "\(number). "
                    number += 1
                case .taskList: prefix = oldMarker.contains("[x]") || oldMarker.contains("[X]") ? "- [x] " : "- [ ] "
                default: return nil
                }
                let output = content.substring(to: indent) + prefix + content.substring(from: indent + markerLength) + newline
                lines.append((output, NSRange(location: lineStart + indent, length: markerLength), (prefix as NSString).length))
            }
            location = lineEnd
        } while location < NSMaxRange(whole)

        let replacement = lines.map(\.text).joined()
        guard !source.substring(with: whole).utf8.elementsEqual(replacement.utf8) else { return nil }
        func adjusted(_ offset: Int) -> Int {
            var difference = 0
            for line in lines {
                if offset < line.removed.location { break }
                if offset <= NSMaxRange(line.removed) {
                    return line.removed.location + difference + line.inserted
                }
                difference += line.inserted - line.removed.length
            }
            return offset + difference
        }
        let start = adjusted(selection.location)
        let newEnd = adjusted(end)
        return Change(range: whole, text: replacement, selection: NSRange(location: start, length: max(0, newEnd - start)))
    }
}
