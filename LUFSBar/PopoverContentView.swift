import SwiftUI
import AppKit

struct PopoverContentView: View {
    @ObservedObject private var meterState = MeterState.shared
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LUFSBar")
                    .font(.headline)
                Spacer()
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                Button(action: onQuit) {
                    Image(systemName: "power")
                }
                .buttonStyle(.plain)
            }

            Divider()

            if meterState.needsManualStart {
                startMeteringView
            } else if meterState.audioAccessError {
                audioAccessErrorView
            } else {
                if meterState.possiblyMissingAudioAccess {
                    possiblyMissingAudioAccessHint
                    Divider()
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row(label: "Momentary", value: meterState.momentaryLUFS, unit: "LUFS")
                    row(
                        label: "Short-term", value: meterState.shortTermLUFS, unit: "LUFS",
                        delta: MeterState.delta(current: meterState.shortTermLUFS, reference: meterState.referenceSnapshot?.shortTermLUFS)
                    )
                    row(
                        label: "Integrated", value: meterState.integratedLUFS, unit: "LUFS",
                        delta: MeterState.delta(current: meterState.integratedLUFS, reference: meterState.referenceSnapshot?.integratedLUFS)
                    )
                    row(
                        label: "True Peak", value: meterState.truePeakDBTP, unit: "dBTP",
                        delta: MeterState.delta(current: meterState.truePeakDBTP, reference: meterState.referenceSnapshot?.truePeakDBTP)
                    )
                }

                Divider()

                HStack(spacing: 8) {
                    Button(meterState.referenceSnapshot == nil ? "Save Reference" : "Update Reference") {
                        meterState.saveReferenceSnapshot()
                    }
                    .buttonStyle(.bordered)

                    if meterState.referenceSnapshot != nil {
                        Button("Clear") {
                            meterState.clearReferenceSnapshot()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Divider()

                Text("Streaming Normalization Forecast (Integrated)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(StreamingTarget.all, id: \.name) { target in
                        streamingRow(target)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    private var startMeteringView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome to LUFSBar")
                .font(.callout)
                .fontWeight(.semibold)
            Text("Click below to start metering. macOS will ask for permission to access system audio the first time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Start Metering") {
                meterState.startMeteringManually()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var possiblyMissingAudioAccessHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Not detecting any audio yet")
                .font(.caption)
                .fontWeight(.semibold)
            Text("If this doesn't change while sound is playing, check System Audio Recording access.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var audioAccessErrorView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("System audio access is required")
                .font(.callout)
                .fontWeight(.semibold)
            Text("LUFSBar couldn't start capturing system audio. Please allow access in System Settings, then relaunch LUFSBar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func streamingRow(_ target: StreamingTarget) -> some View {
        GridRow {
            Text(target.name)
                .foregroundStyle(.secondary)
            Text(streamingPredictionText(for: target))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(streamingPredictionColor(for: target))
                .gridColumnAlignment(.trailing)
        }
    }

    private func streamingPredictionText(for target: StreamingTarget) -> String {
        guard let diff = MeterState.delta(current: meterState.integratedLUFS, reference: target.targetLUFS) else {
            return "--"
        }
        return diff > 0.05 ? String(format: "-%.1f dB", diff) : "OK"
    }

    private func streamingPredictionColor(for target: StreamingTarget) -> Color {
        guard let diff = MeterState.delta(current: meterState.integratedLUFS, reference: target.targetLUFS) else {
            return .secondary
        }
        return diff > 0.05 ? .orange : .green
    }

    @ViewBuilder
    private func row(label: String, value: Double, unit: String, delta: Double? = nil) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("\(MeterState.displayString(value)) \(unit)")
                    .font(.system(.body, design: .monospaced))
                if let delta {
                    Text(deltaString(delta))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(delta >= 0 ? .green : .red)
                }
            }
            .gridColumnAlignment(.trailing)
        }
    }

    private func deltaString(_ delta: Double) -> String {
        let sign = delta >= 0 ? "+" : ""
        return "(\(sign)\(String(format: "%.1f", delta)))"
    }
}
