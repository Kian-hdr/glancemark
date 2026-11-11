import AppKit
import Markdown
import SwiftUI

public struct ReadingView: View {
    @ObservedObject private var appearance = ReadingAppearanceStore.shared
    @Environment(\.colorScheme) private var hostScheme
    @Environment(\.isFinderPreview) private var inheritedFinderPreview
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let snapshot: MarkdownSnapshot
    private let footnotes: Footnotes
    private let headings: [Range<Int>: String]
    private let outline: [HeadingIndex.Entry]
    private let documentGroups: [ReadingBlockGroup]
    private let links: RepositoryLinks?
    private let openLocal: (URL, String?) -> Void
    private let width: Double
    private let showOutline: Bool
    private let initialFragment: String?
    private let useHostSurface: Bool
    private let activeEditRange: Range<Int>?
    private let onEditBlock: ((Range<Int>) -> Void)?
    private let activeEditor: (() -> AnyView)?
    private let onUnavailableLocal: (() -> Void)?

    public init(snapshot: MarkdownSnapshot, links: RepositoryLinks? = nil,
                width: Double = 1_200, showOutline: Bool = false, initialFragment: String? = nil,
                useHostSurface: Bool = false, activeEditRange: Range<Int>? = nil,
                onEditBlock: ((Range<Int>) -> Void)? = nil, activeEditor: (() -> AnyView)? = nil,
                onUnavailableLocal: (() -> Void)? = nil,
                openLocal: @escaping (URL, String?) -> Void = { _, _ in }) {
        self.snapshot = snapshot
        footnotes = snapshot.footnotes
        self.links = links
        self.width = width
        self.showOutline = showOutline
        self.initialFragment = initialFragment
        self.useHostSurface = useHostSurface
        self.activeEditRange = activeEditRange
        self.onEditBlock = onEditBlock
        self.activeEditor = activeEditor
        self.onUnavailableLocal = onUnavailableLocal
        self.openLocal = openLocal
        let outline = HeadingIndex(snapshot: snapshot).entries
        self.outline = outline
        headings = Dictionary(uniqueKeysWithValues: outline.map { ($0.sourceRange, $0.id) })
        documentGroups = ReadingBlockGroup.collect(Array(snapshot.document.children), in: snapshot)
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 15) {
                    if showOutline {
                        ForEach(outline, id: \.sourceRange) { heading in
                            Button(heading.title) { scrollToHeading(heading.id, using: proxy) }
                                .buttonStyle(.link)
                                .padding(.leading, CGFloat(heading.level - 1) * 12)
                        }
                        Divider()
                    }
                    if let onEditBlock {
                        editableDocument(onEditBlock, using: proxy)
                    } else {
                        ForEach(documentGroups.indices, id: \.self) { index in
                            groupView(documentGroups[index], using: proxy).id(DocumentBlockTarget(index: index))
                        }
                        if !footnotes.notes.isEmpty { footnoteSection }
                    }
                }
                .font(.system(size: appearance.value.preset.textSize))
                .lineSpacing(3)
                .frame(maxWidth: min(width, appearance.value.preset.width), alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if useHostSurface && !outline.isEmpty {
                    HStack {
                        Spacer()
                        Menu {
                            ForEach(outline, id: \.sourceRange) { heading in
                                Button(heading.title) { scrollToHeading(heading.id, using: proxy) }
                            }
                        } label: {
                            Label("Document outline", systemImage: "list.bullet.indent")
                                .labelStyle(.iconOnly)
                        }
                        .menuStyle(.borderlessButton)
                        .help("Document outline")
                        .accessibilityLabel("Document outline")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
            .background(surface)
            .environment(\.colorScheme, appearance.value.theme.colorScheme ?? hostScheme)
            .environment(\.isFinderPreview, useHostSurface || inheritedFinderPreview)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "glancemark-unavailable-local" {
                    onUnavailableLocal?()
                    return .handled
                }
                if ["glancemark-fragment", "glancemark-note"].contains(url.scheme ?? ""), let fragment = url.fragment {
                    if url.scheme == "glancemark-note" {
                        if let offset = footnotes.returnOffset(for: fragment), let target = blockTarget(at: offset) {
                            proxy.scrollTo(target, anchor: .top)
                        } else {
                            proxy.scrollTo(NoteTarget(id: fragment), anchor: .top)
                        }
                    } else {
                        scrollToHeading(fragment, using: proxy)
                    }
                    return .handled
                }
                if url.isFileURL {
                    openLocal(url, url.fragment?.removingPercentEncoding)
                    return .handled
                }
                return .systemAction
            })
            .onChange(of: initialFragment, initial: true) { _, fragment in
                if let fragment { scrollToHeading(fragment, using: proxy) }
            }
        }
    }

    private struct DocumentBlockTarget: Hashable { let index: Int }

    private func blockTarget(at offset: Int) -> DocumentBlockTarget? {
        documentGroups.firstIndex { $0.range?.contains(offset) == true }.map(DocumentBlockTarget.init(index:))
    }

    private func scrollToHeading(_ id: String, using proxy: ScrollViewProxy) {
        if let range = headings.first(where: { $0.value.utf8.elementsEqual(id.utf8) })?.key,
           let target = blockTarget(at: range.lowerBound) {
            proxy.scrollTo(target, anchor: .top)
        } else {
            proxy.scrollTo(Data(id.utf8), anchor: .top)
        }
    }

    private var surface: AnyShapeStyle {
        let settings = appearance.value
        let materialAllowed = settings.allowsHostMaterial(in: hostScheme, reduceTransparency: reduceTransparency)
        if useHostSurface && materialAllowed && settings.preset.surface != .paper {
            return AnyShapeStyle(Color.clear)
        }
        let scheme = settings.theme.colorScheme ?? hostScheme
        switch settings.preset.surface {
        case .paper:
            return AnyShapeStyle(scheme == .dark ? Color(white: 0.12) : Color(white: 0.98))
        case .translucent where materialAllowed:
            return AnyShapeStyle(.thinMaterial)
        default:
            let window = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            var background: NSColor?
            window?.performAsCurrentDrawingAppearance {
                background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
            }
            return AnyShapeStyle(background.map(Color.init(nsColor:)) ?? (scheme == .dark ? Color(white: 0.12) : Color(white: 0.98)))
        }
    }

    private func blocks(_ nodes: [any Markup]) -> some View {
        let rows = ReadingBlockGroup.collect(nodes, in: snapshot).flatMap(render)
        return ForEach(rows.indices, id: \.self) { rows[$0] }
    }

    private func render(_ group: ReadingBlockGroup) -> [AnyView] {
        switch group.content {
        case let .disclosure(disclosure):
            return [AnyView(disclosureView(disclosure))]
        case let .container(container):
            return container.items.map { item in
                switch item {
                case let .text(block): return AnyView(htmlTextBlock(block))
                case let .image(image): return AnyView(imageView(image))
                case .divider: return AnyView(Divider())
                }
            }
        case let .markdownContainer(container):
            let alignment: HorizontalAlignment = container.alignment == .center ? .center
                : container.alignment == .right ? .trailing : .leading
            return [AnyView(VStack(alignment: alignment, spacing: 10) {
                blocks(container.content)
            }
            .multilineTextAlignment(container.alignment == .center ? .center : container.alignment == .right ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center)))]
        case let .node(node):
            return [block(node)]
        }
    }

    @ViewBuilder private func groupView(_ group: ReadingBlockGroup, using proxy: ScrollViewProxy) -> some View {
        let views = render(group)
        let content = VStack(alignment: .leading, spacing: 15) {
            ForEach(views.indices, id: \.self) { views[$0] }
        }
        let notes = group.range.map(footnotes.referencedNotes(in:)) ?? []
        if notes.isEmpty {
            content
        } else {
            content
                .contextMenu { footnoteActions(notes, using: proxy) }
                .accessibilityActions { footnoteActions(notes, using: proxy) }
        }
    }

    private func footnoteActions(_ notes: [Footnotes.Note], using proxy: ScrollViewProxy) -> some View {
        ForEach(notes, id: \.number) { note in
            Button("Go to footnote \(note.number)") {
                proxy.scrollTo(NoteTarget(id: note.references[0].noteID), anchor: .top)
            }
        }
    }

    @ViewBuilder
    private func editableDocument(_ beginEdit: @escaping (Range<Int>) -> Void, using proxy: ScrollViewProxy) -> some View {
        let groups = documentGroups
        let layout = EditableReadingLayout(ranges: groups.map(\.range),
                                           active: activeEditor == nil ? nil : activeEditRange,
                                           byteCount: snapshot.byteCount)
        ForEach(layout.items) { item in
            switch item {
            case let .block(index):
                let group = groups[index]
                editTarget(group.range, beginEdit: beginEdit) {
                    groupView(group, using: proxy)
                }
                .id(DocumentBlockTarget(index: index))
            case let .fragment(_, _, range):
                editTarget(range, beginEdit: beginEdit) {
                    if let source = snapshot.source(in: range) {
                        let reader = ReadingView(snapshot: MarkdownSource(text: source).parse(), links: links, openLocal: openLocal)
                        VStack(alignment: .leading, spacing: 15) {
                            reader.blocks(Array(reader.snapshot.document.children))
                        }
                    }
                }
            case .footnotes:
                if !footnotes.notes.isEmpty { footnoteSection }
            case .editor:
                VStack(alignment: .leading, spacing: 12) {
                    activeEditor?()
                    if let activeEditRange {
                        let views = ReadingBlockGroup.previews(groups, in: activeEditRange, snapshot: snapshot).flatMap(render)
                        ForEach(views.indices, id: \.self) { views[$0] }
                    }
                }
            }
        }
        if layout.showsTail {
            Button {
                beginEdit(snapshot.byteCount..<snapshot.byteCount)
            } label: {
                Label("Add text", systemImage: "plus")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add text at the end of the document")
        }
    }

    @ViewBuilder
    private func editTarget<Content: View>(_ range: Range<Int>?, beginEdit: @escaping (Range<Int>) -> Void,
                                          @ViewBuilder content: () -> Content) -> some View {
        if let range {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .textSelection(.disabled)
                .gesture(TapGesture().onEnded { beginEdit(range) })
                .accessibilityAction(named: Text("Edit block")) { beginEdit(range) }
        } else {
            content()
        }
    }

    private func disclosureView(_ disclosure: SafeHTML.Disclosure) -> some View {
        let content = ReadingView(snapshot: MarkdownSource(text: disclosure.body).parse(), links: links, openLocal: openLocal)
        let title = ReadingView(snapshot: MarkdownSource(text: disclosure.summary).parse(), links: links, openLocal: openLocal)
        return ReaderDisclosure(isOpen: disclosure.isOpen) {
            VStack(alignment: .leading, spacing: 10) {
                content.blocks(Array(content.snapshot.document.children))
                if !content.footnotes.notes.isEmpty { content.footnoteSection }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14)
        } label: {
            if let paragraph = title.snapshot.document.child(at: 0) as? Paragraph {
                SwiftUI.Text(title.inlines(paragraph)).font(.headline)
            } else {
                SwiftUI.Text(verbatim: disclosure.summary).font(.headline)
            }
        }
    }

    private func block(_ node: any Markup) -> AnyView {
        switch node {
        case let heading as Heading:
            let id = snapshot.byteRange(of: heading).flatMap { headings[$0] } ?? ""
            let sizes: [Font] = [.largeTitle, .title, .title2, .title3, .headline, .subheadline]
            return AnyView(SwiftUI.Text(inlines(heading)).font(sizes[heading.level - 1]).bold()
                .padding(.top, heading.level <= 2 ? 6 : 2)
                .accessibilityAddTraits(.isHeader).id(Data(id.utf8)))
        case let paragraph as Paragraph:
            if let raw = snapshot.source(of: paragraph), let anchor = SafeHTML.anchor(raw) {
                return AnyView(anchorTarget(anchor))
            }
            if paragraph.childCount == 1, let link = paragraph.child(at: 0) as? Markdown.Link,
               let address = link.destination, let video = GitHubVideo.attachment(address) {
                return AnyView(GitHubVideoView(url: video))
            }
            if let source = snapshot.source(of: paragraph),
               let video = GitHubVideo.attachment(source.trimmingCharacters(in: .whitespacesAndNewlines))
                    ?? GitHubVideo.fromHTML(source) {
                return AnyView(GitHubVideoView(url: video))
            }
            if let source = snapshot.source(of: paragraph), let math = GitHubMath.display(source) {
                return AnyView(RichBlockView(input: .math(math, inline: false), fallback: source))
            }
            if let source = snapshot.source(of: paragraph), let parts = GitHubMath.inline(source) {
                return AnyView(inlineMath(parts))
            }
            if let images = imageParagraph(paragraph) {
                return AnyView(imageRow(images))
            }
            if paragraph.childCount == 1, let link = paragraph.child(at: 0) as? Markdown.Link,
               let url = link.destination.flatMap(destination) {
                return AnyView(SwiftUI.Link(destination: url) { SwiftUI.Text(inlines(link)) })
            }
            if let parts = imageFragments(paragraph) {
                return AnyView(InlineMathLayout {
                    ForEach(parts.indices, id: \.self) { index in
                        switch parts[index] {
                        case let .text(text): SwiftUI.Text(text)
                        case let .image(image): imageView(image)
                        }
                    }
                })
            }
            if let raw = snapshot.source(of: paragraph), let image = SafeHTML.image(raw) {
                return AnyView(imageView(image))
            }
            return AnyView(SwiftUI.Text(inlines(paragraph)))
        case let quote as BlockQuote:
            if let first = quote.children.first(where: { _ in true }) as? Paragraph,
               let firstInline = first.children.first(where: { _ in true }) as? Markdown.Text,
               let alert = GitHubAlert.parse(firstInline.string),
               alert.remaining.isEmpty {
                return AnyView(alertView(alert.kind, quote: quote, first: first))
            }
            return AnyView(HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.45)).frame(width: 3)
                VStack(alignment: .leading, spacing: 8) { blocks(Array(quote.children)) }
            }.foregroundStyle(.secondary))
        case let list as OrderedList:
            return AnyView(listView(Array(list.children), start: Int(list.startIndex)))
        case let list as UnorderedList:
            return AnyView(listView(Array(list.children), start: nil))
        case let table as Markdown.Table:
            return AnyView(tableView(table))
        case let code as CodeBlock:
            guard !code.code.allSatisfy(\.isWhitespace) else { return AnyView(EmptyView()) }
            let fallback = snapshot.source(of: code) ?? code.code
            switch code.language?.lowercased() {
            case "mermaid": return AnyView(RichBlockView(input: .mermaid(code.code), fallback: fallback))
            case "math": return AnyView(RichBlockView(input: .math(code.code, inline: false), fallback: fallback))
            case "geojson": return AnyView(OfflineMapBlock(source: code.code, format: .geojson, fallback: fallback))
            case "topojson": return AnyView(OfflineMapBlock(source: code.code, format: .topojson, fallback: fallback))
            case "stl": return AnyView(ASCIIMeshBlock(source: code.code, fallback: fallback))
            default: break
            }
            return AnyView(HighlightedCodeBlock(code: code.code, language: code.language))
        case is HTMLBlock:
            let source = snapshot.source(of: node) ?? ""
            if source.wholeMatch(of: #/(?s)\s*<!--(?:(?!-->).)*-->\s*/#) != nil { return AnyView(EmptyView()) }
            if source.wholeMatch(of: #/(?i)(?:\s*<br\s*\/?>)+\s*/#) != nil {
                let lines = source.matches(of: #/(?i)<br\s*\/?>/#).count
                return AnyView(Color.clear.frame(height: CGFloat(min(lines, 8)) * 10).accessibilityHidden(true))
            }
            if let video = GitHubVideo.fromHTML(source) {
                return AnyView(GitHubVideoView(url: video))
            }
            if let figure = SafeHTML.headingImage(source) {
                return AnyView(VStack(spacing: 0) {
                    ForEach(figure.anchors, id: \.self) { anchorTarget($0) }
                    imageView(figure.image).accessibilityAddTraits(.isHeader)
                })
            }
            if let image = SafeHTML.image(source) {
                return AnyView(imageView(image))
            }
            if let text = SafeHTML.textBlock(source) {
                let id = snapshot.byteRange(of: node).flatMap { headings[$0] }
                if let id { return AnyView(htmlTextBlock(text).id(Data(id.utf8))) }
                return AnyView(htmlTextBlock(text))
            }
            if let anchor = SafeHTML.anchor(source) {
                return AnyView(anchorTarget(anchor))
            }
            return AnyView(DisclosureGroup("HTML source") {
                SwiftUI.Text(verbatim: source).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }.font(.callout).foregroundStyle(.secondary))
        case is ThematicBreak:
            return AnyView(Divider())
        default:
            return AnyView(SwiftUI.Text(verbatim: snapshot.source(of: node) ?? "").font(.system(.body, design: .monospaced)))
        }
    }

    private func anchorTarget(_ name: String) -> some View {
        Color.clear.frame(width: 0, height: 0).id(Data(name.utf8)).accessibilityHidden(true)
    }

    private func htmlTextBlock(_ block: SafeHTML.TextBlock) -> some View {
        var rendered = AttributedString()
        for run in block.runs {
            var next = AttributedString(run.text)
            var intent = InlinePresentationIntent()
            if run.styles.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if run.styles.contains(.italic) { intent.insert(.emphasized) }
            if run.styles.contains(.strike) { intent.insert(.strikethrough) }
            if !intent.isEmpty { next.inlinePresentationIntent = intent }
            if run.styles.contains(.underline) { next.underlineStyle = .single }
            if run.styles.contains(.code) { next.font = .system(.body, design: .monospaced) }
            if run.styles.contains(.superscript) || run.styles.contains(.subscriptText) {
                next.font = .caption
                next.baselineOffset = run.styles.contains(.superscript) ? 4 : -3
            }
            next.link = run.link.flatMap(destination)
            rendered += next
        }
        let level = block.headingLevel
        let text = SwiftUI.Text(rendered)
            .multilineTextAlignment(block.alignment == .center ? .center : block.alignment == .right ? .trailing : .leading)
            .frame(maxWidth: .infinity,
                   alignment: block.alignment == .center ? .center : block.alignment == .right ? .trailing : .leading)
        if let level {
            let sizes: [Font] = [.largeTitle, .title, .title2, .title3, .headline, .subheadline]
            return AnyView(text.font(sizes[level - 1]).bold().accessibilityAddTraits(.isHeader))
        }
        return AnyView(text)
    }

    private func inlineMath(_ parts: [GitHubMath.Part]) -> some View {
        let formatting = InlineMathFormatting(parts: parts)
        let fragments = formatting.fragments(in: inlineMathText(formatting.markdown)) ?? parts.map {
            switch $0 {
            case let .markdown(raw): return .text(inlineMathText(raw))
            case let .formula(source, raw): return .formula(source: source, raw: raw)
            }
        }
        return InlineMathLayout {
            ForEach(fragments.indices, id: \.self) { index in
                switch fragments[index] {
                case let .text(text):
                    SwiftUI.Text(text)
                case let .formula(source, raw):
                    RichBlockView(input: .math(source, inline: true), fallback: raw)
                }
            }
        }
    }

    private func inlineMathText(_ raw: String) -> AttributedString {
        let leading = raw.prefix(while: \.isWhitespace)
        let trimmedLeading = raw.dropFirst(leading.count)
        let trailing = trimmedLeading.reversed().prefix(while: \.isWhitespace).reversed()
        let middle = String(trimmedLeading.dropLast(trailing.count))
        let fragment = ReadingView(snapshot: MarkdownSource(text: middle).parse(), links: links, openLocal: openLocal)
        guard let paragraph = fragment.snapshot.document.child(at: 0) as? Paragraph else {
            return AttributedString(raw)
        }
        return AttributedString(String(leading)) + fragment.inlines(paragraph) + AttributedString(String(trailing))
    }

    private func imageParagraph(_ paragraph: Paragraph) -> [ReaderImage]? {
        var images: [ReaderImage] = []
        for child in paragraph.children {
            if child is SoftBreak || child is LineBreak { continue }
            if let text = child as? Markdown.Text, text.string.allSatisfy(\.isWhitespace) { continue }
            guard let image = readerImage(child) else { return nil }
            images.append(image)
        }
        return images.isEmpty ? nil : images
    }

    private enum ImageFragment {
        case text(AttributedString)
        case image(ReaderImage)
    }

    private func imageFragments(_ paragraph: Paragraph) -> [ImageFragment]? {
        var parts: [ImageFragment] = []
        var pending: [any Markup] = []
        for node in paragraph.children {
            let media = readerImage(node).map { [ImageFragment.image($0)] } ?? imageEmojiFragments(node)
            if let media {
                if !pending.isEmpty { parts.append(.text(inlines(pending))); pending = [] }
                parts.append(contentsOf: media)
            } else {
                pending.append(node)
            }
        }
        guard !parts.isEmpty else { return nil }
        if !pending.isEmpty { parts.append(.text(inlines(pending))) }
        return parts
    }

    private func imageEmojiFragments(_ node: any Markup) -> [ImageFragment]? {
        if let text = node as? Markdown.Text {
            let source = text.string
            let references = footnotes.inText(text, snapshot: snapshot)
            let emoji = GitHubImageEmoji.matches(in: source).filter { match in
                !references.contains { $0.range.overlaps(match.range) }
            }
            guard !emoji.isEmpty else { return nil }
            var result: [ImageFragment] = []
            var start = source.startIndex
            for match in emoji {
                if start < match.range.lowerBound {
                    result.append(.text(footnoteText(text, in: start..<match.range.lowerBound)))
                }
                result.append(.image(match.image))
                start = match.range.upperBound
            }
            if start < source.endIndex { result.append(.text(footnoteText(text, in: start..<source.endIndex))) }
            return result
        }

        let intent: InlinePresentationIntent
        switch node {
        case is Strong: intent = .stronglyEmphasized
        case is Emphasis: intent = .emphasized
        case is Strikethrough: intent = .strikethrough
        case is Markdown.Link: intent = []
        default: return nil
        }
        var result: [ImageFragment] = []
        var containsEmoji = false
        let address = (node as? Markdown.Link)?.destination
        for child in node.children {
            let fragments: [ImageFragment]
            if let nested = imageEmojiFragments(child) {
                containsEmoji = true
                fragments = nested
            } else {
                fragments = [.text(inlines([child]))]
            }
            for fragment in fragments {
                switch fragment {
                case var .image(image):
                    if let address { image.destination = address }
                    result.append(.image(image))
                case let .text(original):
                    var decorated = AttributedString()
                    for run in original.runs {
                        var span = AttributedString(original[run.range])
                        let styles = (run.inlinePresentationIntent ?? []).union(intent)
                        if !styles.isEmpty { span.inlinePresentationIntent = styles }
                        if let address { span.link = destination(address) }
                        decorated += span
                    }
                    result.append(.text(decorated))
                }
            }
        }
        return containsEmoji ? result : nil
    }

    private func readerImage(_ node: any Markup) -> ReaderImage? {
        if let image = node as? Markdown.Image, let source = image.source {
            return ReaderImage(source: source, alt: image.plainText)
        }
        if let link = node as? Markdown.Link, link.childCount == 1,
           let image = link.child(at: 0) as? Markdown.Image, let source = image.source {
            return ReaderImage(source: source, alt: image.plainText, destination: link.destination)
        }
        return nil
    }

    @ViewBuilder private func imageRow(_ images: [ReaderImage]) -> some View {
        if images.count == 1 {
            imageView(images[0])
        } else {
            InlineMathLayout(horizontalSpacing: 4) {
                ForEach(images.indices, id: \.self) { imageView(images[$0]) }
            }
        }
    }

    private func imageView(_ image: ReaderImage) -> some View {
        ReaderImageView(image: image, links: links, linkURL: image.destination.flatMap(destination))
    }

    private struct NoteTarget: Hashable { let id: String }

    @ViewBuilder private var footnoteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            SwiftUI.Text("Footnotes").font(.headline).accessibilityAddTraits(.isHeader)
        }
        ForEach(footnotes.notes, id: \.number) { note in
            HStack(alignment: .top, spacing: 8) {
                SwiftUI.Text("\(note.number).").monospacedDigit()
                VStack(alignment: .leading, spacing: 6) {
                    let content = ReadingView(snapshot: MarkdownSource(text: note.definition.body).parse(),
                                              links: links, openLocal: openLocal)
                    content.blocks(Array(content.snapshot.document.children))
                    HStack {
                        ForEach(note.references, id: \.occurrence) { reference in
                            if let url = noteURL(reference.returnID) {
                                SwiftUI.Link(reference.occurrence == 1 ? "↩" : "↩\(reference.occurrence)", destination: url)
                                    .accessibilityLabel("Back to footnote \(reference.number), reference \(reference.occurrence)")
                            }
                        }
                    }
                }
            }
            .id(NoteTarget(id: note.references[0].noteID))
        }
    }

    private func footnoteText(_ text: Markdown.Text, in selection: Range<String.Index>? = nil) -> AttributedString {
        let source = text.string
        let range = selection ?? source.startIndex..<source.endIndex
        var result = AttributedString()
        var start = range.lowerBound
        for reference in footnotes.inText(text, snapshot: snapshot)
            where reference.range.lowerBound >= range.lowerBound && reference.range.upperBound <= range.upperBound {
            result += AttributedString(EmojiShortcodes.replace(in: source[start..<reference.range.lowerBound]))
            var marker = AttributedString(String(reference.number))
            marker.font = .caption
            marker.link = noteURL(reference.noteID)
            result += marker
            start = reference.range.upperBound
        }
        result += AttributedString(EmojiShortcodes.replace(in: source[start..<range.upperBound]))
        return result
    }

    private func noteURL(_ id: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "glancemark-note"
        parts.fragment = id
        return parts.url
    }

    private func alertView(_ alert: GitHubAlert, quote: BlockQuote, first: Paragraph) -> some View {
        let style: (Color, String)
        switch alert {
        case .note: style = (.blue, "info.circle")
        case .tip: style = (.green, "lightbulb")
        case .important: style = (.purple, "exclamationmark.circle")
        case .warning: style = (.orange, "exclamationmark.triangle")
        case .caution: style = (.red, "exclamationmark.octagon")
        }
        let remainder = Array(first.children.dropFirst().drop(while: { $0 is SoftBreak || $0 is LineBreak }))
        return VStack(alignment: .leading, spacing: 8) {
            Label(alert.rawValue.capitalized, systemImage: style.1).foregroundStyle(style.0).font(.headline)
            if !remainder.isEmpty { SwiftUI.Text(inlines(Paragraph(remainder.compactMap { $0 as? InlineMarkup }))) }
            blocks(Array(quote.children.dropFirst()))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.0.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func listView(_ items: [any Markup], start: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let checkbox = (items[index] as? ListItem)?.checkbox {
                        Image(systemName: checkbox == .checked ? "checkmark.square" : "square")
                            .accessibilityLabel(checkbox == .checked ? "Checked" : "Unchecked")
                    } else {
                        SwiftUI.Text(start.map { "\($0 + index)." } ?? "•").monospacedDigit()
                    }
                    VStack(alignment: .leading, spacing: 6) { blocks(Array(items[index].children)) }
                }
            }
        }.padding(.leading, 8)
    }

    private func tableView(_ table: Markdown.Table) -> some View {
        let rows = [Array(table.head.children)] + table.body.children.map { Array($0.children) }
        let alignment = table.columnAlignments
        let border = Color.primary.opacity(0.16)
        let outline = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(rows[row].indices, id: \.self) { column in
                            let position = column < alignment.count ? alignment[column] : nil
                            let cellAlignment: Alignment = position == .right ? .trailing
                                : position == .center ? .center : .leading
                            SwiftUI.Text(inlines(rows[row][column]))
                                .fontWeight(row == 0 ? .semibold : .regular)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cellAlignment)
                                .overlay(alignment: .trailing) {
                                    if column < rows[row].count - 1 {
                                        Rectangle().fill(border).frame(width: 1)
                                    }
                                }
                        }
                    }
                    .background(row == 0 ? Color.primary.opacity(0.055) : Color.clear)
                    if row < rows.count - 1 {
                        Rectangle().fill(border).frame(height: 1)
                            .gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .clipShape(outline)
            .overlay { outline.strokeBorder(border, lineWidth: 1).allowsHitTesting(false) }
        }
    }

    func inlines(_ node: any Markup) -> AttributedString {
        inlines(Array(node.children))
    }

    private func inlines(_ children: [any Markup]) -> AttributedString {
        var result = AttributedString()
        var styles: [SafeHTML.InlineStyle] = []
        for child in children {
            var content: AttributedString
            switch child {
            case let text as Markdown.Text: content = footnoteText(text)
            case let code as InlineCode:
                content = AttributedString(code.code)
                content.font = .system(.body, design: .monospaced)
            case let html as InlineHTML:
                let raw = html.rawHTML
                if let tag = SafeHTML.InlineStyle.tag(raw) {
                    if tag.closes {
                        if let last = styles.lastIndex(of: tag.style) { styles.remove(at: last) }
                    } else {
                        styles.append(tag.style)
                    }
                    continue
                }
                if raw.wholeMatch(of: #/(?i)<br\s*[/]?>/#) != nil {
                    content = AttributedString("\n")
                } else {
                    content = AttributedString(raw)
                }
            case is SoftBreak: content = AttributedString(" ")
            case is LineBreak: content = AttributedString("\n")
            case is Strong:
                content = inlines(child)
                content.inlinePresentationIntent = [.stronglyEmphasized]
            case is Emphasis:
                content = inlines(child)
                content.inlinePresentationIntent = [.emphasized]
            case is Strikethrough:
                content = inlines(child)
                content.inlinePresentationIntent = [.strikethrough]
            case let link as Markdown.Link:
                content = inlines(link)
                content.link = link.destination.flatMap(destination)
            case let image as Markdown.Image:
                content = AttributedString(image.plainText)
                content.link = image.source.flatMap(destination)
            default:
                content = child.childCount == 0 ? AttributedString(snapshot.source(of: child) ?? "") : inlines(child)
            }
            for style in styles {
                switch style {
                case .underline, .u:
                    content.underlineStyle = .single
                case .strong, .b:
                    content.inlinePresentationIntent = (content.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
                case .emphasis, .i:
                    content.inlinePresentationIntent = (content.inlinePresentationIntent ?? []).union(.emphasized)
                case .strike, .deletion:
                    content.inlinePresentationIntent = (content.inlinePresentationIntent ?? []).union(.strikethrough)
                case .superscript, .subscriptText:
                    content.font = .caption
                    content.baselineOffset = style == .superscript ? 4 : -3
                }
            }
            result += content
        }
        return result
    }

    private func destination(_ reference: String) -> URL? {
        guard let links else { return nil }
        guard let resolved = links.resolve(reference) else { return links.unavailableLocalLink(reference) }
        switch resolved {
        case let .web(url): return url
        case let .local(url, fragment):
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.fragment = fragment
            return parts?.url
        case let .fragment(fragment):
            var parts = URLComponents()
            parts.scheme = "glancemark-fragment"
            parts.fragment = fragment
            return parts.url
        }
    }
}


