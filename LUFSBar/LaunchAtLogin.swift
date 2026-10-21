import Foundation
import ServiceManagement
import os

// Uses SMAppService.mainApp (macOS 13+) to register and unregister the app
// itself as a login item, with no helper bundle required.
enum LaunchAtLogin {
    private static let log = Logger(subsystem: "com.tokyomeltdown.lufsbar", category: "app")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// LUFSBAR_FAIL_LAUNCH_AT_LOGIN = 1: test only. Changing the setting fails
    /// before the system is asked, so a test can see what the toggle does then
    /// without touching the real login item.
    private static let failOnPurpose = ProcessInfo.processInfo.environment["LUFSBAR_FAIL_LAUNCH_AT_LOGIN"] == "1"

    static func setEnabled(_ enabled: Bool) {
        do {
            if failOnPurpose {
                log.error("Launch at Login: failing on purpose")
                throw CocoaError(.featureUnsupported)
            }
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            log.error("Launch at Login: failed to change the setting: \(error.localizedDescription, privacy: .public)")
        }
    }

    // Enabled by default on the very first launch only. Once the user turns it
    // off in Settings, that choice is respected and never silently re-enabled.
    private static let hasConfiguredDefaultKey = "LaunchAtLogin.hasConfiguredDefault"

    static func enableByDefaultOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: hasConfiguredDefaultKey) else { return }
        setEnabled(true)
        defaults.set(true, forKey: hasConfiguredDefaultKey)
    }
}
