import AppKit
import WebKit

enum RichInput: Hashable {
    case mermaid(String)
    case math(String, inline: Bool)

    var source: String {
        switch self {
        case let .mermaid(source), let .math(source, _): return source
        }
    }

    var kind: String {
        switch self {
        case .mermaid: return "mermaid"
        case let .math(_, inline): return inline ? "inlineMath" : "math"
        }
    }

    var permitted: Bool {
        guard !source.isEmpty, source.utf8.count <= 32_768 else { return false }
        switch self {
        case .mermaid:
            // Front matter can change engine configuration. Directives are never interpreted.
            return !source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("---")
                && !source.contains("%%{")
        case .math:
            let controls = #/\\(?:require|href|url|class|cssId|style|htmlClass|htmlId|htmlStyle|htmlData|includegraphics)\b/#
            return source.firstMatch(of: controls) == nil
        }
    }
}

@MainActor
final class OfflineRichRenderer {
    static let shared = OfflineRichRenderer()

    private struct Key: Hashable {
        let input: RichInput
        let dark: Bool
    }

    private var queue: Task<Void, Never>?
    private var cache: [Key: NSImage] = [:]
    private var order: [Key] = []

    func render(_ input: RichInput, dark: Bool) async -> NSImage? {
        guard input.permitted else { return nil }
        let key = Key(input: input, dark: dark)
        if let image = cache[key] { return image }
        let predecessor = queue
        let work = Task { @MainActor () -> NSImage? in
            await predecessor?.value
            if let image = self.cache[key] { return image }
            let job = RichRenderJob(input: input, dark: dark)
            guard let image = await job.run() else { return nil as NSImage? }
            self.cache[key] = image
            self.order.append(key)
            if self.order.count > 16 { self.cache.removeValue(forKey: self.order.removeFirst()) }
            return image
        }
        queue = Task { _ = await work.value }
        return await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
    }
}

@MainActor
private final class RichRenderJob: NSObject, WKNavigationDelegate {
    let input: RichInput
    let dark: Bool
    private var webView: WKWebView?
    private var completion: CheckedContinuation<NSImage?, Never>?
    private var timeout: Task<Void, Never>?
    private var entry: URL?

    init(input: RichInput, dark: Bool) {
        self.input = input
        self.dark = dark
    }

    func run() async -> NSImage? {
        guard !Task.isCancelled, let url = Bundle.module.url(forResource: "Renderer", withExtension: "html", subdirectory: "Rich")
        else { return nil }
        return await withCheckedContinuation { continuation in
            entry = url
            completion = continuation
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1_280, height: 300), configuration: configuration)
            webView = view
            view.navigationDelegate = self
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { self?.finish(nil) }
            }
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url == entry
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                let result = try await webView.callAsyncJavaScript(
                    "return await window.glancemarkRender(kind, source, dark);",
                    arguments: ["kind": input.kind, "source": input.source, "dark": dark],
                    in: nil, contentWorld: .page
                )
                guard completion != nil,
                      let dimensions = result as? [String: Any],
                      let width = dimensions["width"] as? Double, let height = dimensions["height"] as? Double,
                      width > 2, height > 2, width <= 2_048 else { finish(nil); return }
                if case .math = input {
                    guard height <= 1_200, let svg = dimensions["svg"] as? String else { finish(nil); return }
                    let data = try ReaderSVG.sanitize(Data(svg.utf8))
                    finish(NSImage(data: data))
                    return
                }
                guard height <= 4_096, width * height <= 4_194_304,
                      let png = dimensions["png"] as? String, png.utf8.count <= 48_000_000,
                      let data = Data(base64Encoded: png), let bitmap = NSBitmapImageRep(data: data),
                      bitmap.hasAlpha,
                      (bitmap.pixelsWide == Int(width) && bitmap.pixelsHigh == Int(height))
                          || (bitmap.pixelsWide == Int(width) * 2 && bitmap.pixelsHigh == Int(height) * 2)
                else { finish(nil); return }
                // Keep layout in CSS points while retaining the bitmap's Retina resolution.
                let size = NSSize(width: width, height: height)
                bitmap.size = size
                let image = NSImage(size: size)
                image.addRepresentation(bitmap)
                finish(image)
            } catch {
                finish(nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(nil) }

    private func finish(_ image: NSImage?) {
        guard let completion else { return }
        self.completion = nil
        timeout?.cancel()
        timeout = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        completion.resume(returning: image)
    }
}
