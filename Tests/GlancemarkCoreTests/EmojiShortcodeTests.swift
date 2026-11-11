import XCTest
@testable import GlancemarkCore

final class EmojiShortcodeTests: XCTestCase {
    func testKnownUnicodeAliasesAndUnknownShortcodes() {
        let input = "Deploy :rocket: :+1: :this_shortcode_does_not_exist:."
        XCTAssertEqual(EmojiShortcodes.replace(in: input[...]), "Deploy 🚀 👍 :this_shortcode_does_not_exist:.")
    }
}
