import AppKit
import Foundation
import Markdown
import XCTest
@testable import GlancemarkCore

final class PublicREADMECompatibilityTests: XCTestCase {
    private func fixture(_ name: String) throws -> (MarkdownSnapshot, String) {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["GLANCEMARK_README_FIXTURES"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("\(name).md"))
        let source = try MarkdownSource(bytes: bytes)
        let html = try String(contentsOf: directory.appendingPathComponent("\(name)-rendered.html"), encoding: .utf8)
        let snapshot = source.parse()
        XCTAssertEqual(source.bytes, bytes)
        XCTAssertTrue(html.contains("markdown-body"))
        return (snapshot, html)
    }

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["GLANCEMARK_README_FIXTURES"] != nil else {
            throw XCTSkip("Run script/verify_public_readmes.sh to fetch the pinned public comparison fixtures.")
        }
    }

    func testIINAIntroAndAlertsMatchGitHub() throws {
        let (snapshot, html) = try fixture("iina")
        let nodes = allNodes(snapshot.document)
        let heading = try XCTUnwrap(HeadingIndex(snapshot: snapshot).entries.first)
        XCTAssertEqual(heading.title, "IINA")
        XCTAssertTrue(html.contains("href=\"#\(heading.id)\""))

        let logo = try XCTUnwrap(nodes.lazy.compactMap(snapshot.source).compactMap(SafeHTML.image).first)
        XCTAssertEqual(logo.source, "https://iina.io/img/icon.png")
        XCTAssertTrue(html.contains("data-canonical-src=\"\(logo.source)\""))

        let kinds = nodes.compactMap { node -> GitHubAlert? in
            guard let quote = node as? BlockQuote, let paragraph = quote.child(at: 0) as? Paragraph,
                  let text = paragraph.child(at: 0) as? Markdown.Text else { return nil }
            return GitHubAlert.parse(text.string)?.kind
        }
        let rendered = html.matches(of: #/class="markdown-alert markdown-alert-([a-z]+)"/#).map { String($0.1) }
        XCTAssertFalse(kinds.isEmpty)
        XCTAssertEqual(kinds.map { $0.rawValue.lowercased() }, rendered)
    }

    @MainActor
    func testMermaidREADMERecognizesAllFencesAndRendersRepresentatives() async throws {
        let (snapshot, html) = try fixture("mermaid")
        let groups = ReadingBlockGroup.collect(Array(snapshot.document.children), in: snapshot)
        let header = groups.prefix(4).flatMap { group -> [SafeHTML.ContainerItem] in
            guard case let .container(container) = group.content else { return [] }
            return container.items
        }
        XCTAssertTrue(header.contains { item in
            guard case let .image(image) = item else { return false }
            return image.centered && image.source.contains("/favicon.svg")
        })
        XCTAssertTrue(header.contains { item in
            guard case let .text(block) = item else { return false }
            return block.alignment == .center
                && block.runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == "Generate diagrams from Markdown-like text."
        })
        XCTAssertNil(SafeHTML.paragraphFragment("<p>Allowed<script>alert(1)</script><p>Next"))
        let blocks = allNodes(snapshot.document).compactMap { $0 as? CodeBlock }.filter { $0.language == "mermaid" }
        XCTAssertEqual(blocks.count, html.matches(of: #/data-type="mermaid"/#).count)
        XCTAssertGreaterThanOrEqual(blocks.count, 10)
        for syntax in ["flowchart", "sequenceDiagram", "gantt"] {
            let code = try XCTUnwrap(blocks.first { $0.code.hasPrefix(syntax) }?.code)
            let image = await OfflineRichRenderer.shared.render(.mermaid(code), dark: false)
            XCTAssertGreaterThan(try XCTUnwrap(image, "No render for \(syntax)").size.width, 25)
        }
    }

    func testLazygitVideoAttachmentURLsMatchGitHub() throws {
        let (snapshot, html) = try fixture("lazygit")
        let nodes = allNodes(snapshot.document)
        let source = nodes.compactMap { node in
            guard node is HTMLBlock || node is Paragraph, let text = snapshot.source(of: node) else { return nil as String? }
            return GitHubVideo.fromHTML(text)?.absoluteString
        }
        let rendered = html.matches(of: #/<video src="([^"]+)"/#).map { String($0.1) }
        XCTAssertGreaterThan(rendered.count, 10)
        XCTAssertEqual(source, rendered)
    }

    func testLazygitSponsorIntroKeepsGitHubContent() throws {
        let (snapshot, html) = try fixture("lazygit")
        let nodes = Array(snapshot.document.children)
        let first = try XCTUnwrap(SafeHTML.container(at: 0, in: nodes, snapshot: snapshot))
        let images = first.items.compactMap { item -> ReaderImage? in
            guard case let .image(image) = item else { return nil }
            return image
        }
        XCTAssertEqual(images.map(\.alt), ["Warp", "Tuple", "Subble"])
        XCTAssertTrue(images.allSatisfy { $0.centered && $0.destination != nil })
        for image in images { XCTAssertTrue(html.contains("alt=\"\(image.alt)\"")) }
        let text = first.items.compactMap { item -> String? in
            guard case let .text(block) = item else { return nil }
            return block.runs.map(\.text).joined()
        }.joined(separator: " ")
        XCTAssertTrue(text.contains("Available for macOS and Linux"))
        XCTAssertTrue(html.contains("Available for macOS and Linux"))
        let next = try XCTUnwrap(SafeHTML.markdownContainer(at: first.consumed + 1, in: nodes, snapshot: snapshot))
        XCTAssertEqual(next.alignment, .center)
        XCTAssertTrue(next.content.contains { node in snapshot.source(of: node).flatMap(GitHubVideo.fromHTML) != nil })
    }

    @MainActor
    func testLOREMastheadKeepsGitHubLogoBadgesAndDiagram() async throws {
        let (snapshot, html) = try fixture("lore")
        let nodes = Array(snapshot.document.children)
        let header = try XCTUnwrap(SafeHTML.markdownContainer(at: 0, in: nodes, snapshot: snapshot))
        XCTAssertEqual(header.alignment, .center)
        let headerSource = header.content.compactMap(snapshot.source)
        let figure = try XCTUnwrap(headerSource.lazy.compactMap(SafeHTML.headingImage).first)
        XCTAssertEqual(figure.image.alt, "L.O.R.E.")
        XCTAssertEqual(figure.image.width, 280)
        XCTAssertEqual(figure.image.source(for: .light), "demo/assets/LORE_Logo.svg")
        XCTAssertEqual(figure.image.source(for: .dark), "demo/assets/LORE_Logo_Dark.svg")
        XCTAssertTrue(figure.anchors.contains("lore") || headerSource.contains { SafeHTML.anchor($0) == "lore" })
        XCTAssertTrue(html.contains("LORE_Logo.svg") && html.contains("LORE_Logo_Dark.svg"))
        let tagline = try XCTUnwrap(header.content.first { snapshot.source(of: $0)?.contains("<strong>L</strong>") == true })
        let renderedTagline = ReadingView(snapshot: snapshot).inlines(tagline)
        XCTAssertEqual(String(renderedTagline.characters), "Layered Operations, Reasoning, and Execution")
        XCTAssertEqual(renderedTagline.runs.first?.inlinePresentationIntent, .stronglyEmphasized)

        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["GLANCEMARK_README_FIXTURES"])
        for filename in ["LORE_Logo.svg", "LORE_Logo_Dark.svg"] {
            let url = URL(fileURLWithPath: root).appendingPathComponent("lore-assets").appendingPathComponent(filename)
            let image = try ReaderImagePayload.load(url)
            guard case let .vector(svg) = image else { return XCTFail("Logo did not decode as SVG") }
            XCTAssertNotNil(NSImage(data: svg))
        }

        let badges = header.content.flatMap(allNodes).compactMap { $0 as? Markdown.Image }.compactMap(\.source)
        XCTAssertEqual(badges.count, 3)
        if ProcessInfo.processInfo.environment["GLANCEMARK_NETWORK_TEST"] == "1" {
            for url in badges.compactMap(URL.init(string:)) {
                let badge = await ReaderHTTPS.load(url)
                guard case .vector? = badge else { return XCTFail("L.O.R.E. badge did not load as an SVG") }
            }
        }
        let diagrams = nodes.compactMap { $0 as? CodeBlock }.filter { $0.language == "mermaid" }
        XCTAssertEqual(diagrams.count, html.matches(of: #/data-type="mermaid"/#).count)
        XCTAssertGreaterThan(diagrams.count, 5)
        for (index, diagram) in diagrams.enumerated() {
            let image = await OfflineRichRenderer.shared.render(.mermaid(diagram.code), dark: true)
            let rendered = try XCTUnwrap(image, "L.O.R.E. diagram \(index + 1) did not render")
            XCTAssertGreaterThan(rendered.size.width, 25)
            if index < 2 {
                // The pinned GitHub SVGs measured 573.75 × 464 and 757.85 × 1864 CSS px
                // in an 823 px README column. Leave room for platform font metrics.
                let expected = index == 0 ? CGSize(width: 573.75, height: 464) : CGSize(width: 757.85, height: 1864)
                XCTAssertEqual(rendered.size.width, expected.width, accuracy: expected.width * 0.15)
                if index == 0 {
                    XCTAssertEqual(rendered.size.height, expected.height, accuracy: expected.height * 0.15)
                } else {
                    // The SVG-only renderer uses a different vertical rank layout.
                    // Keep the tall diagram at readable size without a page-height cap.
                    XCTAssertGreaterThan(rendered.size.height, 1_400)
                }
                print("L.O.R.E. Mermaid \(index + 1): \(rendered.size.width) × \(rendered.size.height) points")
                let bitmap = try XCTUnwrap(rendered.representations.first as? NSBitmapImageRep)
                XCTAssertEqual(bitmap.size, rendered.size)
                XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0.01)
            }
        }
    }

    private func allNodes(_ root: any Markup) -> [any Markup] {
        [root] + root.children.flatMap(allNodes)
    }
}
