import AppKit
import GlancemarkCore
import XCTest
@testable import GlancemarkEditor

final class GlancemarkEditorTests: XCTestCase {
    @MainActor
    func testLiveStylesPreserveSourceAndAvoidCodeFenceHeading() async throws {
        let input = "# 🚀 **Launch**\n\n- [x] Ready\n\n> *Quote*\n\n~~old~~ and `code`\n\n```md\n# code heading\n```\n"
        let storage = NSTextStorage(string: input)
        let boxes = LiveMarkdownStyle(input).apply(to: storage)
        let source = input as NSString
        XCTAssertEqual(storage.string, input)
        XCTAssertEqual(boxes.map { source.substring(with: $0) }, ["[x]"])
        XCTAssertNotNil(storage.attribute(LiveMarkdownStyle.hiddenMarker, at: 0, effectiveRange: nil))
        XCTAssertNil(storage.attribute(LiveMarkdownStyle.hiddenMarker, at: source.range(of: "# code heading").location, effectiveRange: nil))
        let launch = try XCTUnwrap(storage.attribute(.font, at: source.range(of: "Launch").location, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(launch.pointSize, 20)
        XCTAssertTrue(NSFontManager.shared.traits(of: launch).contains(.boldFontMask))
        XCTAssertNotNil(storage.attribute(.strikethroughStyle, at: source.range(of: "old").location, effectiveRange: nil))
        let quote = try XCTUnwrap(storage.attribute(.font, at: source.range(of: "Quote").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: quote).contains(.italicFontMask))
    }

    @MainActor
    func testNativeFormattingShortcutWritesOnlyMarkdownMarkers() async throws {
        let editor = MarkdownTextView(frame: .zero)
        editor.isRichText = false
        editor.formatted = true
        editor.string = "a café z"
        let selected = (editor.string as NSString).range(of: "café")
        editor.setSelectedRange(selected)
        let command = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: 0, context: nil, characters: "b", charactersIgnoringModifiers: "b",
                isARepeat: false, keyCode: 11))
        XCTAssertTrue(editor.performKeyEquivalent(with: command))
        XCTAssertEqual(editor.string, "a **café** z")
        XCTAssertEqual((editor.string as NSString).substring(with: editor.selectedRange()), "café")
        let heading = NSTextStorage(string: "# ")
        _ = LiveMarkdownStyle("# ").apply(to: heading)
        XCTAssertNotNil(heading.attribute(LiveMarkdownStyle.hiddenMarker, at: 0, effectiveRange: nil))
    }

    @MainActor
    func testEditorUsesDocumentUndoManagerAndKeepsCRLF() async throws {
        let document = MarkdownDocument()
        let undo = document.editorUndo
        let original = "# Heading\r\n\r\nNotes  "
        try document.read(from: Data(original.utf8), ofType: "net.daringfireball.markdown")
        var observed = original
        let coordinator = SourceEditor.Coordinator(SourceEditor(text: original, formatted: true, active: true, undo: undo,
                                                              edit: { observed = $0; document.applyEditorText($0) }))
        let editor = MarkdownTextView(frame: .zero)
        editor.delegate = coordinator
        editor.allowsUndo = true
        editor.isRichText = false
        editor.string = original
        XCTAssertTrue(editor.undoManager === undo)
        XCTAssertEqual(Array(editor.string.utf8), Array(original.utf8))
        let range = (original as NSString).range(of: "Notes")
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.insertText("Edited", replacementRange: range)
        editor.breakUndoCoalescing()
        undo.endUndoGrouping()
        XCTAssertEqual(observed, "# Heading\r\n\r\nEdited  ")
        XCTAssertTrue(document.hasUnautosavedChanges)
        undo.undo()
        XCTAssertEqual(observed, original)
        XCTAssertFalse(document.hasUnautosavedChanges)
    }

    @MainActor
    func testNativePasteUsesPlainTextFromPrivatePasteboard() throws {
        let editor = MarkdownTextView(frame: .zero)
        editor.isRichText = false
        editor.string = "# Title\r\n\r\n"
        let original = editor.string
        editor.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let inserted = "A **literal** Markdown link [x](https://example.com)."
        XCTAssertTrue(pasteboard.setString(inserted, forType: .string))
        XCTAssertTrue(editor.readSelection(from: pasteboard, type: .string))
        XCTAssertEqual(Array(editor.string.utf8), Array((original + inserted).utf8))
    }

