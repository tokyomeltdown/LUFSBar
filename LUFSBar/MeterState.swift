import Foundation
import os
import Combine

// Polls the LoudnessMeter in SystemAudioTap roughly every 100ms and turns
// the result into the text shown in the menu bar.
/// The raw values are what is stored in the user defaults, so they are spelt out
/// rather than left to follow the case names.
enum MenuBarMetric: String, Equatable {
    case momentary = "momentary"
    case shortTerm = "shortTerm"
    case integrated = "integrated"
}

/// A snapshot of I/S/TP at one moment, saved with a single click.
/// (Momentary is excluded on purpose: too instantaneous to compare against.)
struct ReferenceSnapshot {
    let shortTermLUFS: Double
    let integratedLUFS: Double
    let truePeakDBTP: Double
}

/// Loudness normalization targets of the major streaming services (LUFS).
struct StreamingTarget {
    let name: String
    let targetLUFS: Double

    static let all: [StreamingTarget] = [
        StreamingTarget(name: "Apple Music", targetLUFS: -16),
        StreamingTarget(name: "Spotify", targetLUFS: -14),
        StreamingTarget(name: "YouTube", targetLUFS: -14)
    ]
}

final class MeterState: ObservableObject {
    private static let log = Logger(subsystem: "com.tokyomeltdown.lufsbar", category: "meter")

    static let shared = MeterState()

    @Published private(set) var menuBarText: String = MeterState.silentText
    @Published private(set) var momentaryLUFS: Double = -Double.infinity
    @Published private(set) var shortTermLUFS: Double = -Double.infinity
    @Published private(set) var integratedLUFS: Double = -Double.infinity
    @Published private(set) var truePeakDBTP: Double = -Double.infinity

    // Reference snapshot: shows the difference against the I/S/TP saved with one click.
    @Published private(set) var referenceSnapshot: ReferenceSnapshot?

    // Set when SystemAudioTap.start() fails creating the tap or the aggregate device,
    // or in AudioDeviceStart. Typically the system audio permission is denied.
    @Published private(set) var audioAccessError = false

    // When postinstall auto-launches the app via launchctl asuser, that first session
    // still carries the installer context. Creating the tap there was observed on a real
    // machine to put tccd into a suppressed state without ever showing the prompt.
    // So on the first launch the tap is not created immediately; an explicit click from
    // the user triggers it, which reliably brings up the proper permission prompt.
    static let hasCompletedFirstLaunchKey = "LUFSBar.hasCompletedFirstLaunchTapStart"
    @Published private(set) var needsManualStart = false

    func markNeedsManualStart() {
        needsManualStart = true
    }

    func startMeteringManually() {
        SystemAudioTap.shared.start()
        needsManualStart = false
        UserDefaults.standard.set(true, forKey: Self.hasCompletedFirstLaunchKey)
    }

    // Even with the tap and aggregate device created successfully, without the recording
    // permission the API returns no error and just delivers silence (seen on a real Mac).
    // Since 1.1.1 only the default output is measured, so audio going to another device
    // looks the same. If no valid audio has been seen since launch for a long time, a hint
    // naming both is shown. This is a heuristic; there is no reliable way to detect either.
    @Published private(set) var possiblyMissingAudioAccess = false
    private var hasEverCapturedRealAudio = false
    private var neverCapturedPollCount = 0
    private let possiblyMissingAudioAccessThresholdPolls = 900  // 0.1s x 900 = about 90 seconds

    // Which figure is shown live in the menu bar. Switchable from the right-click menu,
    // and kept across launches (1.1 forgot it and came back on Short-term).
    private static let menuBarMetricKey = "menuBarMetric"
    @Published var menuBarMetric: MenuBarMetric = .shortTerm {
        didSet {
            guard oldValue != menuBarMetric else { return }
            UserDefaults.standard.set(menuBarMetric.rawValue, forKey: Self.menuBarMetricKey)
            // Reset the smoothing, so switching does not briefly blend the new figure with the
            // old one and show something nonsensical.
            displaySmoothedValue = -Double.infinity
        }
    }

