import XCTest
@testable import GlancemarkEditor

final class InlineDocumentBlockTests: XCTestCase {
    func testInlineEditPreservesUnchangedUnicodeAndLineEndings() throws {
        let original = "# Café\r\n\r\nKeep **this**  \r\n"
        var block = InlineDocumentBlock(range: 0..<"# Café".utf8.count)
        XCTAssertEqual(block.text(in: original), "# Café")
        let revised = try XCTUnwrap(block.replace(in: original, with: "# 日本"))
        XCTAssertEqual(Array(revised.utf8), Array("# 日本\r\n\r\nKeep **this**  \r\n".utf8))
        XCTAssertEqual(block.text(in: revised), "# 日本")
    }

    func testUndoingANewParagraphRemovesOnlyItsInsertedSeparator() throws {
        let original = "# Café\r\n\r\nLast line\r\n"
        let end = original.utf8.count
        var block = InlineDocumentBlock(range: end..<end)
        let inserted = try XCTUnwrap(block.replace(in: original, with: "New"))
        XCTAssertEqual(Array(inserted.utf8), Array((original + "\r\nNew").utf8))
        XCTAssertEqual(block.text(in: inserted), "New")
        let reverted = try XCTUnwrap(block.replace(in: inserted, with: ""))
        XCTAssertEqual(Array(reverted.utf8), Array(original.utf8))
        XCTAssertEqual(block.range, end..<end)
    }
}
