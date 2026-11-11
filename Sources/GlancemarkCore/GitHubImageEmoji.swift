import Foundation

enum GitHubImageEmoji {
    struct Match: Equatable {
        let alias: String
        let range: Range<String.Index>
        let url: URL

        var shortcode: String { ":\(alias):" }

        var image: ReaderImage {
            ReaderImage(source: url.absoluteString, alt: shortcode, width: 20, height: 20)
        }
    }

    /// Call only with decoded Markdown text. Code spans and fenced code remain literal.
    static func matches(in text: String) -> [Match] {
        guard text.contains(":") else { return [] }
        let token = #/:([a-zA-Z0-9_+\-]+):/#
        var previousTokenEnd: String.Index?
        var inEmojiRun = false
        var matches: [Match] = []
        for candidate in text.matches(of: token) {
            let start = candidate.range.lowerBound
            let atBoundary = start == text.startIndex || text[text.index(before: start)] == " "
                || (inEmojiRun && previousTokenEnd == start)
            previousTokenEnd = candidate.range.upperBound
            inEmojiRun = atBoundary
            guard atBoundary, let address = GitHubImageEmojiData.urls[String(candidate.1)],
                  let url = URL(string: address) else { continue }
            matches.append(Match(alias: String(candidate.1), range: candidate.range, url: url))
        }
        return matches
    }
}
