import Foundation
import XCTest
@testable import GlancemarkCore

final class GitHubHeadingSlugTests: XCTestCase {
    private struct Fixture: Decodable {
        let name: String
        let input: String
        let expected: String
        let markdownOverwrite: String?
    }

    func testPinnedUpstreamSequenceMatchesExactly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixtureURL = root.appendingPathComponent("Fixtures/HeadingSlugs/Upstream_Fixtures.json")
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixtureURL))
        XCTAssertEqual(fixtures.count, 78)
        var slugger = GitHubHeadingSlugger()
        for fixture in fixtures {
            let actual = slugger.next(fixture.input)
            XCTAssertTrue(actual.utf8.elementsEqual(fixture.expected.utf8), fixture.name)
        }

        let explicitHeadings = fixtures.filter { $0.markdownOverwrite != nil }
        let source = MarkdownSource(text: explicitHeadings.compactMap(\.markdownOverwrite).joined(separator: "\n"))
        XCTAssertEqual(HeadingIndex(snapshot: source.parse()).entries.map(\.id),
                       explicitHeadings.map(\.expected))
    }

    func testMarkdownHeadingTextAndCanonicalEquivalence() {
        let text = """
        # A `code sample` and <em>style</em>
        # é
        # é
        # é
        # ΟΣ
        # 😄 Unicode ‿
        # 😄
        # 😄
        """
        let index = HeadingIndex(snapshot: MarkdownSource(text: text).parse())
        let expected = ["a-code-sample-and-style", "e\u{301}", "é", "e\u{301}-1", "ος", "-unicode-‿", "", "-1"]
        XCTAssertEqual(index.entries.map { Data($0.id.utf8) }, expected.map { Data($0.utf8) })
        XCTAssertEqual(index.entries.first?.title, "A code sample and style")
    }
}
