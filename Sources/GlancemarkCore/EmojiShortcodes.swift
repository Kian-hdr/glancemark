import Foundation

enum EmojiShortcodes {
    private static let aliases: [String: String] = {
        guard let url = Bundle.module.url(forResource: "Emoji_Aliases", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return result
    }()

    static func replace(in text: Substring) -> String {
        var result = ""
        var offset = text.startIndex
        for match in text.matches(of: #/:([A-Za-z0-9_+\-]+):/#) {
            guard let emoji = aliases[String(match.1)] else { continue }
            result += text[offset..<match.range.lowerBound]
            result += emoji
            offset = match.range.upperBound
        }
        result += text[offset...]
        return result
    }
}
