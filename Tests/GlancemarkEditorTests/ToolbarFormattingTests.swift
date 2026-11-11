import AppKit
import XCTest
@testable import GlancemarkEditor

final class ToolbarFormattingTests: XCTestCase {
    func testBlockFormattingPreservesCRLFAndSelectedUTF16Text() throws {
        let original = "- [X] 🚀 first\r\n\r\n  ## second\r\nkeep  "
        let text = original as NSString
        let selected = NSRange(location: text.range(of: "🚀").location,
                               length: NSMaxRange(text.range(of: "second")) - text.range(of: "🚀").location)
        let change = try XCTUnwrap(MarkdownFormatting.change(.numberedList, in: original, selection: selected))
        let edited = text.replacingCharacters(in: change.range, with: change.text) as NSString
        XCTAssertEqual(edited as String, "1. 🚀 first\r\n\r\n  2. second\r\nkeep  ")
        XCTAssertEqual(edited.substring(with: change.selection), "🚀 first\r\n\r\n  2. second")
    }

    func testSwitchingBlockTypeAndFormattingEmptyLines() throws {
        func changed(_ command: EditorFormatting.Command, _ source: String, _ location: Int) throws -> String {
            let change = try XCTUnwrap(MarkdownFormatting.change(command, in: source,
                                                                 selection: NSRange(location: location, length: 0)))
            return (source as NSString).replacingCharacters(in: change.range, with: change.text)
        }
        XCTAssertEqual(try changed(.taskList, "- [X] Done", 8), "- [x] Done")
        XCTAssertEqual(try changed(.paragraph, "### Detail", 6), "Detail")
        XCTAssertEqual(try changed(.heading(2), "", 0), "## ")
        XCTAssertEqual(try changed(.bulletList, "previous\r\n", 10), "previous\r\n- ")
        XCTAssertEqual(try changed(.taskList, "previous", 8), "- [ ] previous")
    }

    func testLinkAndInlineOperationsPreserveTheSource() throws {
        let text = "🚀 [docs] keep"
        let selection = (text as NSString).range(of: "[docs]")
        let link = try XCTUnwrap(MarkdownFormatting.change(.link, in: text, selection: selection))
        let result = (text as NSString).replacingCharacters(in: link.range, with: link.text)
        XCTAssertEqual(result, "🚀 [\\[docs\\]](https://) keep")
        XCTAssertEqual((result as NSString).substring(with: link.selection), "https://")
        let wrapped = try XCTUnwrap(MarkdownFormatting.change(.strikethrough, in: text, selection: selection))
        let bold = (text as NSString).replacingCharacters(in: wrapped.range, with: wrapped.text)
        let unwrapped = try XCTUnwrap(MarkdownFormatting.change(.strikethrough, in: bold, selection: wrapped.selection))
        XCTAssertEqual((bold as NSString).replacingCharacters(in: unwrapped.range, with: unwrapped.text), text)
        XCTAssertNil(MarkdownFormatting.change(.italic, in: text, selection: NSRange(location: 1, length: 0)))
    }

    @MainActor
    func testCommandBusTargetsOnlyCurrentEditorAndWorksWithTextKitUndo() async {
        let first = MarkdownTextView(frame: .zero)
        first.isEditable = true
        first.string = "Old"
        let second = MarkdownTextView(frame: .zero)
        second.isEditable = true
        second.string = "Target"
        second.setSelectedRange(NSRange(location: 0, length: 6))
        let commands = EditorFormatting()
        commands.attach(first)
        commands.attach(second)
        commands.detach(first)
        commands.perform(.bold)
        XCTAssertEqual(first.string, "Old")
        XCTAssertEqual(second.string, "**Target**")
        commands.perform(.bold)
        XCTAssertEqual(second.string, "Target")
        commands.detach(second)
        commands.perform(.italic)
        XCTAssertEqual(second.string, "Target")
    }
}
