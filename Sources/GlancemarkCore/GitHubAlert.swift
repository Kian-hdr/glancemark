import Foundation

public enum GitHubAlert: String, CaseIterable {
    case note = "NOTE", tip = "TIP", important = "IMPORTANT", warning = "WARNING", caution = "CAUTION"

    public static func parse(_ firstParagraph: String) -> (kind: Self, remaining: String)? {
        guard let range = firstParagraph.range(of: #"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*(?:\r\n|\r|\n|$)"#,
                                               options: .regularExpression),
              let end = firstParagraph[range].firstIndex(of: "]"),
              let kind = Self(rawValue: String(firstParagraph[firstParagraph.index(firstParagraph.startIndex, offsetBy: 2)..<end]))
        else { return nil }
        return (kind, String(firstParagraph[range.upperBound...]))
    }
}
