import Foundation
import SwiftUI

public struct ReadingAppearance: Codable, Equatable {
    public enum Theme: String, CaseIterable, Codable, Identifiable {
        case system = "System", light = "Light", dark = "Dark"
        public var id: Self { self }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    public enum Surface: String, CaseIterable, Codable, Identifiable {
        case window = "Window", paper = "Paper", translucent = "Translucent"
        public var id: Self { self }
    }

    public struct Preset: Codable, Equatable, Identifiable {
        public var id: UUID = UUID()
        public var name: String
        public var textSize: Double
        public var width: Double
        public var surface: Surface

        public init(name: String, textSize: Double = 15, width: Double = 760, surface: Surface = .window) {
            self.name = name
            self.textSize = textSize
            self.width = width
            self.surface = surface
        }
    }

    public var theme = Theme.system
    public var presets: [Preset] = [
        Preset(name: "Standard"),
        Preset(name: "Compact", textSize: 13, width: 640)
    ]
    public var selected: UUID?

    public init() {}

    public var preset: Preset {
        presets.first { $0.id == selected } ?? presets.first ?? Preset(name: "Standard")
    }

    func allowsHostMaterial(in host: ColorScheme, reduceTransparency: Bool) -> Bool {
        !reduceTransparency && (theme.colorScheme ?? host) == host
    }

    fileprivate func normalized() -> ReadingAppearance {
        var value = self
        var seen: Set<UUID> = []
        value.presets = value.presets.prefix(32).filter { seen.insert($0.id).inserted }.map {
            var preset = $0
            preset.name = String(preset.name.prefix(60))
            preset.textSize = preset.textSize.isFinite ? min(32, max(11, preset.textSize)) : 15
            preset.width = preset.width.isFinite ? min(1_200, max(380, preset.width)) : 760
            return preset
        }
        if value.presets.isEmpty { value.presets = ReadingAppearance().presets }
        value.selected = value.preset.id
        return value
    }
}

@MainActor
public final class ReadingAppearanceStore: ObservableObject {
    public static let shared = ReadingAppearanceStore()
    @Published public private(set) var value = ReadingAppearance()
    private let file: URL?
    private let defaults: UserDefaults
    private let key = "GlancemarkReadingAppearance"

    init(file: URL? = nil, defaults: UserDefaults = .standard, useSignedGroup: Bool = true) {
        self.defaults = defaults
        if let file {
            self.file = file
        } else if useSignedGroup,
                  let group = Bundle.main.object(forInfoDictionaryKey: "GlancemarkAppearanceGroup") as? String,
                  !group.isEmpty,
                  let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            self.file = container.appendingPathComponent("ReadingAppearance.json")
        } else {
            self.file = nil
        }
        reload()
    }

    public func reload() {
        let bytes = file.flatMap { try? Data(contentsOf: $0) } ?? defaults.data(forKey: key)
        if let bytes, bytes.count <= 65_536, let saved = try? JSONDecoder().decode(ReadingAppearance.self, from: bytes) {
            value = saved.normalized()
        }
    }

    public func update(_ change: (inout ReadingAppearance) -> Void) throws {
        var next = value
        change(&next)
        next = next.normalized()
        let bytes = try JSONEncoder().encode(next)
        if let file {
            try bytes.write(to: file, options: .atomic)
        } else {
            defaults.set(bytes, forKey: key)
        }
        value = next
    }
}
