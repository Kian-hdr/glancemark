import AVFoundation
import AVKit
import Foundation
import SwiftUI

enum GitHubVideo {
    static func attachment(_ raw: String) -> URL? {
        guard let url = URL(string: raw), ReaderHTTPS.host(of: url) == "github.com",
              url.query == nil, url.fragment == nil,
              url.path.wholeMatch(of: #/\/user-attachments\/assets\/[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}/#) != nil
        else { return nil }
        return url
    }

    static func fromHTML(_ raw: String) -> URL? {
        let html = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let video = html.wholeMatch(of: #/(?i)<video\s+src\s*=\s*(?:"([^"]+)"|'([^']+)')(?:\s+controls(?:\s*=\s*(?:"controls"|'controls'))?)?\s*>\s*<\/video\s*>/#),
              let source = video.1 ?? video.2 else { return nil }
        return attachment(String(source))
    }

    static func permits(_ url: URL) -> Bool {
        if attachment(url.absoluteString) != nil { return true }
        guard let host = ReaderHTTPS.host(of: url), !url.path.isEmpty else { return false }
        switch host {
        case "github-production-user-asset-6210df.s3.amazonaws.com":
            return true
        case "objects.githubusercontent.com", "github.com", "user-images.githubusercontent.com":
            return host != "github.com" && url.path.hasPrefix("/github-production-user-asset-")
        default:
            return false
        }
    }

    static func fileExtension(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        if data[4..<8].elementsEqual("ftyp".utf8) {
            return data[8..<12].elementsEqual("qt  ".utf8) ? "mov" : "mp4"
        }
        if data.prefix(4).elementsEqual([0x1a, 0x45, 0xdf, 0xa3]) { return "webm" }
        return nil
    }

    private static let worker: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Glancemark attachment download"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    static func download(_ url: URL, inFinder: Bool = false) async -> URL? {
        guard attachment(url.absoluteString) != nil else { return nil }
        let maximum = 100 * 1024 * 1024
        if inFinder {
            guard let bytes = await FinderPublicMediaTransport.load(url, maximum: maximum,
                                                                   timeout: 45, permits: { permits($0) }) else { return nil }
            return try? save(bytes)
        }
        return await withCheckedContinuation { continuation in
            worker.addOperation {
                let destination = try? save(ReaderHTTPS.fetch(url, limit: maximum, timeout: 45_000, permits: permits))
                continuation.resume(returning: destination)
            }
        }
    }

    private static func save(_ bytes: Data) throws -> URL? {
        guard let suffix = fileExtension(bytes) else { return nil }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlancemarkAttachment-\(UUID().uuidString)")
            .appendingPathExtension(suffix)
        try bytes.write(to: destination, options: .atomic)
        return destination
    }
}

struct GitHubVideoView: View {
    let url: URL
    @Environment(\.isFinderPreview) private var isFinderPreview
    @State private var player: AVPlayer?
    @State private var file: URL?
    @State private var loading: Task<Void, Never>?
    @State private var failed = false
    @State private var generation = UUID()
    @State private var playerStatus: NSKeyValueObservation?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let player {
                NativeVideoPlayer(player: player)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(minHeight: 180)
            } else if loading != nil {
                ProgressView("Loading GitHub video…")
            } else if failed {
                Label("Video unavailable", systemImage: "video.slash").foregroundStyle(.secondary)
                if isFinderPreview {
                    Text("To try inline playback in the app, use Open With → Glancemark in Finder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(action: play) { Label("Play GitHub video", systemImage: "play.circle") }
            }
            SwiftUI.Link("Open attachment on GitHub", destination: url).font(.caption)
        }
        .onDisappear(perform: clear)
        .onChange(of: url) { _, _ in clear() }
    }

    private func play() {
        let request = UUID()
        generation = request
        loading = Task { @MainActor in
            let downloaded = await GitHubVideo.download(url, inFinder: isFinderPreview)
            guard !Task.isCancelled, generation == request else { delete(downloaded); return }
            guard let downloaded else { loading = nil; failed = true; return }
            let asset = AVURLAsset(url: downloaded)
            do {
                guard try await asset.load(.isPlayable),
                      !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                    delete(downloaded)
                    if generation == request { loading = nil; failed = true }
                    return
                }
                guard !Task.isCancelled, generation == request else { delete(downloaded); return }
                file = downloaded
                let item = AVPlayerItem(asset: asset)
                let next = AVPlayer(playerItem: item)
                playerStatus = item.observe(\.status, options: [.initial, .new]) { item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor in
                        if generation == request { clear(); failed = true }
                    }
                }
                player = next
                loading = nil
                next.play()
            } catch {
                delete(downloaded)
                if generation == request { loading = nil; failed = true }
            }
        }
    }

    private func clear() {
        generation = UUID()
        loading?.cancel()
        loading = nil
        playerStatus = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        delete(file)
        file = nil
        failed = false
    }

    private func delete(_ url: URL?) {
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}

private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsSharingServiceButton = false
        view.showsFullScreenToggleButton = false
        view.updatesNowPlayingInfoCenter = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}
