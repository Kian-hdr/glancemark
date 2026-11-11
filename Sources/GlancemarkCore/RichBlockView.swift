import SwiftUI

struct RichBlockView: View {
    let input: RichInput
    let fallback: String

    @Environment(\.colorScheme) private var scheme
    @State private var image: NSImage?
    @State private var displayedInput: RichInput?
    @State private var displayedDark = false

    private var inline: Bool { input.kind == "inlineMath" }
    private var isDiagram: Bool { input.kind == "mermaid" }

    var body: some View {
        let dark = scheme == .dark
        Group {
            if let image, displayedInput == input, displayedDark == dark {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(idealWidth: image.size.width, maxWidth: image.size.width,
                           idealHeight: image.size.height)
                    .padding(.vertical, isDiagram ? 4 : 0)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        input.kind == "inlineMath" ? dimensions.height * 0.74 : dimensions.height
                    }
                    .accessibilityLabel(input.kind == "mermaid" ? "Mermaid diagram" : input.source)
            } else if inline {
                Text(verbatim: fallback)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            } else if displayedInput == input && displayedDark == dark {
                DisclosureGroup(isDiagram ? "Mermaid source" : "Equation source") {
                    Text(verbatim: fallback)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                ProgressView(isDiagram ? "Rendering diagram…" : "Rendering equation…")
                    .controlSize(.small)
                    .font(.callout)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: inline ? nil : .infinity, alignment: .center)
        .task(id: RenderKey(input: input, dark: dark)) {
            let result = await OfflineRichRenderer.shared.render(input, dark: dark)
            guard !Task.isCancelled else { return }
            image = result
            displayedInput = input
            displayedDark = dark
        }
    }

    private struct RenderKey: Hashable {
        let input: RichInput
        let dark: Bool
    }
}
