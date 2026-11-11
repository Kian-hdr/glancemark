import Markdown
import XCTest
@testable import GlancemarkCore

final class EditableReadingLayoutTests: XCTestCase {
    func testActivePreviewsFollowEditedSourceWithoutRepeatingNeighboringText() throws {
        let source = MarkdownSource(text: """
        Ordinary text.

        ```mermaid
        flowchart LR
        A --> B
        ```

        | Left | Right |
        | :--- | ----: |
        | 1 | 2 |

        ![Logo](logo.svg)
        """)
        let snapshot = source.parse()
        let groups = ReadingBlockGroup.collect(Array(snapshot.document.children), in: snapshot)
        XCTAssertEqual(groups.count, 4)
        let diagram = try XCTUnwrap(groups[1].range)
        XCTAssertEqual(ReadingBlockGroup.previews(groups, in: diagram, snapshot: snapshot).map(\.range), [diagram])
        XCTAssertTrue(ReadingBlockGroup.previews(groups, in: diagram.dropLast(), snapshot: snapshot).isEmpty)
        XCTAssertEqual(ReadingBlockGroup.previews(groups, in: 0..<snapshot.byteCount, snapshot: snapshot).count, 3)

        let edited = MarkdownSource(text: source.text.replacingOccurrences(of: "A --> B", with: "A --> C")).parse()
        let editedGroups = ReadingBlockGroup.collect(Array(edited.document.children), in: edited)
        let preview = try XCTUnwrap(ReadingBlockGroup.previews(editedGroups, in: diagram, snapshot: edited).first)
        guard case let .node(node) = preview.content, let code = node as? CodeBlock else {
            return XCTFail("The live diagram should use the updated source block")
        }
        XCTAssertEqual(code.code.trimmingCharacters(in: .newlines), "flowchart LR\nA --> C")
    }

    func testUTF8GroupRangesRetainDisclosureAndHTMLClosingTags() throws {
        let disclosure = """
        <details>
        <summary>Résumé</summary>

        Here's the **body**.

        </details>
        """
        let html = """
        <div align="center">
        <p>Centered content.</p>
        </div>
        """
        let source = MarkdownSource(text: ["# Heading 🙂", disclosure, html, "Next."].joined(separator: "\n\n"))
        let snapshot = source.parse()
        let groups = ReadingBlockGroup.collect(Array(snapshot.document.children), in: snapshot)
        XCTAssertEqual(groups.count, 4)
        guard case .disclosure = groups[1].content, case .container = groups[2].content else {
            return XCTFail("Safe HTML was not grouped")
        }
        let spans = try groups.map { try XCTUnwrap($0.range) }
        XCTAssertEqual(spans.map { snapshot.source(in: $0) }, ["# Heading 🙂", disclosure, html, "Next."])
        XCTAssertEqual(spans[0].upperBound, "# Heading 🙂".utf8.count)
        XCTAssertEqual(spans.last?.upperBound, source.text.utf8.count)
    }

    func testSplitActiveBlockAndKeepNeighboringFragments() {
        let plan = EditableReadingLayout(ranges: [0..<4, 6..<11, 13..<18, 20..<25],
                                         active: 8..<16, byteCount: 25)
        XCTAssertEqual(plan.items, [
            .block(0), .fragment(1, .before, 6..<8), .editor,
            .fragment(2, .after, 16..<18), .block(3), .footnotes
        ])
        XCTAssertTrue(plan.showsTail)
    }

    func testDeletionAtCaretKeepsBothSidesAndOneEditor() {
        let plan = EditableReadingLayout(ranges: [0..<10], active: 4..<4, byteCount: 10)
        XCTAssertEqual(plan.items, [.fragment(0, .before, 0..<4), .editor, .fragment(0, .after, 4..<10), .footnotes])
        XCTAssertTrue(plan.showsTail)
    }

    func testEOFCaretAndFirstTypedBlockKeepEditorIdentity() throws {
        let empty = EditableReadingLayout(ranges: [], active: 0..<0, byteCount: 0)
        XCTAssertEqual(empty.items, [.footnotes, .editor])
        XCTAssertFalse(empty.showsTail)
        let typed = EditableReadingLayout(ranges: [0..<5], active: 0..<5, byteCount: 5)
        XCTAssertEqual(typed.items, [.editor, .footnotes])
        XCTAssertEqual(try XCTUnwrap(empty.items.last).id, try XCTUnwrap(typed.items.first).id)

        let end = EditableReadingLayout(ranges: [0..<4], active: 7..<7, byteCount: 7)
        XCTAssertEqual(end.items, [.block(0), .footnotes, .editor])
        XCTAssertFalse(end.showsTail)
    }

    func testInvalidOrInactiveEditLeavesBlocksAndEOFTarget() {
        let inactive = EditableReadingLayout(ranges: [nil, 0..<2], active: nil, byteCount: 3)
        XCTAssertEqual(inactive.items, [.block(0), .block(1), .footnotes])
        XCTAssertTrue(inactive.showsTail)
        let invalid = EditableReadingLayout(ranges: [nil, 0..<2], active: 3..<4, byteCount: 3)
        XCTAssertEqual(invalid.items, inactive.items)
        XCTAssertTrue(invalid.showsTail)
    }
}
