import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ReaderImage: Equatable {
    enum Theme { case light, dark }

    var source: String
    var alt: String
    var destination: String?
    var width: Double?
    var height: Double?
    var centered = false
    var variants: [Theme: String] = [:]

    func source(for theme: Theme) -> String? {
        let selected = variants[theme] ?? source
        let fragment = URLComponents(string: selected)?.fragment
        if (fragment == "gh-dark-mode-only" && theme == .light)
            || (fragment == "gh-light-mode-only" && theme == .dark) { return nil }
        return selected
    }
}

struct ReaderRaster: @unchecked Sendable {
    let frames: [CGImage]
    let durations: [Double]

    static func loadBytes(_ url: URL) throws -> Data {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard url.isFileURL, info.isRegularFile == true, let size = info.fileSize,
              size > 0, size <= 16 * 1024 * 1024 else { throw InvalidImage() }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        return bytes
    }

    static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= 16 * 1024 * 1024,
              let image = CGImageSourceCreateWithData(bytes as CFData, nil),
              let identifier = CGImageSourceGetType(image) as String?,
              let type = UTType(identifier),
              type.conforms(to: .image), !type.conforms(to: .svg)
        else { throw InvalidImage() }
        let count = CGImageSourceGetCount(image)
        guard count > 0 else { throw InvalidImage() }
        let animated = type.conforms(to: .gif) && count <= 180
        var frames: [CGImage] = []
        var durations: [Double] = []
        var pixels = 0
        for i in 0..<(animated ? count : 1) {
            let properties = CGImageSourceCopyPropertiesAtIndex(image, i, nil) as? [CFString: Any] ?? [:]
            guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 16_384, height <= 16_384,
                  width * height <= 64_000_000 else { throw InvalidImage() }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_600,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let frame = CGImageSourceCreateThumbnailAtIndex(image, i, options as CFDictionary) else {
                throw InvalidImage()
            }
            pixels += frame.width * frame.height
            if pixels > 16_000_000, !frames.isEmpty { return Self(frames: [frames[0]], durations: []) }
            frames.append(frame)
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
            durations.append(max(0.02, delay.isFinite ? delay : 0.1))
        }
        return Self(frames: frames, durations: durations)
    }

    func frame(at elapsed: TimeInterval) -> CGImage {
        let duration = durations.reduce(0, +)
        guard frames.count > 1, duration > 0 else { return frames[0] }
        var phase = elapsed.truncatingRemainder(dividingBy: duration)
        for (index, delay) in durations.enumerated() {
            if phase < delay { return frames[index] }
            phase -= delay
        }
        return frames[0]
    }

    struct InvalidImage: Error {}
}

enum ReaderImagePayload: Sendable {
    case raster(ReaderRaster)
    case vector(Data)

    static func load(_ url: URL) throws -> Self {
        try decode(ReaderRaster.loadBytes(url))
    }

    static func decode(_ bytes: Data) throws -> Self {
        let utf8 = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? bytes.dropFirst(3) : bytes[...]
        if utf8.first(where: { ![9, 10, 13, 32].contains($0) }) == 60 {
            return .vector(try ReaderSVG.sanitize(bytes))
        }
        return .raster(try ReaderRaster.decode(bytes))
    }
}

struct ReaderImageView: View {
    private struct LoadKey: Hashable {
        let reference: String
        let location: URL?
        let document: URL?
    }

    var image: ReaderImage
    var links: RepositoryLinks?
    var linkURL: URL?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isFinderPreview) private var finderAccess
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var payload: ReaderImagePayload?
    @State private var vector: NSImage?
    @State private var rasterSource: URL?
    @State private var start = Date()

    var body: some View {
        let source = image.source(for: colorScheme == .dark ? .dark : .light)
        if let source {
            let location = imageURL(source)
            Group {
                if let linkURL {
                    SwiftUI.Link(destination: linkURL) { content(for: location) }
                } else {
                    content(for: location)
                }
            }
            .frame(maxWidth: image.centered ? .infinity : nil)
            .task(id: LoadKey(reference: source, location: location, document: links?.document)) {
                payload = nil
                vector = nil
                rasterSource = nil
                var value: ReaderImagePayload?
                if let location {
                    if location.isFileURL {
                        value = await Task.detached(priority: .utility) { try? ReaderImagePayload.load(location) }.value
                    } else {
                        value = finderAccess ? await FinderImageTransport.load(location) : await ReaderHTTPS.load(location)
                    }
                }
                if value == nil, finderAccess, let document = links?.document {
                    value = await Task.detached(priority: .utility) {
                        FinderImageCache.load(document: document, reference: source, legacyAsset: location)
                    }.value
                }
                guard !Task.isCancelled else { return }
                payload = value
                if case let .vector(sanitized)? = value,
                   let picture = NSImage(data: sanitized),
                   picture.size.width.isFinite, picture.size.height.isFinite,
                   picture.size.width > 0, picture.size.width <= 16_384,
                   picture.size.height > 0, picture.size.height <= 16_384 {
                    vector = picture
                }
                rasterSource = location
                start = Date()
            }
        }
    }

    @ViewBuilder private func content(for location: URL?) -> some View {
        if let vector, rasterSource == location {
            Image(nsImage: vector)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(idealWidth: displayWidth(width: vector.size.width, height: vector.size.height),
                       maxWidth: displayWidth(width: vector.size.width, height: vector.size.height))
                .accessibilityLabel(image.alt.isEmpty ? "Image" : image.alt)
        } else if case let .raster(raster)? = payload, rasterSource == location {
            if raster.frames.count > 1 && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    frame(raster.frame(at: context.date.timeIntervalSince(start)))
                }
            } else {
                frame(raster.frames[0])
            }
        } else {
            Label(image.alt.isEmpty ? "Image unavailable" : image.alt, systemImage: "photo")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    private func frame(_ bitmap: CGImage) -> some View {
        Image(decorative: bitmap, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(idealWidth: displayWidth(width: Double(bitmap.width), height: Double(bitmap.height)),
                   maxWidth: displayWidth(width: Double(bitmap.width), height: Double(bitmap.height)))
            .accessibilityLabel(image.alt.isEmpty ? "Image" : image.alt)
    }

    private func displayWidth(width: Double, height: Double) -> Double {
        min(image.width ?? image.height.map { width * $0 / height } ?? width, 1_600)
    }

    private func imageURL(_ reference: String) -> URL? {
        switch links?.resolve(reference) {
        case let .local(url, _): return url
        case let .web(url): return ReaderHTTPS.host(of: url) == nil ? nil : url
        default: return nil
        }
    }
}
