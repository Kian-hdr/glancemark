import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GlancemarkCore

final class ReaderImageTests: XCTestCase {
    func testLinkedPictureSelectsThemeAndPreservesFallback() throws {
        let html = """
        <a href="./download.md">
          <picture>
            <source media="(prefers-color-scheme: dark)" srcset="./dark.png 1x, ./dark-large.png 2x">
            <source media="(prefers-color-scheme: light)" srcset="./light.png">
            <img src="./fallback.png" width="180" alt="Download">
          </picture>
        </a>
        """
        let image = try XCTUnwrap(SafeHTML.image(html))
        XCTAssertEqual(image.source(for: .dark), "./dark.png")
        XCTAssertEqual(image.source(for: .light), "./light.png")
        XCTAssertEqual(image.source, "./fallback.png")
        XCTAssertEqual(image.destination, "./download.md")
        XCTAssertEqual(image.alt, "Download")
        XCTAssertEqual(image.width, 180)
    }

    func testImageAllowlistAndModeFragments() throws {
        XCTAssertNil(SafeHTML.image("<img src='hello.png' onerror='evil()'>"))
        XCTAssertNil(SafeHTML.image("<picture><script>evil()</script><img src='hello.png'></picture>"))
        XCTAssertNil(SafeHTML.image("<img src='hello.png'> trailing text"))
        let image = try XCTUnwrap(SafeHTML.image("<img src='./dark.png#gh-dark-mode-only' alt='dark'/>"))
        XCTAssertNil(image.source(for: .light))
        XCTAssertEqual(image.source(for: .dark), "./dark.png#gh-dark-mode-only")
        XCTAssertThrowsError(try ReaderRaster.decode(Data("<svg><script>evil()</script></svg>".utf8)))
    }

    func testCenteredREADMEIconUsesSpecifiedHeight() throws {
        let markup = "<p align=\"center\">\n<img height=\"256\" src=\"https://iina.io/img/icon.png\">\n</p>"
        let snapshot = MarkdownSource(text: markup).parse()
        let node = try XCTUnwrap(snapshot.document.child(at: 0))
        let image = try XCTUnwrap(SafeHTML.image(try XCTUnwrap(snapshot.source(of: node))))
        XCTAssertTrue(image.centered)
        XCTAssertEqual(image.height, 256)
        XCTAssertEqual(image.source, "https://iina.io/img/icon.png")
    }

    func testSVGUsesSanitizedStaticMarkup() throws {
        let input = ##"<svg xmlns="http://www.w3.org/2000/svg" width="90" height="20" onload="evil()"><defs><linearGradient id="shade"><stop offset="0" stop-color="#fff"/></linearGradient></defs><rect width="90" height="20" fill="url(#shade)"/><rect width="1" height="1" fill="url(https://example.org/hidden)"/></svg>"##
        let payload = try ReaderImagePayload.decode(Data(input.utf8))
        guard case let .vector(data) = payload else { return XCTFail("Expected sanitized SVG") }
        let markup = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(markup.contains("url(#shade)"))
        XCTAssertFalse(markup.contains("onload"))
        XCTAssertFalse(markup.contains("example.org"))
        XCTAssertEqual(NSImage(data: data)?.size.width, 90)
        XCTAssertThrowsError(try ReaderImagePayload.decode(Data("<svg><script>evil()</script></svg>".utf8)))
        XCTAssertThrowsError(try ReaderImagePayload.decode(Data("<!DOCTYPE svg SYSTEM 'https://example.org/x'><svg/>".utf8)))
    }

    func testSVG11DeclarationAndStaticPaintAreRebuiltSafely() throws {
        let input = """
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
        <svg width="100%" height="100%" viewBox="0 0 20 12" xmlns="http://www.w3.org/2000/svg">
        <rect width="20" height="12" style="fill:rgb(255,54,112);cursor:url(https://example.org/hidden)"/>
        </svg>
        """
        let safe = try ReaderSVG.sanitize(Data(input.utf8))
        let markup = String(decoding: safe, as: UTF8.self)
        XCTAssertTrue(markup.contains("fill=\"rgb(255,54,112)\""))
        XCTAssertFalse(markup.contains("DOCTYPE"))
        XCTAssertFalse(markup.contains("example.org"))
        XCTAssertEqual(NSImage(data: safe)?.size, NSSize(width: 20, height: 12))
    }

    func testSVGAllowsOnlyOneSanitizedEmbeddedVector() throws {
        let nested = #"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" onload="evil()"><rect width="10" height="10"/></svg>"#
        let encoded = Data(nested.utf8).base64EncodedString()
        let image = #"<svg xmlns="http://www.w3.org/2000/svg" width="30" height="15"><image width="10" height="10" href="data:image/svg+xml;base64,\#(encoded)"/></svg>"#
        let safe = try ReaderSVG.sanitize(Data(image.utf8))
        let xml = String(decoding: safe, as: UTF8.self)
        let embedded = try XCTUnwrap(xml.firstMatch(of: #/data:image\/svg\+xml;base64,([A-Za-z0-9+/=]+)/#))
        let bytes = try XCTUnwrap(Data(base64Encoded: String(embedded.1)))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("onload"))
        XCTAssertNotNil(NSImage(data: safe))
        let recursive = image.replacingOccurrences(of: encoded, with: Data(image.utf8).base64EncodedString())
        XCTAssertThrowsError(try ReaderSVG.sanitize(Data(recursive.utf8)))
        let remote = image.replacingOccurrences(of: "data:image/svg+xml;base64," + encoded, with: "https://example.com/evil.svg")
        XCTAssertThrowsError(try ReaderSVG.sanitize(Data(remote.utf8)))
    }

    func testGIFUsesMultipleFramesAndTheirDelays() throws {
        let bytes = NSMutableData()
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.gif.identifier as CFString, 2, nil))
        for (red, delay) in [(1.0, 0.1), (0.0, 0.2)] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                                                bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(red: red, green: 0, blue: 1 - red, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            let bitmap = try XCTUnwrap(context.makeImage())
            CGImageDestinationAddImage(encoder, bitmap, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        let result = try ReaderRaster.decode(bytes as Data)
        XCTAssertEqual(result.frames.count, 2)
        XCTAssertEqual(result.durations[0], 0.1, accuracy: 0.01)
        XCTAssertEqual(result.durations[1], 0.2, accuracy: 0.01)
        XCTAssertTrue(result.frame(at: 0.15) === result.frames[1])
    }
}
