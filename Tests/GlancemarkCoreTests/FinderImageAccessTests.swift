import Foundation
import XCTest
@testable import GlancemarkCore

final class FinderImageAccessTests: XCTestCase {
    func testFinderTransportAllowsOnlyExactPublicImageHosts() throws {
        for address in ["https://img.shields.io/badge/test-passing-green.svg",
                        "https://raw.githubusercontent.com/example/repo/main/logo.svg"] {
            XCTAssertTrue(FinderImageTransport.permits(try XCTUnwrap(URL(string: address))))
        }
        for address in ["https://img.shields.io.evil.example/a", "https://img.shields.io:8443/a",
                        "https://u:p@img.shields.io/a", "http://img.shields.io/a",
                        "https://127.0.0.1/a", "https://example.com/a"] {
            XCTAssertFalse(FinderImageTransport.permits(try XCTUnwrap(URL(string: address))), address)
        }
    }

    func testCacheIncludesOnlyReferencedLocalImagesAndBothThemes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = directory.appendingPathComponent("repo")
        let cache = directory.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vector = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><rect width="20" height="20"/></svg>"#.utf8)
        for name in ["Light.svg", "Dark.svg", "Unreferenced.svg"] {
            try vector.write(to: repo.appendingPathComponent(name))
        }
        let outside = directory.appendingPathComponent("Outside.svg")
        try vector.write(to: outside)
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("Escape.svg"), withDestinationURL: outside)
        let readme = repo.appendingPathComponent("README.md")
        let snapshot = MarkdownSource(text: """
        <h1>
          <picture>
            <source media="(prefers-color-scheme: dark)" srcset="Dark.svg">
            <img src="Light.svg" alt="Logo">
          </picture>
        </h1>

        ![Escape](Escape.svg)
        ![Remote](https://img.shields.io/badge/test-passing-green.svg)
        """).parse()
        let links = RepositoryLinks(document: readme, allowedFolder: repo)
        XCTAssertEqual(try FinderImageCache.prepare(snapshot: snapshot, links: links, directory: cache), 2)
        for name in ["Light.svg", "Dark.svg"] {
            guard case .vector? = FinderImageCache.load(document: readme, reference: name, directory: cache) else {
                return XCTFail("Expected cached vector for \(name)")
            }
            XCTAssertNil(FinderImageCache.load(document: repo.appendingPathComponent("Other.md"), reference: name, directory: cache))
        }
        for name in ["Unreferenced.svg", "Escape.svg"] {
            XCTAssertNil(FinderImageCache.load(document: readme, reference: name, directory: cache))
        }
    }

    func testPreparedAncestorImageDoesNotRequireFinderFolderAccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let docs = root.appendingPathComponent("docs")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="12" height="12"><rect width="12" height="12"/></svg>"#.utf8)
        try image.write(to: root.appendingPathComponent("Logo.svg"))
        let readme = docs.appendingPathComponent("README.md")
        let reference = "../Logo.svg"
        let source = MarkdownSource(text: "![Logo](\(reference))").parse()
        let finder = RepositoryLinks(document: readme, allowedFolder: docs)
        XCTAssertNil(finder.resolve(reference))
        let editor = RepositoryLinks(document: readme, allowedFolder: root, repositoryRoot: root)
        XCTAssertEqual(try FinderImageCache.prepare(snapshot: source, links: editor, directory: cache), 1)
        guard case .vector? = FinderImageCache.load(document: finder.document, reference: reference, directory: cache) else {
            return XCTFail("Finder should find the prepared image without resolving the original path")
        }
    }

    func testSystemTransportDecodesPublicBadgeWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["GLANCEMARK_NETWORK_TEST"] == "1" else {
            throw XCTSkip("Enable GLANCEMARK_NETWORK_TEST for the system URL loading smoke test.")
        }
        let url = try XCTUnwrap(URL(string: "https://img.shields.io/badge/test-passing-green.svg"))
        let loaded = await FinderImageTransport.load(url)
        guard case .vector? = loaded else { return XCTFail("Expected a decoded public badge") }
    }
}
