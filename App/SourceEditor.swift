import AppKit
import CoreText
import SwiftUI

struct SourceEditor: NSViewRepresentable {
    var text: String
    var formatted: Bool
    var active: Bool
    var undo: UndoManager?
    var formatting: EditorFormatting?
    var focusOnCreation: Bool
    var openLink: (String, MarkdownTextView) -> Bool
    var edit: (String) -> Void

    init(text: String, formatted: Bool, active: Bool, undo: UndoManager?,
         formatting: EditorFormatting? = nil, focusOnCreation: Bool = false,
         openLink: @escaping (String, MarkdownTextView) -> Bool = { _, _ in false },
         edit: @escaping (String) -> Void) {
        self.text = text
        self.formatted = formatted
        self.active = active
        self.undo = undo
        self.formatting = formatting
        self.focusOnCreation = focusOnCreation
        self.openLink = openLink
        self.edit = edit
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = view
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.isRichText = false
        view.isEditable = active
        view.isSelectable = active
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.allowsUndo = true
        view.textContainerInset = NSSize(width: 26, height: 22)
        view.openLink = { [weak coordinator = context.coordinator] link, editor in
            coordinator?.parent.openLink(link, editor) ?? false
        }
        view.delegate = context.coordinator
        view.layoutManager?.delegate = context.coordinator
        view.setAccessibilityLabel(formatted ? "Markdown editor" : "Markdown source")
        view.string = text
        if active {
            formatting?.attach(view)
            view.focusWhenAttached = focusOnCreation
        }
        context.coordinator.style(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let previous = context.coordinator.parent
        context.coordinator.parent = self
        guard let view = scroll.documentView as? MarkdownTextView else { return }
        if !active || previous.formatting !== formatting { previous.formatting?.detach(view) }
        if active { formatting?.attach(view) }
        if !active, view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
        if previous.active != active {
            view.isEditable = active
            view.isSelectable = active
        }
        if previous.formatted != formatted {
            view.setAccessibilityLabel(formatted ? "Markdown editor" : "Markdown source")
        }
        guard !view.hasMarkedText() else { return }
        if !view.string.utf8.elementsEqual(text.utf8) {
            // A document reload must never leave old edits in the undo stack.
            view.breakUndoCoalescing()
            view.undoManager?.removeAllActions(withTarget: view)
            view.string = text
        }
        context.coordinator.style(view)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let view = scroll.documentView as? MarkdownTextView else { return }
        coordinator.parent.formatting?.detach(view)
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        var parent: SourceEditor
        private var lastText: String?
        private var lastFormatted: Bool?
        init(_ parent: SourceEditor) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? { parent.undo }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? MarkdownTextView, !view.hasMarkedText() else { return }
            parent.edit(view.string)
            style(view)
        }

        func layoutManager(_ layoutManager: NSLayoutManager,
                           shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                           properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                           characterIndexes: UnsafePointer<Int>,
                           font: NSFont, forGlyphRange range: NSRange) -> Int {
            guard parent.formatted, let storage = layoutManager.textStorage else { return 0 }
            var changed = false
            var attributes = Array(UnsafeBufferPointer(start: properties, count: range.length))
            var displayGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: range.length))
            for index in attributes.indices where characterIndexes[index] < storage.length {
                let character = characterIndexes[index]
                if storage.attribute(LiveMarkdownStyle.hiddenMarker, at: character, effectiveRange: nil) != nil {
                    attributes[index].insert(.null)
                    changed = true
                } else if let symbol = storage.attribute(LiveMarkdownStyle.displayGlyph, at: character,
                                                         effectiveRange: nil) as? NSString, symbol.length == 1 {
                    var scalar = symbol.character(at: 0)
                    var glyph: CGGlyph = 0
                    if CTFontGetGlyphsForCharacters(font, &scalar, &glyph, 1) {
                        displayGlyphs[index] = glyph
                        changed = true
                    }
                }
            }
            guard changed else { return 0 }
            displayGlyphs.withUnsafeBufferPointer { projected in
                attributes.withUnsafeBufferPointer { buffer in
                    if let projected = projected.baseAddress, let properties = buffer.baseAddress {
                        layoutManager.setGlyphs(projected, properties: properties, characterIndexes: characterIndexes,
                                                font: font, forGlyphRange: range)
                    }
                }
            }
            return range.length
        }

        func style(_ view: MarkdownTextView) {
            guard !view.hasMarkedText(), let storage = view.textStorage else { return }
            let current = view.string
            guard lastFormatted != parent.formatted || lastText?.utf8.elementsEqual(current.utf8) != true else { return }
            lastText = current
            lastFormatted = parent.formatted
            view.formatted = parent.formatted
            view.updateDocumentInsets()
            let font = parent.formatted ? NSFont.systemFont(ofSize: 15) : NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
            if parent.formatted { attrs[.paragraphStyle] = LiveMarkdownStyle.paragraphStyle() }
            let all = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(attrs, range: all)
            // A very large document stays editable without paying a full parse on each keystroke.
            view.checkboxes = parent.formatted && current.utf8.count <= 512 * 1024
                ? LiveMarkdownStyle(current).apply(to: storage)
                : []
            storage.endEditing()
            view.layoutManager?.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
            view.typingAttributes = attrs
        }
    }
}

final class MarkdownTextView: NSTextView {
    var formatted = false
    var checkboxes: [NSRange] = []
    var focusWhenAttached = false
    var openLink: (String, MarkdownTextView) -> Bool = { _, _ in false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDocumentInsets()
    }

