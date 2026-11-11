import Foundation

/// Tracks the UTF-8 span of an in-place editor independently of reparsed block boundaries.
struct InlineDocumentBlock {
    private(set) var range: Range<Int>
    private var insertedSeparator: Range<Int>?

    init(range: Range<Int>) { self.range = range }

    func text(in document: String) -> String? {
        let bytes = Data(document.utf8)
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return nil }
        return String(data: bytes[range], encoding: .utf8)
    }

    mutating func replace(in document: String, with replacement: String) -> String? {
        guard let previous = text(in: document), !previous.utf8.elementsEqual(replacement.utf8) else { return nil }
        let bytes = Data(document.utf8)
        let oldRange = range
        var start = range.lowerBound
        var separator = ""
        if replacement.isEmpty, let insertedSeparator, insertedSeparator.upperBound == start {
            start = insertedSeparator.lowerBound
            self.insertedSeparator = nil
        } else if oldRange.isEmpty, start == bytes.count, !bytes.isEmpty,
                  !bytes.suffix(2).elementsEqual([10, 10]), !bytes.suffix(4).elementsEqual([13, 10, 13, 10]) {
            let newline = document.contains("\r\n") ? "\r\n" : "\n"
            separator = bytes.last == 10 ? newline : newline + newline
            insertedSeparator = start..<(start + separator.utf8.count)
        }
        let insertion = start + separator.utf8.count
        var output = Data(bytes.prefix(start))
        output.append(contentsOf: separator.utf8)
        output.append(contentsOf: replacement.utf8)
        output.append(contentsOf: bytes.suffix(from: oldRange.upperBound))
        guard let result = String(data: output, encoding: .utf8) else { return nil }
        range = insertion..<(insertion + replacement.utf8.count)
        return result
    }
}
