import Foundation
import Markdown
import XCTest
@testable import GlancemarkCore

final class GitHubImageEmojiTests: XCTestCase {
    func testRegistryContainsOnlyPinnedCustomGitHubImages() {
        XCTAssertEqual(GitHubImageEmojiData.urls.count, 23)
        XCTAssertEqual(GitHubImageEmojiData.urls["shipit"],
                       "https://github.githubassets.com/images/icons/emoji/shipit.png?v8")
        XCTAssertNil(GitHubImageEmojiData.urls["smile"])
        XCTAssertNil(GitHubImageEmojiData.urls["+1"])
        XCTAssertNil(GitHubImageEmojiData.urls["heart"])
        for address in GitHubImageEmojiData.urls.values {
            let url = URL(string: address)
            XCTAssertEqual(url?.host, "github.githubassets.com")
            XCTAssertEqual(url?.scheme, "https")
            XCTAssertEqual(url?.pathExtension, "png")
            XCTAssertFalse(address.contains("/unicode/"))
            XCTAssertNotNil(url.flatMap { ReaderHTTPS.host(of: $0) })
        }
    }

    func testMatchesKeepCustomAliasesCaseSensitiveAndPreserveSourceRanges() {
        let source = "Done :shipit: :smile::octocat: :unknown: :SHIPIT:"
        let matches = GitHubImageEmoji.matches(in: source)
        XCTAssertEqual(matches.map(\.alias), ["shipit", "octocat"])
        XCTAssertEqual(matches.map { String(source[$0.range]) }, [":shipit:", ":octocat:"])
        XCTAssertEqual(matches.first?.image.alt, ":shipit:")
        XCTAssertEqual(matches.first?.image.width, 20)
    }

    func testPublicCustomEmojiDecodesWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["GLANCEMARK_NETWORK_TEST"] == "1" else {
            throw XCTSkip("Enable GLANCEMARK_NETWORK_TEST for the public emoji image smoke test.")
        }
        let url = try XCTUnwrap(GitHubImageEmoji.matches(in: ":shipit:").first?.url)
        let result = await ReaderHTTPS.load(url)
        guard case let .raster(image)? = result else { return XCTFail("Expected GitHub’s custom emoji PNG") }
        XCTAssertFalse(image.frames.isEmpty)
    }

    func testPlainTextBoundariesAndMarkdownCodeAreSeparate() throws {
        XCTAssertTrue(GitHubImageEmoji.matches(in: "A ::shipit: and a:shipit:b.").isEmpty)
        XCTAssertEqual(GitHubImageEmoji.matches(in: ":shipit::octocat:").map(\.alias), ["shipit", "octocat"])
        let document = Document(parsing: #"Use `:shipit:` and \:shipit:."#)
        let paragraph = try XCTUnwrap(document.child(at: 0) as? Paragraph)
        let decoded = paragraph.children.compactMap { ($0 as? Markdown.Text)?.string }
        XCTAssertEqual(decoded.flatMap { GitHubImageEmoji.matches(in: $0) }.map(\.alias), ["shipit"])
        XCTAssertTrue(paragraph.children.contains { $0 is InlineCode })
    }
}
