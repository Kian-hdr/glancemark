import Foundation
import Markdown
import XCTest
@testable import GlancemarkCore

final class NavigationTests: XCTestCase {
    @MainActor
    func testNestedVaultNoteResolvesSiblingWikiLinkWithinVault() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let design = root.appendingPathComponent("Design")
        let prototypes = root.appendingPathComponent("Prototypes")
        try fm.createDirectory(at: design, withIntermediateDirectories: true)
        try fm.createDirectory(at: prototypes, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let target = design.appendingPathComponent("Operating_Concept.md")
        try Data().write(to: root.appendingPathComponent("INDEX.md"))
        try Data().write(to: target)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Escape"), withDestinationURL: root.deletingLastPathComponent())
        let source = prototypes.appendingPathComponent("Prototype_Build_Plan.md")
        let wikiRoot = RepositoryLinks.nearestWikiRoot(for: source)
        XCTAssertEqual(wikiRoot?.path, root.path)
        let resolver = RepositoryLinks(document: source, allowedFolder: prototypes, wikiRoot: wikiRoot)
        let snapshot = MarkdownSource(text: "[[Design/Operating_Concept]] [[Escape/Outside]]").parse()
        let paragraph = try XCTUnwrap(snapshot.document.child(at: 0))
        let rendered = ReadingView(snapshot: snapshot, links: resolver).inlines(paragraph)
        let addresses = rendered.runs.compactMap(\.link)
        XCTAssertEqual(addresses.first?.path, target.path)
        XCTAssertFalse(addresses.contains { !$0.path.hasPrefix(root.path + "/") })
        XCTAssertNil(resolver.resolve("../Design/Operating_Concept.md"))

        let clicked = try XCTUnwrap(PreviewMarkdownLink(reference: "Design/Operating_Concept.md#current-handoff", isWiki: true))
        let route = try XCTUnwrap(clicked.url)
        let pending = try XCTUnwrap(PreviewMarkdownLink(url: route))
        let granted = RepositoryLinks(document: source, allowedFolder: root, wikiRoot: root)
        XCTAssertEqual(pending.resolve(in: granted), .local(target, fragment: "current-handoff"))
        XCTAssertNil(PreviewMarkdownLink(reference: "https://example.com/outside.md", isWiki: false))
    }

