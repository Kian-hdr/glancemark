import Foundation
import Markdown
import XCTest
@testable import GlancemarkCore

final class MarkdownSourceTests: XCTestCase {
    func testFrontmatterIsHiddenWithoutMovingBodySourceRanges() throws {
        let preamble = "---\r\ntitle: Café\r\nstatus: proposed\r\n---\r\n\r\n"
        let bytes = Data([0xEF, 0xBB, 0xBF] + Array((preamble + "# Actual title\r\n\r\n---\r\n").utf8))
        let source = try MarkdownSource(bytes: bytes)
        let snapshot = source.parse()
        let nodes = Array(snapshot.document.children)
        XCTAssertEqual(HeadingIndex(snapshot: snapshot).entries.map(\.title), ["Actual title"])
        XCTAssertEqual(snapshot.byteRange(of: try XCTUnwrap(nodes.first))?.lowerBound, preamble.utf8.count)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertTrue(nodes.last is ThematicBreak)
        XCTAssertEqual(source.bytes, bytes)
        XCTAssertTrue(MarkdownSource(text: "---\n\nOrdinary Markdown\n").parse().document.child(at: 0) is ThematicBreak)
    }

    func testNoEditPreservesBOMWhitespaceAndCRLF() throws {
        let bytes = Data([0xEF, 0xBB, 0xBF] + Array("# Café  \r\n\r\n`x`\r\n".utf8))
        let source = try MarkdownSource(bytes: bytes)
        let snapshot = source.parse()
        let nodes = Array(snapshot.document.children)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(snapshot.source(of: nodes[0]), "# Café")
        XCTAssertEqual(snapshot.source(of: nodes[1]), "`x`")
        XCTAssertEqual(source.bytes, bytes)
    }

    func testEditUsesUTF16AndPreservesSurroundingBytes() throws {
        let bytes = Data([0xEF, 0xBB, 0xBF] + Array("# 🦉\r\n\r\n  text  \r\n".utf8))
        var source = try MarkdownSource(bytes: bytes)
        XCTAssertThrowsError(try source.replace(NSRange(location: 3, length: 1), with: "x"))
        try source.replace(NSRange(location: 2, length: 2), with: "Swift")
        XCTAssertEqual(source.bytes, Data([0xEF, 0xBB, 0xBF] + Array("# Swift\r\n\r\n  text  \r\n".utf8)))
    }

    func testGFMNodesAndMalformedSourceRemainAvailable() throws {
        let source = MarkdownSource(text: "| A | B |\n| :- | -: |\n| **x** | y |\n\n- [x] Task\n\n<bad")
        let nodes = Array(source.parse().document.children)
        XCTAssertTrue(nodes.first is Table)
        XCTAssertTrue(nodes.contains { $0 is UnorderedList })
        XCTAssertTrue(source.text.hasSuffix("<bad"))
    }
}
