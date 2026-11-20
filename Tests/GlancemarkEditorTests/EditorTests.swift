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
        XCTAssertNotNil(storage.attribute(LiveMarkdownStyle.hiddenMarker,
                                          at: source.range(of: "**Launch").location, effectiveRange: nil))
        XCTAssertNil(storage.attribute(LiveMarkdownStyle.hiddenMarker,
                                       at: source.range(of: "Launch").location, effectiveRange: nil))
        XCTAssertEqual(storage.attribute(LiveMarkdownStyle.displayGlyph, at: boxes[0].location,
                                         effectiveRange: nil) as? String, "☑")
        XCTAssertTrue(NSFontManager.shared.traits(of: launch).contains(.boldFontMask))
        XCTAssertNotNil(storage.attribute(.strikethroughStyle, at: source.range(of: "old").location, effectiveRange: nil))
        let quote = try XCTUnwrap(storage.attribute(.font, at: source.range(of: "Quote").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: quote).contains(.italicFontMask))
    }

    @MainActor
    func testDocumentWindowHasOneStyledEditorWithCrossParagraphSelection() throws {
        _ = NSApplication.shared
        let document = MarkdownDocument()
        let original = "# Title\r\n\r\nCafé in the first paragraph.\r\n\r\nThe second paragraph.\r\n"
        try document.read(from: Data(original.utf8), ofType: "net.daringfireball.markdown")
        document.makeWindowControllers()
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()

        func editors(in view: NSView) -> [MarkdownTextView] {
            if let editor = view as? MarkdownTextView { return [editor] }
            return view.subviews.flatMap(editors)
        }

        let textViews = editors(in: root)
        XCTAssertEqual(textViews.count, 1)
        let editor = try XCTUnwrap(textViews.first)
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(editor.formatted)
        XCTAssertEqual(Array(editor.string.utf8), Array(original.utf8))

        let source = original as NSString
        let range = source.range(of: "first paragraph.\r\n\r\nThe second")
        editor.setSelectedRange(range)
        XCTAssertEqual(editor.selectedRange(), range)
        XCTAssertEqual(editor.accessibilitySelectedText(), source.substring(with: range))

        let layout = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        func position(at index: Int) -> NSPoint {
            let glyph = layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                          actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyph, in: container)
            let inset = editor.textContainerOrigin
            return editor.convert(NSPoint(x: rect.midX + inset.x, y: rect.midY + inset.y), to: nil)
        }
        func mouse(_ type: NSEvent.EventType, at point: NSPoint, count: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseUp ? 0 : 1))
        }

        let start = position(at: source.range(of: "Café").location)
        let end = position(at: source.range(of: "second paragraph").location + 9)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        NSApp.postEvent(try mouse(.leftMouseUp, at: end), atStart: true)
        NSApp.postEvent(try mouse(.leftMouseDragged, at: end), atStart: true)
        editor.mouseDown(with: try mouse(.leftMouseDown, at: start))
        XCTAssertTrue(editor.accessibilitySelectedText()?.contains("first paragraph.\r\n\r\nThe second") == true)

        let word = source.range(of: "Café")
        let proposed = NSRange(location: word.location + 1, length: 0)
        XCTAssertEqual(editor.selectionRange(forProposedRange: proposed, granularity: .selectByWord), word)
        let wordPoint = position(at: word.location + 1)
        NSApp.postEvent(try mouse(.leftMouseUp, at: wordPoint, count: 2), atStart: true)
        editor.mouseDown(with: try mouse(.leftMouseDown, at: wordPoint, count: 2))
        XCTAssertEqual(editor.accessibilitySelectedText(), "Café")
        editor.selectAll(nil)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: source.length))
        XCTAssertEqual(editors(in: root).first, editor)
        XCTAssertEqual(Array(document.content.source.text.utf8), Array(original.utf8))
        XCTAssertFalse(document.hasUnautosavedChanges)
    }

    @MainActor
    func testUntitledEditorGrowsAndScrollsWhileTyping() throws {
        _ = NSApplication.shared
        let document = MarkdownDocument()
        document.makeWindowControllers()
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()

        func editorScrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView is MarkdownTextView { return scroll }
            return view.subviews.lazy.compactMap(editorScrollView).first
        }

        let scroll = try XCTUnwrap(editorScrollView(in: root))
        let editor = try XCTUnwrap(scroll.documentView as? MarkdownTextView)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertEqual(editor.string, "")

        let text = (1...250).map { "Paragraph \($0). " + String(repeating: "A long, wrapping line. ", count: 6) }
            .joined(separator: "\n\n")
        editor.insertText(text, replacementRange: editor.selectedRange())
        XCTAssertEqual(document.content.source.text, text)

        let tail = "\n\nTyped directly at the end."
        editor.insertText(tail, replacementRange: editor.selectedRange())
        XCTAssertEqual(document.content.source.text, text + tail)

        let last = (editor.string as NSString).range(of: "Typed directly at the end.")
        let layout = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        layout.ensureLayout(for: container)
        editor.scrollRangeToVisible(last)
        let lastGlyph = layout.glyphRange(forCharacterRange: last, actualCharacterRange: nil)
        let lastLine = layout.boundingRect(forGlyphRange: lastGlyph, in: container)
            .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)

        XCTAssertGreaterThan(editor.frame.height, scroll.contentSize.height * 2)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        XCTAssertTrue(scroll.documentVisibleRect.contains(lastLine))
        XCTAssertTrue(scroll.documentView === editor)
    }

    @MainActor
    func testReturnStartsParagraphsAndContinuesOnlyRealMarkdownLists() {
        _ = NSApplication.shared
        let editor = MarkdownTextView(frame: .zero)
        editor.isRichText = false
        let coordinator = SourceEditor.Coordinator(SourceEditor(text: "", formatted: true, active: true, undo: nil,
                                                                edit: { _ in }))
        editor.delegate = coordinator
        for (input, expected) in [
            ("A paragraph", "A paragraph\n\n"),
            ("- Item", "- Item\n- "),
            ("7. Item", "7. Item\n8. "),
            ("- [x] Done", "- [x] Done\n- [ ] "),
            ("- Item\n- ", "- Item\n"),
            ("- [ ] ", ""),
            ("- Item\r\n- Next", "- Item\r\n- Next\r\n- "),
            ("```markdown\n- Literal", "```markdown\n- Literal\n")
        ] {
            editor.string = input
            coordinator.style(editor)
            editor.setSelectedRange(NSRange(location: (input as NSString).length, length: 0))
            editor.insertNewline(nil)
            XCTAssertEqual(editor.string, expected, "Return after \(input.debugDescription)")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: (expected as NSString).length, length: 0))
        }
    }

    @MainActor
    func testInsertMenuAppliesTheSameFormattingAsTheToolbar() throws {
        _ = NSApplication.shared
        let editor = MarkdownTextView(frame: .zero)
        editor.isRichText = false
        editor.formatted = true
        editor.string = "Existing paragraph\n\n"
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))

        let menu = editor.editorActionsMenu()
        let action = try XCTUnwrap(menu.items.firstIndex(where: { $0.title == "Task List" }))
        menu.performActionForItem(at: action)

        XCTAssertEqual(editor.string, "Existing paragraph\n\n- [ ] ")
        XCTAssertEqual(editor.selectedRange().location, (editor.string as NSString).length)
    }

    @MainActor
    func testFormattedLinksKeepTheirSourceAndExposeAnOpenAction() throws {
        _ = NSApplication.shared
        let source = "Read [the **guide**](#details).\n\n- An item\n\n## Details"
        let document = MarkdownDocument()
        try document.read(from: Data(source.utf8), ofType: "net.daringfireball.markdown")
        document.makeWindowControllers()
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()

        func editor(in view: NSView) -> MarkdownTextView? {
            (view as? MarkdownTextView) ?? view.subviews.lazy.compactMap(editor).first
        }

        let text = try XCTUnwrap(editor(in: root))
        let storage = try XCTUnwrap(text.textStorage)
        let label = (source as NSString).range(of: "the **guide")
        let destination = (source as NSString).range(of: "#details")
        XCTAssertEqual(storage.attribute(LiveMarkdownStyle.linkDestination, at: label.location,
                                         effectiveRange: nil) as? String, "#details")
        XCTAssertNotNil(storage.attribute(LiveMarkdownStyle.hiddenMarker, at: destination.location, effectiveRange: nil))
        XCTAssertEqual(LiveMarkdownStyle(source).headingRange(for: "details"),
                       (source as NSString).range(of: "## Details"))

        let layout = try XCTUnwrap(text.layoutManager)
        let container = try XCTUnwrap(text.textContainer)
        let glyph = layout.glyphRange(forCharacterRange: NSRange(location: label.location, length: 1),
                                      actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyph, in: container)
        let origin = text.textContainerOrigin
        let point = text.convert(NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        var opened: String?
        text.openLink = { link, _ in opened = link; return true }
        let menu = try XCTUnwrap(text.menu(for: event))
        XCTAssertEqual(menu.items.first?.title, "Open Link")
        menu.performActionForItem(at: 0)
        XCTAssertEqual(opened, "#details")
        XCTAssertEqual(text.string, source)
        XCTAssertFalse(document.hasUnautosavedChanges)
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
        let coordinator = SourceEditor.Coordinator(SourceEditor(text: input, formatted: true, active: true, undo: nil,
                                                                edit: { _ in }))
        editor.delegate = coordinator
        editor.layoutManager?.delegate = coordinator
        editor.string = input
        window.contentView = editor
        coordinator.style(editor)
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
        let release = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: event.locationInWindow,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0))
        NSApp.postEvent(release, atStart: true)
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
