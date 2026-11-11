import Foundation
import SwiftUI

private struct FinderPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isFinderPreview: Bool {
        get { self[FinderPreviewKey.self] }
        set { self[FinderPreviewKey.self] = newValue }
    }
}

/// Quick Look may deny direct DNS socket access. Its system URL loading path is
/// restricted to fixed public image services, including every redirect.
enum FinderImageTransport {
    private static let services: Set<String> = [
        "img.shields.io", "raw.githubusercontent.com", "user-images.githubusercontent.com",
        "github.githubassets.com", "avatars.githubusercontent.com", "camo.githubusercontent.com"
    ]

    static func permits(_ url: URL) -> Bool {
        guard let host = ReaderHTTPS.host(of: url) else { return false }
        return services.contains(host)
    }

    static func load(_ url: URL) async -> ReaderImagePayload? {
        guard let bytes = await FinderPublicMediaTransport.load(url, maximum: 8 * 1024 * 1024,
                                                               timeout: 12, permits: { permits($0) }) else { return nil }
        return try? ReaderImagePayload.decode(bytes)
    }
}

enum FinderPublicMediaTransport {
    static func load(_ url: URL, maximum: Int, timeout: TimeInterval,
                     permits: @escaping @Sendable (URL) -> Bool) async -> Data? {
        guard permits(url) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (stream, response) = try await session.bytes(for: URLRequest(url: url), delegate: PublicMediaRedirects(permits: permits))
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  let final = response.url, permits(final), response.expectedContentLength <= maximum
            else { return nil }
            var bytes = Data()
            if response.expectedContentLength > 0 { bytes.reserveCapacity(Int(response.expectedContentLength)) }
            for try await byte in stream {
                guard !Task.isCancelled, bytes.count < maximum else { return nil }
                bytes.append(byte)
            }
            return bytes
        } catch {
            return nil
        }
    }
}

private final class PublicMediaRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var redirects = 0
    private let permits: @Sendable (URL) -> Bool

    init(permits: @escaping @Sendable (URL) -> Bool) {
        self.permits = permits
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 3, let url = request.url, permits(url) else {
            completionHandler(nil)
            return
        }
        // Rebuild the request instead of forwarding headers to a different origin.
        completionHandler(URLRequest(url: url))
    }
}
