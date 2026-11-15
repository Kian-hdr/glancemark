import AppKit
import GlancemarkCore
import Observation

struct PreviewPage: Identifiable {
    let id = UUID()
    let snapshot: MarkdownSnapshot
    let document: URL
    var fragment: String?

    static func read(from document: URL, fragment: String? = nil) throws -> Self {
        let snapshot = try MarkdownSource(bytes: Data(contentsOf: document)).parse()
        return Self(snapshot: snapshot, document: document, fragment: fragment)
    }
}

@MainActor
@Observable
final class PreviewNavigation {
    private let root: PreviewPage
    private var history: [PreviewPage] = []
    private var folder: PreviewFolderAccess?
    private var pendingLink: PreviewMarkdownLink?
    @ObservationIgnored private var load: Task<Void, Never>?

    private(set) var showsAccessHandoff = false
    private(set) var isChoosingFolder = false

    var page: PreviewPage { history.last ?? root }
    var canGoBack: Bool { !history.isEmpty }

    var links: RepositoryLinks {
        let document = page.document
        return RepositoryLinks(document: document, allowedFolder: folder?.url ?? document.deletingLastPathComponent(),
                               wikiRoot: folder?.url ?? RepositoryLinks.nearestWikiRoot(for: document),
                               offersPreviewHandoff: true)
    }

    init(root: PreviewPage) { self.root = root }

    func goBack() {
        guard canGoBack else { return }
        cancelLoad()
        history.removeLast()
        dismissFolderAccess()
    }

    func openMarkdownLink(_ link: PreviewMarkdownLink) {
        cancelLoad()
        pendingLink = link
        showsAccessHandoff = false
        switch link.resolve(in: links) {
        case let .local(url, fragment):
            openLocal(url, fragment)
        case let .fragment(fragment):
            focus(fragment)
        default:
            offerFolderAccess()
        }
    }

    func openLocal(_ url: URL, _ fragment: String?) {
        cancelLoad()
        let destination = URL(fileURLWithPath: url.path)
        guard ["md", "markdown"].contains(destination.pathExtension.lowercased()) else {
            if FileManager.default.isReadableFile(atPath: destination.path) {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } else {
                offerFolderAccess()
            }
            return
        }

        let access = folder
        load = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                // Keep the chosen folder readable even if the host replaces this preview mid-read.
                withExtendedLifetime(access) {
                    Result { try PreviewPage.read(from: destination, fragment: fragment) }
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            switch result {
            case let .success(page):
                self.dismissFolderAccess()
                self.history.append(page)
            case .failure:
                self.offerFolderAccess()
            }
        }
    }

    func chooseFolder() {
        guard !isChoosingFolder else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = root.document.deletingLastPathComponent()
        panel.prompt = "Allow Read Access"
        panel.message = "Choose the folder that contains both notes to continue in this preview."
        isChoosingFolder = true
        panel.begin { [weak self] response in
            guard let self else { return }
            self.isChoosingFolder = false
            guard response == .OK, let url = panel.url else { return }
            let selection = PreviewFolderAccess(url)
            guard selection.contains(self.root.document) else { return }
            self.folder = selection
            self.showsAccessHandoff = false
            if let link = self.pendingLink { self.openMarkdownLink(link) }
        }
    }

    func offerFolderAccess() {
        showsAccessHandoff = true
        if pendingLink != nil, folder == nil { chooseFolder() }
    }

    func dismissFolderAccess() {
        showsAccessHandoff = false
        pendingLink = nil
    }

    func cancelLoad() {
        load?.cancel()
        load = nil
    }

    private func focus(_ fragment: String) {
        pendingLink = nil
        let focusedPage = PreviewPage(snapshot: page.snapshot, document: page.document, fragment: fragment)
        if history.isEmpty {
            history.append(focusedPage)
        } else {
            history[history.count - 1] = focusedPage
        }
    }
}

private final class PreviewFolderAccess {
    let url: URL
    private let started: Bool

    init(_ url: URL) {
        self.url = url
        started = url.startAccessingSecurityScopedResource()
    }

    deinit { if started { url.stopAccessingSecurityScopedResource() } }

    func contains(_ document: URL) -> Bool {
        RepositoryLinks(document: document, allowedFolder: url, wikiRoot: url).wikiRoot != nil
    }
}