    func updateDocumentInsets() {
        let margin = formatted ? max(26, (bounds.width - 720) / 2) : 26
        let inset = NSSize(width: margin, height: formatted ? 30 : 22)
        if inset != textContainerInset { textContainerInset = inset }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusWhenAttached, window != nil else { return }
        focusWhenAttached = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEditable else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        if formatted, isEditable, selection.length == 0, !hasMarkedText(), let storage = textStorage {
            if let change = MarkdownFormatting.listReturn(in: string, at: selection.location, hasListMarker: {
                $0 < storage.length && storage.attribute(LiveMarkdownStyle.listMarker, at: $0, effectiveRange: nil) != nil
            }) {
                apply(change)
                return
            }
            if selection.location > 0,
               storage.attribute(LiveMarkdownStyle.bodyParagraph, at: selection.location - 1, effectiveRange: nil) != nil {
                apply(MarkdownFormatting.paragraphReturn(in: string, at: selection.location))
                return
            }
        }
        super.insertNewline(sender)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if formatted, isEditable, !hasMarkedText(), modifiers == .shift,
           event.charactersIgnoringModifiers == "\r" {
            super.insertNewline(nil)
            return
        }
        let selection = selectedRange()
        let source = string as NSString
        if formatted, isEditable, !hasMarkedText(), !event.isARepeat, modifiers.intersection([.command, .control]).isEmpty,
           event.characters == "/", selection.length == 0,
           source.substring(with: source.lineRange(for: selection))
               .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let window {
            let caret = firstRect(forCharacterRange: selection, actualRange: nil)
            let position = convert(window.convertPoint(fromScreen: NSPoint(x: caret.minX, y: caret.minY)), from: nil)
            if editorActionsMenu().popUp(positioning: nil, at: position, in: self) { return }
        }
        super.keyDown(with: event)
    }

    func editorActionsMenu() -> NSMenu {
        let menu = NSMenu(title: "Insert")
        let commands: [(String, EditorFormatting.Command)] = [
            ("Heading 1", .heading(1)), ("Heading 2", .heading(2)), ("Heading 3", .heading(3)),
            ("Bulleted List", .bulletList), ("Numbered List", .numberedList),
            ("Task List", .taskList), ("Link", .link)
        ]
        for (title, command) in commands {
            let item = NSMenuItem(title: title, action: #selector(performEditorAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            menu.addItem(item)
        }
        return menu
    }

    @objc private func performEditorAction(_ item: NSMenuItem) {
        guard let command = item.representedObject as? EditorFormatting.Command else { return }
        applyFormatting(command)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard formatted, !hasMarkedText(), flags == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "b": applyFormatting(.bold)
        case "i": applyFormatting(.italic)
        case "k": applyFormatting(.link)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if formatted, isEditable, !hasMarkedText(), event.clickCount == 1,
           let hit = textHit(at: event.locationInWindow),
           let storage = textStorage {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if modifiers == .command,
               let link = storage.attribute(LiveMarkdownStyle.linkDestination, at: hit, effectiveRange: nil) as? String,
               confirmClick(after: event) {
                if !openLink(link, self) {
                    window?.makeFirstResponder(self)
                    setSelectedRange(NSRange(location: hit, length: 0))
                }
                return
            }
            if modifiers.isEmpty, let range = checkboxes.first(where: { NSLocationInRange(hit, $0) }),
               confirmClick(after: event) {
                window?.makeFirstResponder(self)
                let old = (string as NSString).substring(with: range)
                breakUndoCoalescing()
                insertText(old == "[ ]" ? "[x]" : "[ ]", replacementRange: range)
                breakUndoCoalescing()
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event)
        guard formatted, let hit = textHit(at: event.locationInWindow),
              let link = textStorage?.attribute(LiveMarkdownStyle.linkDestination, at: hit,
                                                effectiveRange: nil) as? String else { return base }
        let menu = (base?.copy() as? NSMenu) ?? NSMenu()
        let item = NSMenuItem(title: "Open Link", action: #selector(openContextLink(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = link
        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        menu.insertItem(item, at: 0)
        return menu
    }

    @objc private func openContextLink(_ item: NSMenuItem) {
        if formatted, let link = item.representedObject as? String { _ = openLink(link, self) }
    }

    private func textHit(at windowPoint: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0 else { return nil }
        let location = convert(windowPoint, from: nil)
        let origin = textContainerOrigin
        let point = NSPoint(x: location.x - origin.x, y: location.y - origin.y)
        let glyph = layout.glyphIndex(for: point, in: container)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point)
        else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }

    private func confirmClick(after down: NSEvent) -> Bool {
        guard let window, let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { return false }
        if next.type == .leftMouseUp,
           abs(next.locationInWindow.x - down.locationInWindow.x) < 4,
           abs(next.locationInWindow.y - down.locationInWindow.y) < 4 {
            return true
        }
        NSApp.postEvent(next, atStart: true)
        return false
    }

    func applyFormatting(_ command: EditorFormatting.Command) {
        guard isEditable, !hasMarkedText(),
              let change = MarkdownFormatting.change(command, in: string, selection: selectedRange()) else { return }
        apply(change)
    }

    private func apply(_ change: MarkdownFormatting.Change) {
        breakUndoCoalescing()
        insertText(change.text, replacementRange: change.range)
        // Delegate validation can reject the insertion; keep a valid selection in that case.
        if NSMaxRange(change.selection) <= (string as NSString).length {
            setSelectedRange(change.selection)
        }
        breakUndoCoalescing()
    }
}
