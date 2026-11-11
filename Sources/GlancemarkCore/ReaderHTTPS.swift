import CReaderHTTPS
import Foundation

enum ReaderHTTPS {
    private static let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Glancemark image requests"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    static func load(_ url: URL) async -> ReaderImagePayload? {
        await withCheckedContinuation { continuation in
            workers.addOperation {
                let result = try? ReaderImagePayload.decode(fetch(url, limit: 16 * 1024 * 1024, timeout: 9_000))
                continuation.resume(returning: result)
            }
        }
    }

    static func host(of url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), host.utf8.count <= 253,
              host.wholeMatch(of: #/[a-z0-9-]+(?:\.[a-z0-9-]+)+/#) != nil,
              host.split(separator: ".").last?.first?.isLetter == true,
              !host.hasSuffix(".local") && !host.hasSuffix(".localhost")
        else { return nil }
        return host
    }

    static func fetch(_ initial: URL, limit: Int, timeout: Int,
                      permits: (URL) -> Bool = { _ in true }) throws -> Data {
        var url = initial
        for _ in 0..<4 {
            guard permits(url), let host = host(of: url) else { throw ReaderRaster.InvalidImage() }
            var response = GlancemarkHTTPResponse()
            guard glancemark_fetch_https(url.absoluteString, host, limit, timeout, &response) == 1
            else { throw ReaderRaster.InvalidImage() }
            defer { glancemark_free_response(&response) }
            if (300..<400).contains(response.status), let redirect = response.redirect,
               let next = URL(string: String(cString: redirect)) {
                url = next
                continue
            }
            guard (200..<300).contains(response.status), response.length > 0, let data = response.bytes
            else { throw ReaderRaster.InvalidImage() }
            return Data(bytes: data, count: response.length)
        }
        throw ReaderRaster.InvalidImage()
    }
}
