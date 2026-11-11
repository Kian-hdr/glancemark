import Foundation
import XCTest
@testable import GlancemarkCore

final class ReadingAppearanceTests: XCTestCase {
    func testHostMaterialRequiresMatchingAppearanceAndTransparency() {
        var appearance = ReadingAppearance()
        XCTAssertTrue(appearance.allowsHostMaterial(in: .dark, reduceTransparency: false))
        XCTAssertTrue(appearance.allowsHostMaterial(in: .light, reduceTransparency: false))

        appearance.theme = .light
        XCTAssertFalse(appearance.allowsHostMaterial(in: .dark, reduceTransparency: false))
        XCTAssertTrue(appearance.allowsHostMaterial(in: .light, reduceTransparency: false))
        XCTAssertFalse(appearance.allowsHostMaterial(in: .light, reduceTransparency: true))

        appearance.theme = .dark
        XCTAssertFalse(appearance.allowsHostMaterial(in: .light, reduceTransparency: false))
        XCTAssertTrue(appearance.allowsHostMaterial(in: .dark, reduceTransparency: false))
    }

    @MainActor
    func testTwoStoresShareAnAtomicPresetFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ReadingAppearance.json")
        let app = ReadingAppearanceStore(file: file, useSignedGroup: false)
        let finder = ReadingAppearanceStore(file: file, useSignedGroup: false)
        try app.update {
            $0.theme = .dark
            let preset = ReadingAppearance.Preset(name: "Wide", textSize: 21, width: 1_500, surface: .paper)
            $0.presets.append(preset)
            $0.selected = preset.id
        }
        finder.reload()
        XCTAssertEqual(finder.value.theme, .dark)
        XCTAssertEqual(finder.value.preset.name, "Wide")
        XCTAssertEqual(finder.value.preset.textSize, 21)
        XCTAssertEqual(finder.value.preset.width, 1_200)
        XCTAssertEqual(finder.value.preset.surface, .paper)
        XCTAssertEqual(finder.value, app.value)
    }
}
