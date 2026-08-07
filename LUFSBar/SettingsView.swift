import SwiftUI

struct SettingsView: View {
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @ObservedObject private var meterState = MeterState.shared

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: $launchAtLoginEnabled)
                .onChange(of: launchAtLoginEnabled) { _, newValue in
                    LaunchAtLogin.setEnabled(newValue)
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

    private static var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
