import Foundation
import XCTest
@testable import GlancemarkCore

final class CodeHighlighterTests: XCTestCase {
    func testLanguageInfoAndBounds() {
        XCTAssertEqual(CodeHighlighter.Request(code: "int x;", language: "C++ extra-info")?.language, "cpp")
        XCTAssertEqual(CodeHighlighter.Request(code: "echo hi", language: "language-zsh")?.language, "bash")
        XCTAssertNil(CodeHighlighter.Request(code: "let x = 1", language: nil))
        XCTAssertNil(CodeHighlighter.Request(code: "plain text", language: "plaintext"))
        XCTAssertNil(CodeHighlighter.Request(code: "test", language: "https://remote.invalid/language"))
        XCTAssertNil(CodeHighlighter.Request(code: String(repeating: "a", count: 32_769), language: "js"))
    }

    @MainActor
    func testOfflineGrammarAliasingAndSourcePreservation() async throws {
        guard ProcessInfo.processInfo.environment["GLANCEMARK_WEBKIT_TEST"] == "1" else {
            throw XCTSkip("Set GLANCEMARK_WEBKIT_TEST=1 to exercise the WebKit worker.")
        }
        let samples = [
            ("language-Swift", "let value = \"<script>&👋</script>\"\n"),
            ("py", "def greet(name):\n    return \"hello\"\n"),
            ("nix", "{ pkgs }: let answer = 42; in answer\n"),
            ("c++", "int main() { return 0; }\n")
        ]
        for (language, code) in samples {
            let request = try XCTUnwrap(CodeHighlighter.Request(code: code, language: language))
            let result = await CodeHighlighter.shared.tokens(for: request)
            let tokens = try XCTUnwrap(result, "No offline tokens for \(language)")
            XCTAssertTrue(tokens.map(\.text).joined().utf8.elementsEqual(code.utf8))
            XCTAssertTrue(tokens.contains { !$0.scope.isEmpty }, "No language colors for \(language)")
        }
        let request = try XCTUnwrap(CodeHighlighter.Request(code: "hello", language: "unsupported-test-grammar"))
        let fallback = await CodeHighlighter.shared.tokens(for: request)
        XCTAssertNil(fallback)
    }
}