    // Compact menu bar display: drops the " LUFS" suffix and shows the number only.
    // Changeable from both the Settings toggle and the right-click menu; they observe
    // the same @Published property, so they stay in sync automatically.
    private static let compactMenuBarKey = "compactMenuBar"
    @Published var compactMenuBar: Bool = false {
        didSet {
            guard oldValue != compactMenuBar else { return }
            UserDefaults.standard.set(compactMenuBar, forKey: Self.compactMenuBarKey)
            // Apply immediately instead of waiting for the next poll.
            menuBarText = Self.format(displaySmoothedValue, compact: compactMenuBar)
        }
    }

    // Uses the LUFS absolute gate (-70) as the display floor. Hides the transient nonsense
    // right after silence (momentary can pass a finite value below -1000 before -inf) and
    // stops the menu bar width wobbling as the digit count changes.
    private static let displayFloor: Double = -70

    // A normal space (U+0020) can be collapsed by the layout, which makes the menu bar
    // width wobble whenever the digit count changes. Padding to a fixed five characters
    // with a non-breaking space (U+00A0) avoids that.
    private static let nbsp: Character = "\u{00A0}"

    private static func padded(_ raw: String) -> String {
        guard raw.count < 5 else { return raw }
        return String(repeating: nbsp, count: 5 - raw.count) + raw
    }

    private static let silentText: String = padded("--") + String(nbsp) + "LUFS"

    private var timer: Timer?

    // Smoothed value used only for the menu bar text. The figures themselves stay raw;
    // the anti-flicker pass is applied only when the text is generated.
    private var displaySmoothedValue: Double = -Double.infinity

    // If silence (momentary at -inf, i.e. true digital silence) lasts a while, playback is
    // assumed to have stopped and Integrated is reset automatically. The decision uses
    // continuous silence so a brief gap between tracks does not trigger it. It resets once
    // per episode, and the flag clears when audio returns.
    private var silentPollCount = 0
    private var hasAutoResetForCurrentSilence = false
    private let silenceResetThresholdPolls = 20  // 0.1s x 20 = about 2 seconds

    /// The text last put into the menu bar item itself, which is not always
    /// menuBarText: it is copied there by a subscriber. Logged in the level line,
    /// so a test can see what is actually on screen.
    var appliedMenuBarTitle = ""

    // How many times objectWillChange fired, logged every 10 s, so a test can see
    // how often the views are told to redraw.
    private var publishCount = 0
    private var publishCountPolls = 0
    private var publishCounter: AnyCancellable?

    init() {
        compactMenuBar = UserDefaults.standard.bool(forKey: Self.compactMenuBarKey)
        if let stored = UserDefaults.standard.string(forKey: Self.menuBarMetricKey),
           let metric = MenuBarMetric(rawValue: stored) {
            menuBarMetric = metric
        }
        publishCounter = objectWillChange.sink { [weak self] _ in self?.publishCount += 1 }
    }

