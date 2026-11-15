import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class LoginSettings: ObservableObject {
    static let shared = LoginSettings()
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?

    private let service = SMAppService.mainApp
    private let configuredKey = "GlancemarkLoginItemConfigured"

    private init() {}

    func configureDefault() {
        if Bundle.main.object(forInfoDictionaryKey: "GlancemarkDefaultStartAtLogin") as? String == "YES",
           !UserDefaults.standard.bool(forKey: configuredKey) {
            if service.status == .notRegistered {
                setEnabled(true)
            } else if service.status == .enabled || service.status == .requiresApproval {
                UserDefaults.standard.set(true, forKey: configuredKey)
            }
        }
        refresh()
    }

    func refresh() {
        let status = service.status
        isEnabled = status == .enabled || status == .requiresApproval
        requiresApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        // Remember the user's choice even when macOS declines registration.
        UserDefaults.standard.set(true, forKey: configuredKey)
        do {
            switch (enabled, service.status) {
            case (true, .enabled), (true, .requiresApproval), (false, .notRegistered), (false, .notFound):
                break
            case (true, _):
                try service.register()
            case (false, _):
                try service.unregister()
            }
        } catch {
            errorMessage = enabled ? "Couldn’t enable start at login." : "Couldn’t disable start at login."
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
