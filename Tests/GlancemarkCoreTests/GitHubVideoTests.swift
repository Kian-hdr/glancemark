import AVFoundation
import Foundation
import XCTest
@testable import GlancemarkCore

final class GitHubVideoTests: XCTestCase {
    func testPublicAttachmentAndStrictHTMLRoute() throws {
        let source = "https://github.com/user-attachments/assets/031799d1-740d-4cda-90cf-689513fa9860"
        let url = try XCTUnwrap(GitHubVideo.attachment(source))
        XCTAssertEqual(GitHubVideo.fromHTML("<video src=\"\(source)\" controls></video>"), url)
        XCTAssertNil(GitHubVideo.fromHTML("<video src=\"\(source)\" autoplay></video>"))
        XCTAssertNil(GitHubVideo.attachment(source + "?token=other"))
        XCTAssertFalse(GitHubVideo.permits(try XCTUnwrap(URL(string: "https://github.com/redirect"))))
        XCTAssertFalse(GitHubVideo.permits(try XCTUnwrap(URL(string: "https://github.com.example.com/video.mp4"))))
        XCTAssertTrue(GitHubVideo.permits(try XCTUnwrap(URL(string: "https://github-production-user-asset-6210df.s3.amazonaws.com/demo.mp4"))))
    }

    func testPublicAttachmentDecodesWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["GLANCEMARK_VIDEO_TEST"] == "1" else {
            throw XCTSkip("Enable GLANCEMARK_VIDEO_TEST for the public GitHub video smoke test.")
        }
        let source = try XCTUnwrap(GitHubVideo.attachment("https://github.com/user-attachments/assets/031799d1-740d-4cda-90cf-689513fa9860"))
        for inFinder in [false, true] {
            let downloaded = await GitHubVideo.download(source, inFinder: inFinder)
            let file = try XCTUnwrap(downloaded, "GitHub attachment did not download (Finder transport: \(inFinder))")
            defer { try? FileManager.default.removeItem(at: file) }
            let asset = AVURLAsset(url: file)
            let playable = try await asset.load(.isPlayable)
            let video = try await asset.loadTracks(withMediaType: .video)
            XCTAssertTrue(playable)
            XCTAssertFalse(video.isEmpty)
        }
    }

    func testVideoContainerSignaturesExcludePlaylistsAndHTML() {
        XCTAssertEqual(GitHubVideo.fileExtension(Data([0, 0, 0, 20] + Array("ftypisom".utf8))), "mp4")
        XCTAssertEqual(GitHubVideo.fileExtension(Data([0, 0, 0, 20] + Array("ftypqt  ".utf8))), "mov")
        XCTAssertNil(GitHubVideo.fileExtension(Data("#EXTM3U\nhttps://example.com/video".utf8)))
        XCTAssertNil(GitHubVideo.fileExtension(Data("<html>Not a video</html>".utf8)))
    }
}
