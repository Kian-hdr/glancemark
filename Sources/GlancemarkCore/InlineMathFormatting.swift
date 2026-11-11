import Foundation

struct InlineMathFormatting {
    enum Fragment {
        case text(AttributedString)
        case formula(source: String, raw: String)
    }

    private struct Slot {
        let marker: String
        let source: String
        let raw: String
    }

    let markdown: String
    private let slots: [Slot]

    init(parts: [GitHubMath.Part]) {
        var marker = "\u{E000}"
        let original = parts.map {
            switch $0 {
            case let .markdown(raw), let .formula(_, raw): return raw
            }
        }.joined()
        while original.contains(marker) { marker += "\u{E001}" }

        var output = ""
        var formulas: [Slot] = []
        for part in parts {
            switch part {
            case let .markdown(text):
                output += text
            case let .formula(source, raw):
                let token = marker + String(formulas.count) + "\u{E002}"
                output += token
                formulas.append(Slot(marker: token, source: source, raw: raw))
            }
        }
        markdown = output
        slots = formulas
    }

    /// Slice the result of parsing one entire paragraph so Markdown styles survive on both sides of a formula.
    func fragments(in rendered: AttributedString) -> [Fragment]? {
        var output: [Fragment] = []
        var cursor = rendered.startIndex
        for slot in slots {
            guard let range = rendered.range(of: slot.marker), range.lowerBound >= cursor else { return nil }
            if cursor < range.lowerBound { output.append(.text(AttributedString(rendered[cursor..<range.lowerBound]))) }
            output.append(.formula(source: slot.source, raw: slot.raw))
            cursor = range.upperBound
        }
        if cursor < rendered.endIndex { output.append(.text(AttributedString(rendered[cursor...]))) }
        return output
    }
}
