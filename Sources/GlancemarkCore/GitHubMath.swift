import Foundation

enum GitHubMath {
    enum Part: Equatable {
        case markdown(String)
        case formula(source: String, raw: String)
    }

    static func display(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 else { return nil }
        let math = trimmed.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
        return math.isEmpty || math.contains("$$") ? nil : math
    }

    static func inline(_ raw: String) -> [Part]? {
        guard raw.contains("$"), raw.utf8.count <= 65_536 else { return nil }
        var result: [Part] = []
        var start = raw.startIndex
        var i = start
        while i < raw.endIndex {
            let char = raw[i]
            let next = raw.index(after: i)
            if char == "\\" {
                i = next < raw.endIndex ? raw.index(after: next) : next
                continue
            }
            if char == "`" {
                i = endOfCode(in: raw, from: i)
                continue
            }
            if char == "$", next < raw.endIndex, raw[next] != "$",
               i == raw.startIndex || raw[raw.index(before: i)] != "$",
               let match = formula(in: raw, after: next) {
                if start < i { result.append(.markdown(String(raw[start..<i]))) }
                result.append(.formula(source: match.source, raw: String(raw[i..<match.end])))
                start = match.end
                i = start
                continue
            }
            i = next
        }
        guard !result.isEmpty else { return nil }
        if start < raw.endIndex { result.append(.markdown(String(raw[start...]))) }
        return result
    }

    private static func formula(in raw: String, after start: String.Index) -> (source: String, end: String.Index)? {
        if raw[start] == "`" {
            let formulaStart = raw.index(after: start)
            if let close = raw[formulaStart...].range(of: "`$") {
                let formula = String(raw[formulaStart..<close.lowerBound])
                guard !formula.isEmpty, !formula.contains(where: \.isNewline) else { return nil }
                return (formula, close.upperBound)
            }
            return nil
        }
        guard !raw[start].isWhitespace else { return nil }
        var i = start
        while i < raw.endIndex, !raw[i].isNewline {
            let next = raw.index(after: i)
            if raw[i] == "\\" {
                i = next < raw.endIndex ? raw.index(after: next) : next
                continue
            }
            if raw[i] == "$" {
                guard i > start, !raw[raw.index(before: i)].isWhitespace,
                      next == raw.endIndex || (!raw[next].isNumber && raw[next] != "$") else { return nil }
                return (String(raw[start..<i]), next)
            }
            i = next
        }
        return nil
    }

    private static func endOfCode(in raw: String, from start: String.Index) -> String.Index {
        let run = raw[start...].prefix { $0 == "`" }
        var i = run.endIndex
        while i < raw.endIndex {
            if raw[i] == "`" {
                let closing = raw[i...].prefix { $0 == "`" }
                if closing.count == run.count { return closing.endIndex }
                i = closing.endIndex
            } else {
                raw.formIndex(after: &i)
            }
        }
        return run.endIndex
    }
}