private struct ReaderDisclosure<Content: View, Label: View>: View {
    @State var isOpen: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label

    var body: some View {
        DisclosureGroup(isExpanded: $isOpen, content: content, label: label)
    }
}


struct ReadingBlockGroup {
    enum Content {
        case disclosure(SafeHTML.Disclosure)
        case container(SafeHTML.Container)
        case markdownContainer(SafeHTML.MarkdownContainer)
        case node(any Markup)
    }

    let content: Content
    let range: Range<Int>?

    static func previews(_ groups: [Self], in active: Range<Int>, snapshot: MarkdownSnapshot) -> [Self] {
        guard !active.isEmpty else { return [] }
        return groups.filter { group in
            guard let range = group.range, active.lowerBound <= range.lowerBound,
                  range.upperBound <= active.upperBound else { return false }
            switch group.content {
            case .disclosure, .container, .markdownContainer:
                return true
            case let .node(node):
                if node is Markdown.Table { return true }
                if let code = node as? CodeBlock {
                    return ["mermaid", "math", "geojson", "topojson", "stl"].contains(code.language?.lowercased() ?? "")
                }
                if let raw = snapshot.source(of: node) {
                    if let paragraph = node as? Paragraph {
                        if paragraph.childCount == 1, let link = paragraph.child(at: 0) as? Markdown.Link,
                           let address = link.destination, GitHubVideo.attachment(address) != nil { return true }
                        return GitHubMath.display(raw) != nil || GitHubMath.inline(raw) != nil
                            || GitHubVideo.attachment(raw.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
                            || GitHubVideo.fromHTML(raw) != nil || SafeHTML.image(raw) != nil
                            || containsImage(node)
                    }
                    if node is HTMLBlock {
                        return SafeHTML.image(raw) != nil || SafeHTML.headingImage(raw) != nil || GitHubVideo.fromHTML(raw) != nil
                    }
                }
                return false
            }
        }
    }

    private static func containsImage(_ node: any Markup) -> Bool {
        node is Markdown.Image || node.children.contains(where: containsImage)
    }

    static func collect(_ nodes: [any Markup], in snapshot: MarkdownSnapshot) -> [Self] {
        var groups: [Self] = []
        var index = 0
        while index < nodes.count {
            let content: Content
            let consumed: Int
            if let disclosure = SafeHTML.disclosure(at: index, in: nodes, snapshot: snapshot) {
                content = .disclosure(disclosure)
                consumed = disclosure.consumed
            } else if let container = SafeHTML.container(at: index, in: nodes, snapshot: snapshot) {
                content = .container(container)
                consumed = container.consumed
            } else if let container = SafeHTML.markdownContainer(at: index, in: nodes, snapshot: snapshot) {
                content = .markdownContainer(container)
                consumed = container.consumed
            } else if nodes[index] is HTMLBlock, let raw = snapshot.source(of: nodes[index]),
                      SafeHTML.image(raw) == nil, SafeHTML.textBlock(raw) == nil, SafeHTML.headingImage(raw) == nil,
                      let items = SafeHTML.paragraphFragment(raw) {
                content = .container(SafeHTML.Container(items: items, consumed: 1))
                consumed = 1
            } else {
                content = .node(nodes[index])
                consumed = 1
            }
            let last = index + consumed - 1
            let range: Range<Int>?
            if let first = snapshot.byteRange(of: nodes[index]), let end = snapshot.byteRange(of: nodes[last]),
               first.lowerBound <= end.upperBound {
                range = first.lowerBound..<end.upperBound
            } else {
                range = nil
            }
            groups.append(Self(content: content, range: range))
            index += consumed
        }
        return groups
    }
}

struct EditableReadingLayout {
    enum Side: Hashable { case before, after }

