import Foundation
import SwiftUI
import WebKit

struct HighlightedCodeBlock: View {
    let code: String
    let language: String?

    @Environment(\.colorScheme) private var colorScheme
    @State private var highlighted: Highlight?

    private var request: CodeHighlighter.Request? { .init(code: code, language: language) }

    var body: some View {
        ScrollView(.horizontal) {
            Text(content)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .task(id: request) {
            guard let request else { return }
            let tokens = await CodeHighlighter.shared.tokens(for: request)
            if let tokens, !Task.isCancelled {
                highlighted = Highlight(request: request, tokens: tokens)
            }
        }
    }

    private var content: AttributedString {
        guard let highlighted, highlighted.request == request else { return AttributedString(code) }
        return highlighted.tokens.reduce(into: AttributedString()) { output, token in
            var styled = AttributedString(token.text)
            styled.foregroundColor = color(for: token.scope)
            output += styled
        }
    }

    private func color(for scope: String) -> Color? {
        let dark = colorScheme == .dark
        switch scope {
        case "keyword", "selector-tag", "deletion", "meta":
            return dark ? Color(red: 1, green: 0.48, blue: 0.45) : Color(red: 0.69, green: 0.12, blue: 0.17)
        case "title", "section", "type", "selector-class", "selector-id":
            return dark ? Color(red: 0.82, green: 0.66, blue: 1) : Color(red: 0.40, green: 0.20, blue: 0.63)
        case "string", "regexp", "addition", "quote":
            return dark ? Color(red: 0.55, green: 0.81, blue: 1) : Color(red: 0.04, green: 0.29, blue: 0.49)
        case "number", "literal", "built_in", "attribute", "attr", "symbol", "variable", "property":
            return dark ? Color(red: 0.41, green: 0.72, blue: 1) : Color(red: 0.02, green: 0.31, blue: 0.65)
        case "comment":
            return .secondary
        default:
            return nil
        }
    }

    private struct Highlight {
        let request: CodeHighlighter.Request
        let tokens: [CodeHighlighter.Token]
    }
}

@MainActor
final class CodeHighlighter {
    static let shared = CodeHighlighter()

    struct Request: Hashable {
        let code: String
        let language: String

        init?(code: String, language: String?) {
            guard !code.isEmpty, code.utf8.count <= 32_768,
                  let info = language?.split(whereSeparator: \.isWhitespace).first else { return nil }
            var name = info.lowercased()
            if name.hasPrefix("language-") { name.removeFirst("language-".count) }
            guard !name.isEmpty, name.utf8.count <= 48,
                  name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [35, 43, 45, 46, 95].contains($0) }),
                  !["text", "plain", "plaintext", "none"].contains(name)
            else { return nil }
            let aliases = ["c++": "cpp", "c#": "csharp", "objective-c": "objectivec",
                           "objc": "objectivec", "zsh": "bash", "fish-shell": "fish",
                           "shell-session": "shell", "textile": "textile"]
            self.code = code
            self.language = aliases[name] ?? name
        }
    }

    struct Token: Equatable {
        let text: String
        let scope: String
    }

    private let page = HighlightPage()
    private var last: Task<Void, Never>?
    private var cache: [Request: [Token]] = [:]
    private var order: [Request] = []

    func tokens(for request: Request) async -> [Token]? {
        if let cached = cache[request] { return cached }
        let previous = last
        let work = Task { @MainActor () -> [Token]? in
            await previous?.value
            guard !Task.isCancelled else { return nil }
            if let cached = self.cache[request] { return cached }
            guard let result = await self.page.run(request), !Task.isCancelled else { return nil }
            self.cache[request] = result
            self.order.append(request)
            if self.order.count > 24 { self.cache.removeValue(forKey: self.order.removeFirst()) }
            return result
        }
        last = Task { _ = await work.value }
        return await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
    }
}

@MainActor
private final class HighlightPage: NSObject, WKNavigationDelegate {
    private typealias Token = CodeHighlighter.Token
    private typealias Request = CodeHighlighter.Request

    private struct Pending {
        let id = UUID()
        let request: Request
        let result: CheckedContinuation<[Token]?, Never>
    }

    private var pending: Pending?
    private var webView: WKWebView?
    private var entry: URL?
    private var ready = false
    private var timeout: Task<Void, Never>?

    func run(_ request: CodeHighlighter.Request) async -> [CodeHighlighter.Token]? {
        guard !Task.isCancelled,
              let entry = Bundle.module.url(forResource: "Highlighter", withExtension: "html", subdirectory: "Highlight")
        else { return nil }
        return await withCheckedContinuation { continuation in
            let pending = Pending(request: request, result: continuation)
            self.pending = pending
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { self?.finish(id: pending.id, tokens: nil, reset: true) }
            }
            if ready, let webView {
                highlight(pending, in: webView)
            } else {
                self.entry = entry
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .nonPersistent()
                config.preferences.javaScriptCanOpenWindowsAutomatically = false
                let browser = WKWebView(frame: .zero, configuration: config)
                self.webView = browser
                browser.navigationDelegate = self
                browser.loadFileURL(entry, allowingReadAccessTo: entry.deletingLastPathComponent())
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let initialLocalPage = !ready && navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url == entry
        decisionHandler(initialLocalPage ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let pending, self.webView === webView else { return }
        ready = true
        highlight(pending, in: webView)
    }

    private func highlight(_ pending: Pending, in webView: WKWebView) {
        webView.callAsyncJavaScript("return window.glancemarkHighlight(source, grammar);",
                                    arguments: ["source": pending.request.code, "grammar": pending.request.language],
                                    in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            if case let .success(value) = result, let raw = value as? [[String: String]], raw.count <= 32_000 {
                let tokens = raw.compactMap { item -> Token? in
                    guard let text = item["text"], let scope = item["scope"], scope.utf8.count < 48 else { return nil }
                    return Token(text: text, scope: scope)
                }
                let original = pending.request.code.utf8
                let preserved = tokens.count == raw.count && tokens.map(\.text).joined().utf8.elementsEqual(original)
                self.finish(id: pending.id, tokens: preserved ? tokens : nil)
            } else {
                self.finish(id: pending.id, tokens: nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { abort(webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { abort(webView) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { abort(webView) }

    private func abort(_ sender: WKWebView) {
        guard webView === sender else { return }
        if let pending { finish(id: pending.id, tokens: nil, reset: true) } else { resetPage() }
    }

    private func finish(id: UUID, tokens: [Token]?, reset: Bool = false) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        timeout?.cancel()
        timeout = nil
        if reset { resetPage() }
        pending.result.resume(returning: tokens)
    }

    private func resetPage() {
        ready = false
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
    }
}
