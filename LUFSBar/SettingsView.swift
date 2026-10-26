import SwiftUI

struct SettingsView: View {
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @ObservedObject private var meterState = MeterState.shared

    var body: some View {
        Form {
            // The toggle shows what the system has, not what was last clicked: after
            // a change it is read back, so one that fails puts the toggle back
            // (1.1 left it flipped), and it is read again whenever the window comes
            // forward, since it can be changed in System Settings meanwhile.
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLoginEnabled },
                set: { wanted in
                    LaunchAtLogin.setEnabled(wanted)
                    launchAtLoginEnabled = LaunchAtLogin.isEnabled
                }
            ))
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                // This window only: the view outlives its window closing, and the
                // popover's window becomes key on every click.
                guard (note.object as? NSWindow)?.title == Self.windowTitle else { return }
                launchAtLoginEnabled = LaunchAtLogin.isEnabled
            }

            // Bound directly to MeterState.shared.compactMenuBar, the same value
            // the right-click menu toggles, so both stay in sync automatically.
            Toggle("Compact menu bar display", isOn: $meterState.compactMenuBar)

            Section {
                LabeledContent("Version", value: Self.versionString)
                Link("libebur128 (MIT License)", destination: URL(string: "https://github.com/jiixyj/libebur128")!)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    static let windowTitle = "LUFSBar Settings"

    private static var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