    @MainActor
    func testNativeMarkedTextCommitsOnlyCompletedComposition() throws {
        let editor = MarkdownTextView(frame: .zero)
        let original = "# Title\r\n\r\n"
        var committed = original
        let coordinator = SourceEditor.Coordinator(SourceEditor(text: original, formatted: true, active: true,
                                                                undo: nil, edit: { committed = $0 }))
        editor.delegate = coordinator
        editor.isRichText = false
        editor.string = original
        editor.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
        editor.setMarkedText("nihon", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(committed, original)
        editor.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(Array(committed.utf8), Array((original + "日本").utf8))
    }

    @MainActor
    func testNativeCheckboxClickChangesOnlyTaskMarker() throws {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 500, height: 140)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = MarkdownTextView(frame: frame)
        editor.isRichText = false
        editor.formatted = true
        editor.textContainerInset = NSSize(width: 16, height: 12)
        let input = "- [ ] Keep source **literal**\r\n"
        editor.string = input
        window.contentView = editor
        let storage = try XCTUnwrap(editor.textStorage)
        editor.checkboxes = LiveMarkdownStyle(input).apply(to: storage)
        let range = try XCTUnwrap(editor.checkboxes.first)
        let layout = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        layout.ensureLayout(for: container)
        let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let box = layout.boundingRect(forGlyphRange: glyphRange, in: container)
        XCTAssertFalse(box.isEmpty)
        let origin = editor.textContainerOrigin
        let local = NSPoint(x: origin.x + box.midX, y: origin.y + box.midY)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: editor.convert(local, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        editor.mouseDown(with: event)
        XCTAssertEqual(Array(editor.string.utf8), Array("- [x] Keep source **literal**\r\n".utf8))
    }

    @MainActor
    func testNativeCoordinatedSaveUsesTheSourcePreservingWriter() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("README.md")
        let type = "net.daringfireball.markdown"
        let initial = Data([0xef, 0xbb, 0xbf]) + Data("# Title\r\n\r\nKeep spaces  ".utf8)
        try initial.write(to: url)
        let document = MarkdownDocument()
        document.fileURL = url
        document.fileType = type
        try document.read(from: initial, ofType: type)
        try await coordinatedSave(document, url: url, type: type)
        XCTAssertEqual(try Data(contentsOf: url), initial)
        document.applyEditorText("# Renamed\r\n\r\nKeep spaces  ")
        try await coordinatedSave(document, url: url, type: type)
        XCTAssertEqual(try Data(contentsOf: url), document.content.source.bytes)
        XCTAssertFalse(document.hasUnautosavedChanges)
    }

    @MainActor
    private func coordinatedSave(_ document: MarkdownDocument, url: URL, type: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.save(to: url, ofType: type, for: .saveOperation) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    @MainActor
    func testDocumentNoOpEditedSaveExternalConflictAndCopy() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("README.md")
        let copy = folder.appendingPathComponent("README_Copy.md")
        let type = "net.daringfireball.markdown"
        let initial = Data([0xef, 0xbb, 0xbf]) + Data("# Cafe\u{301}\r\n\r\nspaced  ".utf8)
        try initial.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_650_000_000)], ofItemAtPath: url.path)
        let originalModified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let doc = MarkdownDocument()
        doc.fileURL = url
        doc.fileType = type
        try doc.read(from: initial, ofType: type)
        try doc.writeSafely(to: url, ofType: type, for: .saveOperation)
        XCTAssertEqual(try Data(contentsOf: url), initial)
        XCTAssertEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, originalModified)

        var edited = doc.content.source
        try edited.replace((edited.text as NSString).range(of: "spaced"), with: "Edited")
        doc.content.source = edited
        try doc.writeSafely(to: url, ofType: type, for: .autosaveInPlaceOperation)
        XCTAssertEqual(try Data(contentsOf: url), edited.bytes)

        let external = Data("written by another app".utf8)
        try external.write(to: url, options: .atomic)
        XCTAssertThrowsError(try doc.writeSafely(to: url, ofType: type, for: .saveOperation))
        XCTAssertEqual(try Data(contentsOf: url), external)
        XCTAssertEqual(doc.content.source.bytes, edited.bytes)
        try doc.writeSafely(to: copy, ofType: type, for: .saveToOperation)
        XCTAssertEqual(try Data(contentsOf: copy), edited.bytes)
        XCTAssertEqual(try Data(contentsOf: url), external)
    }
}
