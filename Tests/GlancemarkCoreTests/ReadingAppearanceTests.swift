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

    func testLegacyAppearanceDecodesWithoutEnablingSolidQuickLook() throws {
        let legacy = Data(#"{"theme":"Dark","presets":[{"id":"0B0F882C-AB7E-4602-897E-2C319C4AE2AE","name":"Legacy","textSize":18,"width":680,"surface":"Paper"}],"selected":"0B0F882C-AB7E-4602-897E-2C319C4AE2AE"}"#.utf8)
        let appearance = try JSONDecoder().decode(ReadingAppearance.self, from: legacy)
        XCTAssertFalse(appearance.solidQuickLookBackground)
        XCTAssertEqual(appearance.theme, .dark)
        XCTAssertEqual(appearance.preset.name, "Legacy")
        XCTAssertEqual(appearance.preset.surface, .paper)
    }

    @MainActor
    func testTwoStoresShareAnAtomicPresetFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ReadingAppearance.json")
        let app = ReadingAppearanceStore(file: file, useSignedGroup: false)
        let finder = ReadingAppearanceStore(file: file, useSignedGroup: false)
        XCTAssertFalse(finder.value.solidQuickLookBackground)
        try app.update {
            $0.solidQuickLookBackground = true
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
        XCTAssertTrue(finder.value.solidQuickLookBackground)
        XCTAssertEqual(finder.value, app.value)

        try app.update { $0.solidQuickLookBackground = false }
        finder.reload()
        XCTAssertFalse(finder.value.solidQuickLookBackground)
        XCTAssertEqual(finder.value.preset.name, "Wide")
    }
}
