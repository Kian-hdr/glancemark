import Foundation
import XCTest
@testable import GlancemarkEditor

final class FileNavigatorTests: XCTestCase {
    func testNavigatorFindsNestedMarkdownAndSkipsLinksAndHiddenFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["README.md", ".hidden.md", "unrelated.txt"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        try Data().write(to: nested.appendingPathComponent("Guide.markdown"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Alias"), withDestinationURL: nested)
        let direct = try DocumentNavigatorItem.contents(of: root)
        XCTAssertEqual(direct.map(\.name), ["Docs", "README.md"])
        XCTAssertEqual(direct[0].children?.count, 0)
        XCTAssertEqual(try DocumentNavigatorItem.contents(of: direct[0].url).map(\.name), ["Guide.markdown"])
        let items = DocumentNavigatorItem.load(root)
        XCTAssertEqual(items.map(\.name), ["Docs", "README.md"])
        XCTAssertEqual(items.flatMap(\.files).map(\.name), ["Guide.markdown", "README.md"])
        XCTAssertEqual(items.compactMap { $0.matching("guide") }.flatMap(\.files).map(\.name), ["Guide.markdown"])
    }

    func testBreadcrumbsKeepTheRootForNestedDocuments() {
        let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let file = root.appendingPathComponent("Docs/Reference/Guide.markdown")
        XCTAssertEqual(DocumentPathBrowser.breadcrumbs(file: file, root: root).map(\.lastPathComponent),
                       ["project", "Docs", "Reference", "Guide.markdown"])
        XCTAssertEqual(DocumentPathBrowser.breadcrumbs(file: file, root: root.appendingPathComponent("Elsewhere"))
            .map(\.lastPathComponent), ["Reference", "Guide.markdown"])
    }

    func testBreadcrumbParentNeverEscapesItsRoot() {
        let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let rootWithoutDirectoryHint = URL(fileURLWithPath: "/tmp/project", isDirectory: false)
        let child = root.appendingPathComponent("Docs", isDirectory: true)
        let outside = URL(fileURLWithPath: "/tmp/project-other", isDirectory: true)
        XCTAssertNil(DocumentPathBrowser.parentFolder(of: rootWithoutDirectoryHint, within: root))
        XCTAssertNil(DocumentPathBrowser.parentFolder(of: outside, within: root))
        XCTAssertEqual(DocumentPathBrowser.parentFolder(of: child, within: root)?.path, root.path)
    }

}
