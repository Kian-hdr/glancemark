import Markdown
import XCTest
@testable import GlancemarkCore

final class GitHubAlertTests: XCTestCase {
    func testAllFiveMarkersAreRecognizedWithoutEatingBody() throws {
        for kind in GitHubAlert.allCases {
            let text = "> [!\(kind.rawValue)]\n> Read **this**.\n"
            let snapshot = MarkdownSource(text: text).parse()
            let quote = try XCTUnwrap(snapshot.document.child(at: 0) as? BlockQuote)
            let paragraph = try XCTUnwrap(quote.child(at: 0) as? Paragraph)
            let first = try XCTUnwrap(paragraph.child(at: 0) as? Markdown.Text)
            XCTAssertEqual(GitHubAlert.parse(first.string)?.kind, kind)
            XCTAssertTrue(paragraph.children.contains { $0 is Strong })
            XCTAssertEqual(snapshot.source(of: quote), String(text.dropLast()))
        }
        XCTAssertNil(GitHubAlert.parse("[!NOTE] ordinary text"))
        XCTAssertNil(GitHubAlert.parse("[!SOMETHING]"))
    }
}