    func startPolling() {
        timer?.invalidate()
        // In the common modes, so the meter keeps going while a menu is open: in
        // the default mode alone it stopped for as long as the right-click menu was
        // showing.
        let poll = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func saveReferenceSnapshot() {
        referenceSnapshot = ReferenceSnapshot(
            shortTermLUFS: shortTermLUFS,
            integratedLUFS: integratedLUFS,
            truePeakDBTP: truePeakDBTP
        )
    }

    func clearReferenceSnapshot() {
        referenceSnapshot = nil
    }

    func reportAudioAccessError() {
        audioAccessError = true
    }

    func clearAudioAccessError() {
        audioAccessError = false
    }

    /// Difference between the current value and the reference. nil when they cannot be compared.
    static func delta(current: Double, reference: Double?) -> Double? {
        guard let reference, current.isFinite, reference.isFinite else { return nil }
        return current - reference
    }

    /// Counts towards the hint above. Called whether or not a meter exists: the tap only
    /// starts delivering once something plays to the device it is bound to, so with the
    /// audio going elsewhere no meter is ever built, and that is exactly when the hint is
    /// needed.
    private func noteNoAudioYet() {
        guard !hasEverCapturedRealAudio, !needsManualStart else { return }
        neverCapturedPollCount += 1
        if neverCapturedPollCount >= possiblyMissingAudioAccessThresholdPolls, !possiblyMissingAudioAccess {
            possiblyMissingAudioAccess = true
            Self.log.notice("no audio since launch: showing the sound output and access hint")
        }
    }

    private func refresh() {
        publishCountPolls += 1
        if publishCountPolls >= 100 {
            Self.log.notice("published \(self.publishCount) changes in the last \(self.publishCountPolls) polls")
            publishCount = 0
            publishCountPolls = 0
        }
        // A meter that is no longer being fed keeps its last figures, and those look
        // exactly like a live reading. Treated the same as having no meter at all,
        // in the popover as well as the menu bar.
        guard let meter = SystemAudioTap.shared.loudnessMeter, SystemAudioTap.shared.isDelivering else {
            noteNoAudioYet()
            if momentaryLUFS.isFinite { momentaryLUFS = -Double.infinity }
            if shortTermLUFS.isFinite { shortTermLUFS = -Double.infinity }
            if integratedLUFS.isFinite { integratedLUFS = -Double.infinity }
            if truePeakDBTP.isFinite { truePeakDBTP = -Double.infinity }
            displaySmoothedValue = -Double.infinity
            let silentDisplay = compactMenuBar ? Self.padded("--") : Self.silentText
            if menuBarText != silentDisplay {
                menuBarText = silentDisplay
            }
            return
        }
        // One locked read: the audio thread writes these as it refreshes.
        // Each @Published assignment tells every view to redraw, equal value or
        // not, so only a change is assigned (1.1 sent 400 redraws per 10 s of
        // silence).
        let reading = meter.reading
        if momentaryLUFS != reading.momentary { momentaryLUFS = reading.momentary }
        if shortTermLUFS != reading.shortTerm { shortTermLUFS = reading.shortTerm }
        if integratedLUFS != reading.integrated { integratedLUFS = reading.integrated }
        if truePeakDBTP != reading.truePeak { truePeakDBTP = reading.truePeak }

        if momentaryLUFS.isFinite {
            hasEverCapturedRealAudio = true
            neverCapturedPollCount = 0
            if possiblyMissingAudioAccess { possiblyMissingAudioAccess = false }
            silentPollCount = 0
            hasAutoResetForCurrentSilence = false
        } else {
            noteNoAudioYet()
            silentPollCount += 1
            if silentPollCount >= silenceResetThresholdPolls && !hasAutoResetForCurrentSilence {
                SystemAudioTap.shared.resetIntegrated()
                hasAutoResetForCurrentSilence = true
            }
        }

        let selectedValue: Double
        switch menuBarMetric {
        case .momentary: selectedValue = momentaryLUFS
        case .shortTerm: selectedValue = shortTermLUFS
        case .integrated: selectedValue = integratedLUFS
        }

        if selectedValue.isFinite {
            if displaySmoothedValue.isFinite {
                // An exponential moving average smooths the display only.
                displaySmoothedValue += (selectedValue - displaySmoothedValue) * 0.2
            } else {
                displaySmoothedValue = selectedValue
            }
        } else {
            displaySmoothedValue = -Double.infinity
        }

        // Only touch @Published when the text actually changes, to avoid needless redraws.
        let newText = Self.format(displaySmoothedValue, compact: compactMenuBar)
        if newText != menuBarText {
            menuBarText = newText
        }
    }

    static func format(_ value: Double, compact: Bool = false) -> String {
        guard value.isFinite else { return compact ? padded("--") : silentText }
        let clamped = max(value, displayFloor)
        let raw = String(format: "%.1f", clamped)
        let numberPart = padded(raw)
        return compact ? numberPart : numberPart + String(nbsp) + "LUFS"
    }

    /// A plain numeric readout for places without the menu bar fixed-width constraint.
    static func displayString(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        let clamped = max(value, displayFloor)
        return String(format: "%.1f", clamped)
    }
}
