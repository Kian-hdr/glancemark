import Foundation
import XCTest
@testable import GlancemarkCore

final class NavigationTests: XCTestCase {
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