    @MainActor
    func testVaultTableRendersClickableNotesAttachmentsAndAlias() throws {
        let snapshot = MarkdownSource(text: #"""
        | Need | Location |
        | --- | --- |
        | Brief | [[Design/Project_Brief]] |
        | Prototype | [[Prototypes/Prototype_Build_Plan]] |
        | Gauge | [[Prototypes/Fit_Gauge.svg]] |
        | Rules | [[AGENTS]] |
        | Alias | [[Design/Project Brief#Current handoff\|Read it]] |
        | Build package | [[Prototypes/V0.1/README|v0.1 build package]] |
        | Tracker | [Tracker](https://example.com) |
        """#).parse()
        let folder = URL(fileURLWithPath: "/tmp/glancemark-links", isDirectory: true).resolvingSymlinksInPath()
        let links = RepositoryLinks(document: folder.appendingPathComponent("INDEX.md"), allowedFolder: folder,
                                    offersPreviewHandoff: true)
        let view = ReadingView(snapshot: snapshot, links: links)
        let table = try XCTUnwrap(snapshot.document.child(at: 0) as? Markdown.Table)
        let cells = table.body.children.compactMap { $0.child(at: 1) }.map { view.inlines($0) }
        XCTAssertEqual(cells.map { String($0.characters) },
                       ["Project_Brief\u{00A0}↪", "Prototype_Build_Plan\u{00A0}↪", "Fit_Gauge.svg",
                        "AGENTS\u{00A0}↪", "Read it\u{00A0}↪", "v0.1 build package\u{00A0}↪", "Tracker\u{00A0}↗"])
        let urls = cells.map { $0.runs.first?.link }
        XCTAssertEqual(urls.dropLast().map { $0?.path }, [
            "Design/Project_Brief.md", "Prototypes/Prototype_Build_Plan.md", "Prototypes/Fit_Gauge.svg",
            "AGENTS.md", "Design/Project Brief.md", "Prototypes/V0.1/README.md"
        ].map { folder.appendingPathComponent($0).path })
        XCTAssertEqual(urls[4]?.fragment, "current-handoff")
        XCTAssertEqual(urls[6]?.absoluteString, "https://example.com")
        XCTAssertTrue(snapshot.source(of: table)?.contains("[[Prototypes/V0.1/README|v0.1 build package]]") == true)
    }

    @MainActor
    func testWikiLinkHeadingAndLiteralSyntax() throws {
        let snapshot = MarkdownSource(text: #"""
        [[#Current handoff|Jump]] and `[[Code]]` and \[[Escaped]] and ![[Embed]] and [[[Web]]](https://example.com).

        ## Current handoff
        """#).parse()
        let view = ReadingView(snapshot: snapshot)
        let paragraph = try XCTUnwrap(snapshot.document.child(at: 0))
        let inline = view.inlines(paragraph)
        XCTAssertEqual(String(inline.characters), "Jump and [[Code]] and [[Escaped]] and ![[Embed]] and [[Web]].")
        XCTAssertEqual(inline.runs.compactMap(\.link).map(\.absoluteString),
                       ["glancemark-fragment:#current-handoff"])
    }

    func testHeadingIDsReserveExplicitSuffixesAndKeepUnicode() {
        let snapshot = MarkdownSource(text: "# Sample\n## Sample-1\n# Sample\n## This'll be a _Helpful_ Section About Θ!").parse()
        let headings = HeadingIndex(snapshot: snapshot).entries
        XCTAssertEqual(headings.map(\.id), ["sample", "sample-1", "sample-2", "thisll-be-a-helpful-section-about-θ"])
        XCTAssertEqual(headings.map(\.level), [1, 2, 1, 2])
    }

    func testRepositoryPathsAndSymlinkBoundary() throws {
        let fm = FileManager.default
        let testFolder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = testFolder.appendingPathComponent("repo")
        let docs = repo.appendingPathComponent("docs")
        let readme = docs.appendingPathComponent("README.md")
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: testFolder) }
        try Data().write(to: repo.appendingPathComponent(".git"))
        try fm.createSymbolicLink(at: repo.appendingPathComponent("escape"), withDestinationURL: testFolder)
        let resolver = RepositoryLinks(document: readme, allowedFolder: repo)
        XCTAssertEqual(resolver.repositoryRoot?.path, repo.resolvingSymlinksInPath().path)
        XCTAssertEqual(RepositoryLinks.nearestRepositoryRoot(for: readme)?.path, repo.resolvingSymlinksInPath().path)
        XCTAssertNil(RepositoryLinks.nearestRepositoryRoot(for: testFolder.appendingPathComponent("Outside.md")))
        let expected = repo.resolvingSymlinksInPath().appendingPathComponent("assets/badge.svg")
        XCTAssertEqual(resolver.resolve("/assets/badge.svg#icon"), .local(expected, fragment: "icon"))
        XCTAssertEqual(resolver.resolve("../assets/badge.svg"), .local(expected, fragment: nil))
        XCTAssertEqual(resolver.resolve("#read%20me"), .fragment("read me"))
        XCTAssertNil(resolver.resolve("../../outside.txt"))
        XCTAssertNil(resolver.resolve("/escape/outside.txt"))
        XCTAssertNil(resolver.resolve("javascript:alert(1)"))
        XCTAssertNil(resolver.resolve("//example.org"))
        XCTAssertNil(RepositoryLinks(document: readme, allowedFolder: docs).resolve("/assets/badge.svg"))
    }

    func testPreviewHandoffIsOnlyForUnresolvedLocalLinks() {
        let root = URL(fileURLWithPath: "/tmp/glancemark-unknown-root", isDirectory: true)
        let readme = root.appendingPathComponent("README.md")
        let preview = RepositoryLinks(document: readme, allowedFolder: root, offersPreviewHandoff: true)
        let editor = RepositoryLinks(document: readme, allowedFolder: root)
        let selected = RepositoryLinks(document: readme, allowedFolder: root, repositoryRoot: root)
        XCTAssertEqual(selected.resolve("/docs/guide.md"), .local(root.resolvingSymlinksInPath().appendingPathComponent("docs/guide.md"), fragment: nil))
        for destination in ["/docs/guide.md", "../other.md"] {
            XCTAssertEqual(preview.unavailableLocalLink(destination)?.scheme, "glancemark-unavailable-local")
            XCTAssertNil(editor.unavailableLocalLink(destination))
        }
        for destination in ["guide.md", "#anchor", "https://example.org", "//example.org",
                            "file:///tmp/outside.md", "javascript:alert(1)", "glancemark-unavailable-local:",
                            "%00.md", "%5Coutside.md"] {
            XCTAssertNil(preview.unavailableLocalLink(destination), destination)
        }
    }
}
