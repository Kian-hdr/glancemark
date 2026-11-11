import CReaderHTTPS
import Foundation
import XCTest
@testable import GlancemarkCore

final class ReaderHTTPSTests: XCTestCase {
    func testOnlyCredentialFreeHTTPSURLsWithDNSHostsAreAccepted() throws {
        let valid = try XCTUnwrap(URL(string: "https://img.shields.io/badge/demo.svg"))
        XCTAssertEqual(ReaderHTTPS.host(of: valid), "img.shields.io")
        for raw in ["http://example.com/x", "https://example.com:8080/x", "https://user@example.com/x",
                    "https://127.0.0.1/x", "https://0x7f000001/x", "https://[::1]/x", "https://server.local/x"] {
            XCTAssertNil(ReaderHTTPS.host(of: try XCTUnwrap(URL(string: raw))), raw)
        }
    }

    func testAddressPolicyRejectsSpecialUseIPv4AndIPv6() {
        for address in ["127.0.0.1", "10.1.2.3", "169.254.169.254", "100.64.0.1", "192.168.1.1",
                        "172.16.0.1", "198.18.0.1", "224.0.0.1", "::1", "::ffff:127.0.0.1",
                        "fe80::1", "fc00::1", "2002:7f00:1::1", "2001:db8::1"] {
            XCTAssertEqual(glancemark_is_public_address(address), 0, address)
        }
        XCTAssertEqual(glancemark_is_public_address("8.8.8.8"), 1)
        XCTAssertEqual(glancemark_is_public_address("2606:4700::1111"), 1)
    }

    func testPublicBadgeFetchWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["GLANCEMARK_NETWORK_TEST"] == "1" else {
            throw XCTSkip("Enable GLANCEMARK_NETWORK_TEST for the public HTTPS smoke test.")
        }
        let url = try XCTUnwrap(URL(string: "https://img.shields.io/badge/test-passing-green.svg"))
        let payload = await ReaderHTTPS.load(url)
        guard case let .vector(data)? = payload else { return XCTFail("Expected a decoded SVG badge") }
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("passing"))
    }
}
