import AppKit
import XCTest
@testable import GlancemarkCore

final class OfflineRichRendererTests: XCTestCase {
    func testRichInputsRejectSettingsAndActiveTex() {
        XCTAssertFalse(RichInput.mermaid("%%{init: {\"securityLevel\":\"loose\"}}%%\nflowchart LR").permitted)
        XCTAssertFalse(RichInput.mermaid("---\nconfig: {}\n---\nflowchart LR").permitted)
        XCTAssertFalse(RichInput.math(#"\href{https://example.com}{text}"#, inline: true).permitted)
        XCTAssertFalse(RichInput.math(#"\require{html}"#, inline: false).permitted)
        XCTAssertTrue(RichInput.math(#"\frac{a}{b}"#, inline: true).permitted)
        XCTAssertEqual(GitHubMath.display("$$\n x^2\n$$"), "x^2")
        XCTAssertNil(GitHubMath.display("Cost $20"))
    }

    func testInlineDelimitersLeaveEscapedCurrencyAndCodeAlone() {
        XCTAssertEqual(GitHubMath.inline(#"Cost \$20, then $x^2$ and $`a*b`$."#), [
            .markdown(#"Cost \$20, then "#),
            .formula(source: "x^2", raw: "$x^2$"),
            .markdown(" and "),
            .formula(source: "a*b", raw: "$`a*b`$"),
            .markdown(".")
        ])
        XCTAssertNil(GitHubMath.inline("Costs $20 and $30"))
        XCTAssertNil(GitHubMath.inline("Example `$x$`"))
        XCTAssertNil(GitHubMath.inline(#"Literal \$x\$"#))
    }

    @MainActor
    func testBundledEnginesRenderPixelsWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["GLANCEMARK_WEBKIT_TEST"] == "1" else {
            throw XCTSkip("Enable GLANCEMARK_WEBKIT_TEST for the native WebKit render smoke test.")
        }
        let renderer = OfflineRichRenderer.shared
        let mermaid = RichInput.mermaid("flowchart LR\nA[Start] --> B[End]")
        for (input, dark) in [(mermaid, false), (mermaid, true),
                              (RichInput.math("E = mc^2", inline: false), true),
                              (RichInput.math(#"\frac{a}{b} = c"#, inline: false), false),
                              (RichInput.math(#"x^2 + y^2"#, inline: true), false)] {
            let output = await renderer.render(input, dark: dark)
            let image = try XCTUnwrap(output, "No output for \(input.kind)")
            XCTAssertGreaterThan(image.size.width, 20)
            XCTAssertGreaterThan(image.size.height, 15)
            let bytes = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: bytes))
            if case .math = input {
                let right = bitmap.pixelsWide - 1
                let bottom = bitmap.pixelsHigh - 1
                for x in 0...right {
                    XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: x, y: 0)).alphaComponent, 0.01)
                    XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: x, y: bottom)).alphaComponent, 0.01)
                }
                for y in 0...bottom {
                    XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: y)).alphaComponent, 0.01)
                    XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: right, y: y)).alphaComponent, 0.01)
                }
                let painted = (1..<bottom).contains { y in
                    (1..<right).contains { x in
                        guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                              pixel.alphaComponent > 0.85 else { return false }
                        return dark ? pixel.redComponent > 0.7 : pixel.redComponent < 0.3
                    }
                }
                XCTAssertTrue(painted, "Formula needs visible theme-colored glyphs")
                continue
            }
            let background = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
            XCTAssertLessThan(background.alphaComponent, 0.01, "The native surface should show through the diagram")
            let distinct = (0..<bitmap.pixelsHigh).contains { y in
                (0..<bitmap.pixelsWide).contains { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.alphaComponent > 0.85
                }
            }
            XCTAssertTrue(distinct, "Blank output for \(input.kind)")
        }
    }
}
