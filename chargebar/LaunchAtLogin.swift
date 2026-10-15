import Foundation
import ServiceManagement
import os

@MainActor
enum LaunchAtLogin {
    private static let log = Logger(subsystem: "net.digital-shokunin.chargebar", category: "LaunchAtLogin")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when the user has to approve the login item in System Settings.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Launch at login toggle failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