    enum Item: Equatable, Identifiable {
        case block(Int)
        case fragment(Int, Side, Range<Int>)
        case footnotes
        case editor

        enum ID: Hashable {
            case block(Int)
            case fragment(Int, Side)
            case footnotes
            case editor
        }

        var id: ID {
            switch self {
            case let .block(index): return .block(index)
            case let .fragment(index, side, _): return .fragment(index, side)
            case .footnotes: return .footnotes
            case .editor: return .editor
            }
        }
    }

    let items: [Item]
    let showsTail: Bool

    init(ranges: [Range<Int>?], active: Range<Int>?, byteCount: Int) {
        guard let active, active.lowerBound >= 0, active.upperBound <= byteCount else {
            items = ranges.indices.map(Item.block) + [.footnotes]
            showsTail = true
            return
        }

        var result: [Item] = []
        var inserted = false
        for (index, range) in ranges.enumerated() {
            guard let range, range.upperBound > active.lowerBound else {
                result.append(.block(index))
                continue
            }

            if range.lowerBound >= active.upperBound {
                if !inserted {
                    result.append(.editor)
                    inserted = true
                }
                result.append(.block(index))
                continue
            }

            if range.lowerBound < active.lowerBound {
                result.append(.fragment(index, .before, range.lowerBound..<active.lowerBound))
            }
            if !inserted {
                result.append(.editor)
                inserted = true
            }
            if range.upperBound > active.upperBound {
                result.append(.fragment(index, .after, active.upperBound..<range.upperBound))
            }
        }
        result.append(.footnotes)
        if !inserted { result.append(.editor) }
        items = result
        showsTail = inserted
    }
}
