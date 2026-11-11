import AppKit
import GlancemarkCore
import SwiftUI

@MainActor
final class AppearanceSettingsController: NSObject {
    static let shared = AppearanceSettingsController()
    private var window: NSWindow?

    @objc func show(_ sender: Any?) {
        if let window {
            window.makeKeyAndOrderFront(sender)
            return
        }
        let controller = NSHostingController(rootView: AppearanceSettingsView())
        let window = NSWindow(contentViewController: controller)
        window.title = "Reading Appearance"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(sender)
        self.window = window
    }
}

private struct AppearanceSettingsView: View {
    @ObservedObject var store = ReadingAppearanceStore.shared
    @State private var saveError: String?

    var body: some View {
        Form {
            Picker("Appearance", selection: Binding(get: { store.value.theme }, set: { theme in
                change { $0.theme = theme }
            })) {
                ForEach(ReadingAppearance.Theme.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                Picker("Preset", selection: Binding(get: { store.value.preset.id }, set: { id in
                    change { $0.selected = id }
                })) {
                    ForEach(store.value.presets) { Text($0.name).tag($0.id) }
                }
                Button("Add") {
                    change {
                        var preset = $0.preset
                        preset.id = UUID()
                        preset.name = "Custom"
                        $0.presets.append(preset)
                        $0.selected = preset.id
                    }
                }.disabled(store.value.presets.count >= 32)
                Button("Remove") {
                    change {
                        let selected = $0.preset.id
                        $0.presets.removeAll { $0.id == selected }
                        $0.selected = $0.presets.first?.id
                    }
                }.disabled(store.value.presets.count <= 1)
            }
            TextField("Name", text: presetBinding(\.name))
            HStack {
                Slider(value: presetBinding(\.textSize), in: 11...32, step: 1) { Text("Text size") }
                Text("\(Int(store.value.preset.textSize)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            HStack {
                Slider(value: presetBinding(\.width), in: 380...1200, step: 10) { Text("Reading width") }
                Text("\(Int(store.value.preset.width)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            Picker("Background", selection: presetBinding(\.surface)) {
                ForEach(ReadingAppearance.Surface.allCases) { Text($0.rawValue).tag($0) }
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
        }.padding(22).frame(width: 460)
    }

    private func presetBinding<Value>(_ key: WritableKeyPath<ReadingAppearance.Preset, Value>) -> Binding<Value> {
        Binding(get: { store.value.preset[keyPath: key] }, set: { value in
            change {
                let id = $0.preset.id
                if let index = $0.presets.firstIndex(where: { $0.id == id }) {
                    $0.presets[index][keyPath: key] = value
                }
            }
        })
    }

    private func change(_ action: (inout ReadingAppearance) -> Void) {
        do { try store.update(action); saveError = nil }
        catch { saveError = "Couldn’t save reading appearance." }
    }
}
