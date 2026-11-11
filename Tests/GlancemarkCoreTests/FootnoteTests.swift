import Foundation
import Markdown
import XCTest
@testable import GlancemarkCore

final class FootnoteTests: XCTestCase {
    func testReferencesAreNumberedInReadingOrderAndPreserveSource() {
        let text = """
        First[^b] then [^a] and again[^b]. \\[^b] remains text.

        [^a]: One **important** note.
        [^b]: First line.

            Another paragraph.

        ```text
        [^fake]: This is code.
        ```
        """
        let source = MarkdownSource(text: text)
        let snapshot = source.parse()
        let notes = snapshot.footnotes.notes
        XCTAssertEqual(notes.map(\.definition.label), ["b", "a"])
        XCTAssertEqual(notes.map(\.number), [1, 2])
        XCTAssertEqual(notes.first?.definition.body, "First line.\n\nAnother paragraph.")
        XCTAssertEqual(notes.first?.references.map(\.occurrence), [1, 2])
        XCTAssertEqual(snapshot.document.childCount, 2)
        XCTAssertEqual(source.bytes, Data(text.utf8))
    }

    func testReferencesInCodeAndUndefinedReferencesStayLiteral() {
        let text = "Inline `[^a]` and undefined [^b].\r\n\r\n[^a]: Definition.\r\n"
        let snapshot = MarkdownSource(text: text).parse()
        XCTAssertTrue(snapshot.footnotes.notes.isEmpty)
        XCTAssertEqual(snapshot.source(of: snapshot.document.child(at: 0)!), "Inline `[^a]` and undefined [^b].")
    }

    func testBacklinksLocateDistinctReferenceBlocksAfterUnicode() throws {
        let text = "Résumé [^note].\n\nAnother reference [^note].\n\n[^note]: Content."
        let snapshot = MarkdownSource(text: text).parse()
        let footnotes = snapshot.footnotes
        let references = try XCTUnwrap(footnotes.notes.first).references
        let expected = [text.utf8.distance(from: text.utf8.startIndex, to: try XCTUnwrap(text.range(of: "[^note]")).lowerBound),
                        "Résumé [^note].\n\nAnother reference ".utf8.count]
        let offsets = try references.map { try XCTUnwrap(footnotes.returnOffset(for: $0.returnID)) }
        XCTAssertEqual(offsets, expected)
        XCTAssertNotEqual(offsets[0], offsets[1])
        XCTAssertEqual(footnotes.referencedNotes(in: 0..<offsets[1]).map(\.number), [1])
        XCTAssertEqual(footnotes.referencedNotes(in: offsets[1]..<(offsets[1] + 1)).map(\.number), [1])
        XCTAssertTrue(footnotes.referencedNotes(in: 0..<offsets[0]).isEmpty)
    }
}
