import Foundation
import XCTest
@testable import GlancemarkCore

final class InlineMathFormattingTests: XCTestCase {
    func testEmphasisSpanningAnEquationSurvivesAsAttributedText() throws {
        let raw = "A **bold $x^2$ result** and *italic $y$ text*."
        let parts = try XCTUnwrap(GitHubMath.inline(raw))
        let template = InlineMathFormatting(parts: parts)
        let styled = try AttributedString(markdown: template.markdown)
        let fragments = try XCTUnwrap(template.fragments(in: styled))
        let formulas = fragments.compactMap { fragment -> String? in
            guard case let .formula(source, _) = fragment else { return nil }
            return source
        }
        XCTAssertEqual(formulas, ["x^2", "y"])
        let text = fragments.compactMap { fragment -> AttributedString? in
            guard case let .text(value) = fragment else { return nil }
            return value
        }.reduce(AttributedString(), +)
        XCTAssertEqual(String(text.characters), "A bold  result and italic  text.")
        for word in ["bold", "result"] {
            let range = try XCTUnwrap(text.range(of: word))
            XCTAssertEqual(text[range].runs.first?.inlinePresentationIntent, .stronglyEmphasized)
        }
        for word in ["italic", "text"] {
            let range = try XCTUnwrap(text.range(of: word))
            XCTAssertEqual(text[range].runs.first?.inlinePresentationIntent, .emphasized)
        }
    }
}
