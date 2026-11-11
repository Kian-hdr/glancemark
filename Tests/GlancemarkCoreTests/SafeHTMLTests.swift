import Foundation
import Markdown
import XCTest
@testable import GlancemarkCore

final class SafeHTMLTests: XCTestCase {
    func testDisclosureKeepsMarkdownAcrossParserBlocksAndLeavesTrailingContent() throws {
        let text = """
        <details open>
        <summary>Read **more**</summary>

        A paragraph with **bold** text.

        - First
        - Second

        </details>

        Outside.
        """
        let source = MarkdownSource(text: text)
        let snapshot = source.parse()
        let nodes = Array(snapshot.document.children)
        let details = try XCTUnwrap(SafeHTML.disclosure(at: 0, in: nodes, snapshot: snapshot))
        XCTAssertTrue(details.isOpen)
        XCTAssertEqual(details.summary, "Read **more**")
        XCTAssertEqual(details.body, "A paragraph with **bold** text.\n\n- First\n- Second")
        XCTAssertEqual(snapshot.source(of: nodes[details.consumed]), "Outside.")
        XCTAssertEqual(source.bytes, Data(text.utf8))
    }

    func testREADMETextHeadingAndLinksKeepNativeStructure() throws {
        let heading = try XCTUnwrap(SafeHTML.textBlock(#"<h1 align="center">IINA</h1>"#))
        XCTAssertEqual(heading.headingLevel, 1)
        XCTAssertEqual(heading.alignment, .center)
        XCTAssertEqual(heading.runs.map(\.text), ["IINA"])
        let paragraph = try XCTUnwrap(SafeHTML.textBlock(#"<p align="center">A <b>native</b> <a href="https://iina.io/">player</a>.</p>"#))
        XCTAssertEqual(paragraph.runs.map(\.text).joined(), "A native player.")
        XCTAssertTrue(paragraph.runs.first(where: { $0.text == "native" })?.styles.contains(.bold) == true)
        XCTAssertEqual(paragraph.runs.first(where: { $0.text == "player" })?.link, "https://iina.io/")
        XCTAssertNil(SafeHTML.textBlock(#"<p>Before <script>alert(1)</script> After</p>"#))
    }

    func testNestedHTMLContainerPreservesLinksImagesAndStructure() throws {
        let raw = """
        <div align="center">
        <sup>Thanks to:</sup><br>
        <a href="https://example.com/"><div><img src="./logo.svg" width="400" alt="Logo"></div>
        <b>Example</b></a>
        <hr>

        <div><p>Second paragraph</p></div>
        </div>

        # After the container
        """
        let snapshot = MarkdownSource(text: raw).parse()
        let nodes = Array(snapshot.document.children)
        let container = try XCTUnwrap(SafeHTML.container(at: 0, in: nodes, snapshot: snapshot))
        let images = container.items.compactMap { if case let .image(value) = $0 { return value }; return nil }
        XCTAssertEqual(images.map(\.source), ["./logo.svg"])
        XCTAssertEqual(images.first?.destination, "https://example.com/")
        XCTAssertTrue(images.first?.centered == true)
        XCTAssertTrue(container.items.contains { if case .divider = $0 { return true }; return false })
        let text = container.items.compactMap { if case let .text(block) = $0 { return block.runs.map(\.text).joined() }; return nil }
        XCTAssertTrue(text.contains { $0.contains("Example") })
        XCTAssertTrue(nodes[container.consumed] is Heading)
        XCTAssertNil(SafeHTML.containerItems("<div><img src='logo.svg' onload='run()'></div>"))
        XCTAssertNil(SafeHTML.containerItems("<div><iframe src='https://example.com'></iframe></div>"))
        XCTAssertNil(SafeHTML.containerItems("<div><script>alert(1)</script></div>"))
    }

    func testMarkupWithActiveAttributesIsNotInterpreted() {
        XCTAssertEqual(SafeHTML.anchor("<a name='user-content'></a>"), "user-content")
        XCTAssertNil(SafeHTML.anchor("<a name='x' onclick='evil()'></a>"))
        XCTAssertNil(SafeHTML.anchor("<a href='javascript:evil()'></a>"))
        XCTAssertEqual(SafeHTML.InlineStyle.tag("</SUP>")?.style, .superscript)
        XCTAssertNil(SafeHTML.InlineStyle.tag("<ins onclick='evil()'>"))
        let hostile = MarkdownSource(text: "<details onclick='evil()'>\n<summary>Title</summary>\n</details>").parse()
        XCTAssertNil(SafeHTML.disclosure(at: 0, in: Array(hostile.document.children), snapshot: hostile))
    }
}
