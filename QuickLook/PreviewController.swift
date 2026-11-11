import AppKit
import GlancemarkCore
import QuickLookUI
import SwiftUI

final class PreviewController: NSViewController, QLPreviewingController {
    private var hostingView: NSView?
    private var request = UUID()

    override func loadView() { view = NSView() }

    func preparePreviewOfFile(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        let current = UUID()
        request = current
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try MarkdownSource(bytes: Data(contentsOf: url)).parse() }
            DispatchQueue.main.async {
                guard current == self.request else { completionHandler(CancellationError()); return }
                switch result {
                case let .failure(error): completionHandler(error)
                case let .success(snapshot):
                    ReadingAppearanceStore.shared.reload()
                    let reader = FinderDocumentPreview(snapshot: snapshot, document: url)
                    let next = NSHostingView(rootView: reader)
                    self.hostingView?.removeFromSuperview()
                    self.hostingView = next
                    self.view.addSubview(next)
                    next.frame = self.view.bounds
                    next.autoresizingMask = [.width, .height]
                    completionHandler(nil)
                }
            }
        }
    }
}

private struct FinderDocumentPreview: View {
    let snapshot: MarkdownSnapshot
    let document: URL
    @State private var showHandoff = false

    var body: some View {
        let links = RepositoryLinks(document: document, allowedFolder: document.deletingLastPathComponent(),
                                    offersPreviewHandoff: true)
        VStack(spacing: 0) {
            ReadingView(snapshot: snapshot, links: links, useHostSurface: true,
                        onUnavailableLocal: offerHandoff, openLocal: openLocal)
            if showHandoff {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Finder can’t open this local link.").fontWeight(.semibold)
                        Text("Close Quick Look, then Control-click the Markdown file and choose Open With → Glancemark.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button { showHandoff = false } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
                }
                .font(.callout)
                .padding(12)
                .background(.regularMaterial)
            }
        }
    }

    private func openLocal(_ destination: URL, _: String?) {
        if !FileManager.default.isReadableFile(atPath: destination.path) || !NSWorkspace.shared.open(destination) {
            offerHandoff()
        }
    }

    private func offerHandoff() {
        showHandoff = true
    }
}
