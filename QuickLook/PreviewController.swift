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
            let result = Result { try PreviewPage.read(from: url) }
            DispatchQueue.main.async {
                guard current == self.request else { completionHandler(CancellationError()); return }
                switch result {
                case let .failure(error): completionHandler(error)
                case let .success(page):
                    ReadingAppearanceStore.shared.reload()
                    self.show(page)
                    completionHandler(nil)
                }
            }
        }
    }

    private func show(_ page: PreviewPage) {
        let next = NSHostingView(rootView: FinderDocumentPreview(root: page))
        hostingView?.removeFromSuperview()
        hostingView = next
        next.frame = view.bounds
        next.autoresizingMask = [.width, .height]
        view.addSubview(next)
    }
}
