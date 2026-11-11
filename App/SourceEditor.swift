import AppKit
import SwiftUI

struct SourceEditor: NSViewRepresentable {
    var text: String
    var formatted: Bool
    var active: Bool
    var undo: UndoManager?
    var formatting: EditorFormatting?
    var focusOnCreation: Bool
    var inline: Bool
    var edit: (String) -> Void

    init(text: String, formatted: Bool, active: Bool, undo: UndoManager?,
         formatting: EditorFormatting? = nil, focusOnCreation: Bool = false, inline: Bool = false,
         edit: @escaping (String) -> Void) {
        self.text = text
        self.formatted = formatted
        self.active = active
        self.undo = undo
        self.formatting = formatting
        self.focusOnCreation = focusOnCreation
        self.inline = inline
        self.edit = edit
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = inline
        scroll.drawsBackground = !inline
        view.drawsBackground = !inline
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
        view.textContainerInset = inline ? NSSize(width: 1, height: 2) : NSSize(width: 26, height: 22)
        if inline { view.textContainer?.lineFragmentPadding = 0 }
        view.delegate = context.coordinator
        view.layoutManager?.delegate = context.coordinator
        view.setAccessibilityLabel(inline ? "Markdown block" : "Markdown source")
        view.string = text
        if active {
            formatting?.attach(view)
            if focusOnCreation {
                view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
                view.focusWhenAttached = true
            }
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
        view.isEditable = active
        view.isSelectable = active
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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard inline, let width = proposal.width, width.isFinite, width > 0,
              let view = scroll.documentView as? MarkdownTextView,
              let layout = view.layoutManager, let container = view.textContainer else { return nil }
        let inset = view.textContainerInset
        container.containerSize = NSSize(width: max(1, width - inset.width * 2),
                                         height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = max(26, min(420, ceil(layout.usedRect(for: container).maxY + inset.height * 2 + 2)))
        return CGSize(width: width, height: height)
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
            if parent.inline { view.enclosingScrollView?.invalidateIntrinsicContentSize() }
        }

        func layoutManager(_ layoutManager: NSLayoutManager,
                           shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                           properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                           characterIndexes: UnsafePointer<Int>,
                           font: NSFont, forGlyphRange range: NSRange) -> Int {
            guard parent.formatted, let storage = layoutManager.textStorage else { return 0 }
            var changed = false
            var attributes = Array(UnsafeBufferPointer(start: properties, count: range.length))
            for index in attributes.indices where characterIndexes[index] < storage.length {
                if storage.attribute(LiveMarkdownStyle.hiddenMarker, at: characterIndexes[index], effectiveRange: nil) != nil {
                    attributes[index].insert(.null)
                    changed = true
                }
            }
            guard changed else { return 0 }
            attributes.withUnsafeBufferPointer { buffer in
                if let address = buffer.baseAddress {
                    layoutManager.setGlyphs(glyphs, properties: address, characterIndexes: characterIndexes, font: font, forGlyphRange: range)
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
            let font = parent.formatted ? NSFont.systemFont(ofSize: 15) : NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusWhenAttached, window != nil else { return }
        focusWhenAttached = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEditable else { return }
            self.window?.makeFirstResponder(self)
        }
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
        if formatted, !hasMarkedText(), event.clickCount == 1, let layout = layoutManager, let container = textContainer,
           !checkboxes.isEmpty {
            let location = convert(event.locationInWindow, from: nil)
            let origin = textContainerOrigin
            let point = NSPoint(x: location.x - origin.x, y: location.y - origin.y)
            let glyph = layout.glyphIndex(for: point, in: container)
            if glyph < layout.numberOfGlyphs,
               let range = checkboxes.first(where: { NSLocationInRange(layout.characterIndexForGlyph(at: glyph), $0) }) {
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                if layout.boundingRect(forGlyphRange: glyphs, in: container).contains(point) {
                    window?.makeFirstResponder(self)
                    let old = (string as NSString).substring(with: range)
                    breakUndoCoalescing()
                    insertText(old == "[ ]" ? "[x]" : "[ ]", replacementRange: range)
                    breakUndoCoalescing()
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    func applyFormatting(_ command: EditorFormatting.Command) {
        guard isEditable, !hasMarkedText(),
              let change = MarkdownFormatting.change(command, in: string, selection: selectedRange()) else { return }
        breakUndoCoalescing()
        insertText(change.text, replacementRange: change.range)
        // Delegate validation can reject the insertion; keep a valid selection in that case.
        if NSMaxRange(change.selection) <= (string as NSString).length {
            setSelectedRange(change.selection)
        }
        breakUndoCoalescing()
    }
}
