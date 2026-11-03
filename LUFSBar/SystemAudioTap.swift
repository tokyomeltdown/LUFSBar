import Foundation
import CoreAudio
import os

/// The LUFSBAR_* test switches, read in one place: a positive, finite value no
/// larger than `limit`, or nil, so a typo cannot reach a conversion that traps.
/// Read on the main thread only: reading the environment allocates and takes
/// locks, and a switch held in a static is first read wherever it is first
/// used, which must not be the audio thread. A read anywhere else is logged,
/// so a test can tell.
enum TestSwitch {
    private static let log = Logger(subsystem: "com.tokyomeltdown.lufsbar", category: "switch")

    static func number(_ name: String, limit: Double) -> Double? {
        if !Thread.isMainThread {
            log.error("test switch \(name, privacy: .public) was read off the main thread")
        }
        guard let raw = ProcessInfo.processInfo.environment[name],
              let value = Double(raw), value.isFinite, value > 0 else { return nil }
        return min(value, limit)
    }

    /// A list such as "1,2,3,5": positive whole numbers, or nil when the switch
    /// is not set or any item is not one (so a typo fails nothing, rather than
    /// everything, and the "on purpose" lines the tests look for are missing).
    static func numbers(_ name: String) -> Set<Int>? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        let items = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !items.isEmpty, items.allSatisfy({ ($0 ?? 0) > 0 }) else { return nil }
        return Set(items.compactMap { $0 })
    }
}

// Uses the macOS 14.4+ Core Audio process tap to capture what every process is
// playing to the Mac's default output, through a single private, tap-only
// aggregate device. Audio sent to any other device is not measured.
// Reference: https://github.com/insidegui/AudioCap
final class SystemAudioTap {
    static let shared = SystemAudioTap()

    // Read back with:
    //   /usr/bin/log show --last 5m --predicate 'subsystem == "com.tokyomeltdown.lufsbar"'
    // NSLog's text is hidden as <private> in the unified log.
    private static let log = Logger(subsystem: "com.tokyomeltdown.lufsbar", category: "tap")

    /// LUFSBAR_METER_HOLD_MS = n: test only. The audio thread holds the meter
    /// for n ms before feeding it, widening the window in which the main thread
    /// can let go of it at the same moment. Read once by start().
    private static let meterHoldMicroseconds: UInt32 =
        TestSwitch.number("LUFSBAR_METER_HOLD_MS", limit: 1000).map { UInt32($0 * 1000) } ?? 0
    /// Test only; see LUFSBAR_DROP_METER_EVERY_MS in start().
    private var meterDropTimer: Timer?

    /// Makes startTap() give up at a named point, so the teardown that runs
    /// when it does can actually be fired.
    /// LUFSBAR_FAIL_START_AT = defaultdevice | uid | tap | aggregate | ioproc | devicestart
    /// (defaultdevice: reading which device is the default output fails;
    /// uid: the default output's UID cannot be read)
    /// LUFSBAR_FAIL_START_TIMES = n: only the first n attempts fail (default: all).
    /// LUFSBAR_FAIL_START_ATTEMPTS = 1,2,3,5: only those attempts fail.
    private static let failStartAt = ProcessInfo.processInfo.environment["LUFSBAR_FAIL_START_AT"]
    private static var failStartsLeft: Int? =
        TestSwitch.number("LUFSBAR_FAIL_START_TIMES", limit: 1000).map { Int($0) }
    private static let failStartAttempts = TestSwitch.numbers("LUFSBAR_FAIL_START_ATTEMPTS")
    private static var failStartCalls = 0
    /// LUFSBAR_NO_OUTPUT_AT_ATTEMPT = n: the n-th build reads no default output.
    private static let noOutputAttempt = TestSwitch.number("LUFSBAR_NO_OUTPUT_AT_ATTEMPT", limit: 1000).map { Int($0) }
    private static var startTapCalls = 0
    /// LUFSBAR_METER_RATE = Hz: the meter request reads this as the rate, for
    /// the first LUFSBAR_METER_RATE_TIMES requests (default: all), the way a
    /// device that is reconfiguring or going away can answer.
    private static let meterRateOverride = TestSwitch.number("LUFSBAR_METER_RATE", limit: 1e9)
    private static var meterRateOverridesLeft: Int? =
        TestSwitch.number("LUFSBAR_METER_RATE_TIMES", limit: 1000).map { Int($0) }
    /// LUFSBAR_METER_REQUEST_DELAY_MS = n: a meter request waits n ms before the
    /// main thread takes it up, so a test can rebuild the tap while one waits.
    private static let meterRequestDelay = TestSwitch.number("LUFSBAR_METER_REQUEST_DELAY_MS", limit: 60_000)
    private static func overriddenMeterRate() -> Double? {
        guard let rate = meterRateOverride else { return nil }
        if let left = meterRateOverridesLeft {
            guard left > 0 else { return nil }
            meterRateOverridesLeft = left - 1
        }
        log.error("reading the meter's rate as \(rate) Hz on purpose")
        return rate
    }
    private static func shouldFail(at point: String) -> Bool {
        guard failStartAt == point else { return false }
        failStartCalls += 1
        if let attempts = failStartAttempts, !attempts.contains(failStartCalls) { return false }
        if let left = failStartsLeft {
            guard left > 0 else { return false }
            failStartsLeft = left - 1
        }
        log.error("failing on purpose at \(point, privacy: .public)")
        return true
    }

    private var tapID: AudioObjectID = kAudioObjectUnknown
    /// The tap on the right channel's stream, when the stereo pair spans two.
    private var secondTapID: AudioObjectID = kAudioObjectUnknown
    /// Where the two sides are in what the IOProc is given, when the pair spans
    /// two streams (nil otherwise). Set on the main thread before the IOProc
    /// exists and cleared after it is gone.
    private struct SpanRoute {
        var buffers: Int
        var leftBuffer: Int, leftOffset: Int, leftStride: Int
        var rightBuffer: Int, rightOffset: Int, rightStride: Int
    }
    private var spanRoute: SpanRoute?
    /// Which tap this is: one more for every build. A meter request carries the
    /// one it was made for, so a request left over from the tap before a rebuild
    /// is dropped instead of being served (and counted) against the new one.
    /// Written on the main thread before the IOProc exists, read under the
    /// meter lock.
    private var generation: UInt64 = 0
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?

    // The meter is installed and let go of on the main thread and used on the
    // Core Audio IO thread, so the reference itself is guarded by a lock.
    /// A pointer, not a stored value: `&someProperty` passed to a C function
    /// may be a temporary copy, and a lock that gets copied is not a lock.
    private let loudnessMeterLock: UnsafeMutablePointer<os_unfair_lock_s> = {
        let lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())
        return lock
    }()
    private var _loudnessMeter: LoudnessMeter?
    /// Up from the moment the audio thread asks for a meter until one is
    /// installed, the tap is torn down, or (after a meter that could not be
    /// built) a second has passed; under the same lock. While it is up, no
    /// callback asks again.
    private var isBuildingLoudnessMeter = false
    /// What the audio thread asked for, under the same lock: plain values, so
    /// writing it allocates nothing. Taken up by the main thread's meterPoll.
    private struct MeterRequest {
        var channels: Int
        var replacing: Bool
        var tapChannels: Int
        var buffers: Int
        var generation: UInt64
        var askedAt: UInt64
    }
    private var pendingMeterRequest: MeterRequest?
    /// Takes up a meter request ten times a second. In the common modes, so it
    /// goes on while a menu is open.
    private var meterPoll: Timer?

    var loudnessMeter: LoudnessMeter? {
        os_unfair_lock_lock(loudnessMeterLock)
        defer { os_unfair_lock_unlock(loudnessMeterLock) }
        return _loudnessMeter
    }

    /// Main thread only.
    private func setLoudnessMeter(_ meter: LoudnessMeter?) {
        os_unfair_lock_lock(loudnessMeterLock)
        let retired = _loudnessMeter
        _loudnessMeter = meter
        os_unfair_lock_unlock(loudnessMeterLock)
        retire(retired)
    }

    /// The audio thread may be holding the old meter at this very moment, and if
    /// this was the last other reference, its own release would be the one that
    /// frees it: a run of free() on the audio thread. Kept for a second, far
    /// longer than any callback, so the last release happens on the main thread.
    /// tests/realtime.sh measured 38 of 70 meters freed on the audio thread
    /// without this.
    private func retire(_ meter: LoudnessMeter?) {
        guard let meter else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { withExtendedLifetime(meter) {} }
    }

    /// Asks the main thread for a meter with `channels` channels, rather than
    /// building one here: building allocates and asks the HAL for the sample
    /// rate, and this is called from the IOProc. The request is written down
    /// under the meter lock the IOProc takes anyway, and meterPoll takes it up
    /// within 100 ms. (It used to hand a block to the main run loop from here:
    /// three mallocs, the run loop's lock and a Mach message on the audio
    /// thread at every tap build. tests/realtime.sh 7.) With `replacing`, the
    /// current meter is swapped for the new one (the tap's layout changed
    /// under it).
    private func requestLoudnessMeter(channels: Int, replacing: Bool, tapChannels: Int, buffers: Int) {
        os_unfair_lock_lock(loudnessMeterLock)
        if !isBuildingLoudnessMeter {
            isBuildingLoudnessMeter = true
            pendingMeterRequest = MeterRequest(channels: channels, replacing: replacing, tapChannels: tapChannels,
                                               buffers: buffers, generation: generation, askedAt: mach_absolute_time())
        }
        os_unfair_lock_unlock(loudnessMeterLock)
    }

    /// meterPoll's work: builds the meter asked for, if any. Main thread only.
    private func serviceMeterRequest() {
        os_unfair_lock_lock(loudnessMeterLock)
        var request = pendingMeterRequest
        // Test only: LUFSBAR_METER_REQUEST_DELAY_MS holds a request back.
        if let ms = Self.meterRequestDelay, let held = request,
           Double(mach_absolute_time() - held.askedAt) * Self.nanosecondsPerTick < ms * 1_000_000 {
            request = nil
        }
        if request != nil { pendingMeterRequest = nil }
        os_unfair_lock_unlock(loudnessMeterLock)
        guard let request else { return }
        let channels = request.channels, replacing = request.replacing
        let tapChannels = request.tapChannels, buffers = request.buffers
        do {
            // stopTap() drops a request it finds, so one from an earlier tap
            // only gets here in a race with it; a meter put on a tap that is
            // gone would show figures nothing feeds.
            guard self.ioProcID != nil, self.generation == request.generation else {
                Self.log.notice("dropping a meter request from an earlier tap")
                return
            }
            // The rate comes from the HAL, and a device that is reconfiguring
            // or going away can report anything, or nothing. When there is no
            // meter to be had, it is asked for again later (see meterFailed);
            // the tap is not rebuilt for it, which would not help. Before,
            // the flag stayed up for good, and the menu bar showed "--" with
            // the audio playing until something else rebuilt the tap.
            guard let nominal = Self.overriddenMeterRate() ?? self.nominalSampleRate(),
                  let sampleRate = LoudnessMeter.sampleRate(fromNominal: nominal) else {
                Self.log.error("the aggregate gives no sample rate a meter can be built at")
                self.meterFailed()
                return
            }
            // ebur128_init only fails on a refused sample rate or a failed malloc.
            guard let meter = LoudnessMeter(sampleRate: sampleRate, channels: UInt32(channels)) else {
                Self.log.error("the meter could not be built at \(sampleRate) Hz")
                self.meterFailed()
                return
            }
            os_unfair_lock_lock(self.loudnessMeterLock)
            // Only into an empty place, unless asked to replace. Requests from an
            // earlier tap were dropped above, and one tap has one request out at
            // a time, so this is a guard rather than a case that comes up.
            let installed = replacing || self._loudnessMeter == nil
            var retired: LoudnessMeter?
            if installed {
                retired = self._loudnessMeter
                self._loudnessMeter = meter
            }
            self.isBuildingLoudnessMeter = false
            os_unfair_lock_unlock(self.loudnessMeterLock)
            self.retire(retired)
            guard installed else { return }
            self.meterFailures = 0
            Self.log.notice("LoudnessMeter init sampleRate=\(sampleRate) channels=\(channels) of tapChannels=\(tapChannels) buffers=\(buffers) on the \(Thread.isMainThread ? "main" : "audio", privacy: .public) thread")
        }
    }

    /// Meters that could not be built in a row on this tap, for the log. Counted
    /// apart from failed builds: the tap is running, so this is no matter of
    /// access, and no panel is shown for it.
    private var meterFailures = 0
    private var meterRetry: Timer?

    /// Lets the next callback ask for a meter again a second later. Until then
    /// the flag stays up and nothing asks. Every second, not on the build
    /// schedule: asking costs one HAL read and nothing else on the Mac, and on
    /// that schedule a device that had recovered went on showing "--", with the
    /// audio playing, for as long as the 30 or 60 s step it had reached.
    /// Main thread only.
    private func meterFailed() {
        meterFailures += 1
        Self.log.notice("asking for a meter again in 1 s (meter failure \(self.meterFailures))")
        meterRetry?.invalidate()
        let retry = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            guard let self else { return }
            os_unfair_lock_lock(self.loudnessMeterLock)
            self.isBuildingLoudnessMeter = false
            os_unfair_lock_unlock(self.loudnessMeterLock)
        }
        RunLoop.main.add(retry, forMode: .common)
        meterRetry = retry
    }

    /// The level line, once a second, from the main thread. It used to be
    /// written from inside the IO callback, and logging takes locks.
    private var levelLogTimer: Timer?

    private func logMeterLevels() {
        // What the meter holds, and what the app is showing: the menu bar text,
        // the popover's four figures and the metric in the menu bar. The second
        // half is what a person sees, so the display tests read it from here.
        // The meter half is "--" when nothing is being delivered: a meter that is
        // no longer fed keeps its last figures, and a test reading them would take
        // a dead tap for a live one.
        let state = MeterState.shared
        let shown = "shown=\"\(state.menuBarText)\" title=\"\(state.appliedMenuBarTitle)\" popover=\(Self.figure(state.momentaryLUFS))/\(Self.figure(state.shortTermLUFS))/\(Self.figure(state.integratedLUFS))/\(Self.figure(state.truePeakDBTP)) metric=\(state.menuBarMetric)"
        if isDelivering, let reading = loudnessMeter?.reading {
            Self.log.notice("M=\(Self.figure(reading.momentary), privacy: .public) S=\(Self.figure(reading.shortTerm), privacy: .public) I=\(Self.figure(reading.integrated), privacy: .public) TP=\(Self.figure(reading.truePeak), privacy: .public) \(shown, privacy: .public)")
        } else {
            Self.log.notice("M=-- S=-- I=-- TP=-- \(shown, privacy: .public)")
        }
    }

    private static func figure(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f", value) : "--"
    }

    /// When the IOProc last fed the meter, so the display can tell a reading that
    /// is current from one that stopped being fed. A callback that arrives and
    /// feeds nothing (no meter yet, a layout the meter does not match) does not
    /// count. Written on the audio thread and read on the main one without a
    /// lock: an aligned 64 bit store is a single instruction here, and a lock is
    /// the one thing that cannot go in an IOProc.
    private var lastFedTicks: UInt64 = 0

    /// False when the meter has not been fed for two seconds, which covers every
    /// reason that can happen: the callbacks stopping (the bound device sleeping
    /// or being unplugged, the HAL rebuilding, a format change nobody listened
    /// for) and callbacks that measure nothing. Without it the menu bar went on
    /// showing the last number measured, which looks like an answer. Not a sign
    /// that the callbacks stopped: they may be arriving and returning early.
    var isDelivering: Bool {
        // The stamp is read once, before the clock, and the difference is floored
        // at zero: read the other way round, a newer stamp landing between the two
        // reads makes the unsigned subtraction go negative, which traps (measured
        // in LUFSBar Pro, tests/isdelivering_race.swift there).
        let last = lastFedTicks
        guard last != 0 else { return false }
        let now = mach_absolute_time()
        let elapsed = Double(now > last ? now - last : 0) * Self.nanosecondsPerTick
        return elapsed < 2_000_000_000
    }

    /// LUFSBAR_STALL_AFTER_SECONDS = n: test only. n seconds after the first
    /// callback, the IOProc stops feeding the meter and stops stamping, which is
    /// what it looks like from here when the bound device sleeps or is unplugged.
    /// Counted from the first callback rather than the tap's start, because the
    /// device can take seconds to start playing.
    /// LUFSBAR_STALL_FOR_SECONDS = m: and resumes after m seconds (default: never).
    private var stallAfterTicks: UInt64 = 0
    private var stallForTicks: UInt64 = 0
    private var stallAtTicks: UInt64 = 0

    private static let nanosecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    /// Allocated once: the IO thread does not wait on an allocator. A buffer
    /// with more frames than fit is measured in pieces.
    private static let scratchFrames = 4096
    private var interleaveScratch = [Float32](repeating: 0, count: scratchFrames * 2)

    private struct OutputDevice: Equatable {
        let id: AudioObjectID
        let uid: String
    }

    /// The default output as read from the HAL: none at all, a device, or
    /// unreadable: a device that did not give its UID (which happens for a moment
    /// while it reconfigures), or, with kAudioObjectUnknown, a read of which
    /// device is the default that failed outright. Unreadable is a failed build
    /// to try again, not a reason to wait: nothing would tell the app to look
    /// again.
    private enum DefaultOutput: Equatable {
        case none
        case device(OutputDevice)
        case unreadable(AudioObjectID)

        var name: String {
            switch self {
            case .none: return "nothing"
            case .device(let device): return device.uid
            case .unreadable(let id): return id == kAudioObjectUnknown ? "unreadable" : "object \(id), UID unreadable"
            }
        }
    }

    // The default output the tap was last built, or tried, on, so the listener
    // can tell a change of default output that matters from the bursts of
    // notifications that do not. The object ID is compared as well as the UID: a
    // driver that reloads, or a device that comes back from sleep, can return
    // under the same UID as a new object, and a tap bound to the old one
    // delivers nothing. Kept when the build fails too: the retry schedule tries
    // again, and a notification that names the same device leaves it alone.
    // (It used to be cleared then, and every notification of a burst started
    // the retries over, so the access panel never came.)
    private var attemptedOutput: DefaultOutput?

    // Listener that rebuilds the tap on the new device whenever the default output
    // changes. It has to be retained, or stop() cannot remove it with the right block.
    private var defaultOutputDeviceListener: AudioObjectPropertyListenerBlock?

    /// Where the device's stereo pair sits: the output stream that holds each
    /// side, the channel within it (zero-based), and how many channels that
    /// stream has. Usually both sides are in one stream, and one tap is bound
    /// to it; when they are in two (Configure Speakers 2-3 on a device whose
    /// streams are 2 and 10 channels wide, or a device of mono streams), a tap
    /// is bound to each.
    private struct StereoPair: Equatable {
        var leftStream = 0
        var left = 0
        var rightStream = 0
        var right = 1
        var leftStreamChannels = 2
        var rightStreamChannels = 2
        var spansStreams: Bool { leftStream != rightStream }
    }
    private var stereoPair = StereoPair()
    /// The bound device's nominal sample rate when the tap was built. The device
    /// can change rate and stay the same object, so no default output change
    /// says so; before this was watched (and in 1.1), 96 kHz audio went on
    /// feeding a meter built for 48 kHz and read M -18.7, TP -17.2 for a -18.0 tone.
    private var boundSampleRate: Float64 = 0
    // Rebuilds the tap when the bound device's stereo pair (Audio MIDI Setup), its
    // sample rate or its output streams change. Belongs to one device, so it is
    // removed with the tap.
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var deviceListenerDevice = AudioObjectID(kAudioObjectUnknown)

    private static var stereoPairAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var sampleRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    // The stream holding the stereo pair can move when the device changes its
    // output streams at the same rate (an interface's I/O mode, a display's
    // channel count); stereoPair(of:) gives the stream, so the comparison sees it.
    private static var streamConfigurationAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    /// Every address the device listener is added to, and removed from.
    private static var deviceListenerAddresses: [AudioObjectPropertyAddress] {
        [stereoPairAddress, sampleRateAddress, streamConfigurationAddress]
    }

    private static var defaultOutputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )


    func start() {
        // A second start would overwrite tapID and aggregateID, leaking the tap that
        // is running, and change what its IOProc reads while it runs.
        stopTap()
        if defaultOutputDeviceListener == nil {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                // These arrive in bursts (plugging a display in sends dozens), so
                // nothing is rebuilt unless the default output really moved.
                let output = Self.defaultOutput()
                guard output != self.attemptedOutput else { return }
                Self.log.notice("default output device changed: rebuilding the tap on \(output.name, privacy: .public)")
                // Sample rate and channel count can differ per device, so the tap
                // and the LoudnessMeter are both built again for the new one.
                self.rebuild()
            }
            defaultOutputDeviceListener = listener
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputDeviceAddress, DispatchQueue.main, listener
            )
        }
        // Test switches, read here on the main thread before the IOProc exists,
        // so the audio thread never sets up a static or reads the environment.
        // These two are the ones the IOProc uses (tests/realtime.sh 6).
        _ = Self.meterHoldMicroseconds
        _ = Self.meterRequestDelay
        stallAfterTicks = 0
        stallForTicks = 0
        if let seconds = TestSwitch.number("LUFSBAR_STALL_AFTER_SECONDS", limit: 86_400) {
            stallAfterTicks = UInt64(seconds * 1_000_000_000 / Self.nanosecondsPerTick)
            if let resume = TestSwitch.number("LUFSBAR_STALL_FOR_SECONDS", limit: 86_400) {
                stallForTicks = UInt64(resume * 1_000_000_000 / Self.nanosecondsPerTick)
            }
            Self.log.error("stalling on purpose \(seconds) s after the first callback")
        }
        rebuild()

        meterDropTimer?.invalidate()
        meterDropTimer = nil
        levelLogTimer?.invalidate()
        // In the common modes, like the polling in MeterState, so it goes on while
        // a menu is open.
        let levelLog = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.logMeterLevels()
        }
        RunLoop.main.add(levelLog, forMode: .common)
        levelLogTimer = levelLog
        meterPoll?.invalidate()
        let poll = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.serviceMeterRequest()
        }
        RunLoop.main.add(poll, forMode: .common)
        meterPoll = poll
        // LUFSBAR_DROP_METER_EVERY_MS = n: test only. Lets go of the meter every
        // n ms the way a device change does, so the next callback needs a new
        // one. Used with LUFSBAR_METER_HOLD_MS.
        if let ms = TestSwitch.number("LUFSBAR_DROP_METER_EVERY_MS", limit: 60_000) {
            Self.log.error("dropping the meter on purpose every \(ms) ms")
            meterDropTimer = Timer.scheduledTimer(withTimeInterval: ms / 1000, repeats: true) { [weak self] _ in
                self?.setLoudnessMeter(nil)
            }
        }
    }

    /// Failed builds in a row, however each was asked for, and back to 0 once a
    /// tap starts. (It used to wait for a meter, which only comes once audio
    /// plays, so on a Mac playing nothing to the default output the failures
    /// of one episode were still counted in the next, hours later, and one
    /// hiccup on an output switch brought the panel and a long wait.) A meter
    /// that cannot be built is counted apart, in meterFailures.
    private var failures = 0
    /// The access panel comes with this many failures in a row (about 3 s).
    private static let failuresBeforePanel = 4
    /// Seconds before the next attempt, by failure; the last one repeats. The
    /// attempts go on behind the panel, further and further apart: the usual
    /// cause is the device itself (still reconfiguring after a rate or stream
    /// change, waking, going away), which passes, and building and tearing down
    /// a tap notifies every audio app on the Mac, so not every second for good.
    /// Before 1.1.1, one failure left metering dead until the default output
    /// changed, behind a panel that blamed the permission.
    private static let retryDelays: [TimeInterval] = [1, 1, 1, 5, 10, 30, 60]
    private var startRetry: Timer?

    private enum StartResult { case started, waiting, failed }

    /// Every build of the tap comes through here: start(), a change of default
    /// output, a change on the bound device, and a retry. One place keeps the
    /// count of failures, so no caller can start it over, and only a failed
    /// build schedules a retry, so there is never more than one.
    private func rebuild() {
        startRetry?.invalidate()
        startRetry = nil
        stopTap()
        switch startTap() {
        case .failed:
            noteFailure()
        case .started, .waiting:
            // Nothing is failing any more: a tap is running, or there is no
            // output to build one on (and a new one wakes the listener). The
            // count starts again, and a panel blaming the build goes. (On
            // .waiting both used to stay, and the next episode inherited them.)
            failures = 0
            MeterState.shared.clearAudioAccessError()
        }
    }

    /// Counts a failed build, shows the panel once there have been enough, and
    /// schedules the next attempt. Main thread only.
    private func noteFailure() {
        failures += 1
        if failures >= Self.failuresBeforePanel {
            MeterState.shared.reportAudioAccessError()
        }
        let delay = Self.retryDelays[min(failures, Self.retryDelays.count) - 1]
        Self.log.notice("trying again in \(delay) s (\(self.failures) failed in a row)")
        startRetry?.invalidate()
        // In the common modes, like everything else that keeps the meter going
        // while a menu is open.
        let retry = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.rebuild()
        }
        RunLoop.main.add(retry, forMode: .common)
        startRetry = retry
    }

    /// Builds the tap on the default output. Only through rebuild(), which tears
    /// the last one down first.
    private func startTap() -> StartResult {
        generation &+= 1
        // Test only: a rebuilt tap waits its own n seconds before stalling.
        stallAtTicks = 0
        // Bound to the default output's stream rather than tapping everything.
        //
        // A global tap averages every channel of the device into one stereo pair,
        // so the level drops by the number of pairs, and which device that is
        // cannot be known when applications play to different ones. 1.1 guessed
        // it from the default output and read 14 dB low with a DAW playing to a
        // ten channel interface while the Mac's output was the built-in
        // speakers. Bound, the tap carries that one device at its own channel
        // count, at the source's level, with nothing to correct.
        // The trade-off: audio sent to any other device is not measured at all.
        Self.startTapCalls += 1
        var output = Self.defaultOutput(failingTheRead: Self.shouldFail(at: "defaultdevice"))
        if Self.noOutputAttempt == Self.startTapCalls {
            Self.log.error("reading no default output on purpose")
            output = .none
        }
        if case .device(let device) = output, Self.shouldFail(at: "uid") {
            output = .unreadable(device.id)
        }
        attemptedOutput = output
        let device: OutputDevice
        switch output {
        case .none:
            // Nothing to measure until an output appears, and when one does the
            // listener sees the default output change and builds the tap then.
            Self.log.notice("no default output device; waiting for one")
            return .waiting
        case .unreadable(let id):
            if id == kAudioObjectUnknown {
                Self.log.error("the default output could not be read")
            } else {
                Self.log.error("the default output (object \(id)) did not give its UID")
            }
            return .failed
        case .device(let found):
            device = found
        }
        let boundUID = device.uid

        // Every way of giving up below tears down whatever was already built,
        // because the next attempt overwrites tapID and aggregateID and would
        // otherwise leak them.
        var started = false
        defer {
            if !started {
                Self.log.error("start gave up part way; tearing the tap back down")
                stopTap()
            }
        }

        // macOS plays stereo to the pair set in Audio MIDI Setup > Configure
        // Speakers, which is 1-2 unless someone changed it, so that is the pair
        // measured. Set here, before the IOProc exists, and not touched again
        // until stopTap() has stopped it.
        let pair = Self.stereoPair(of: device.id)
        stereoPair = pair
        guard let rate = Self.nominalSampleRate(of: device.id) else {
            Self.log.error("the default output did not give its sample rate")
            return .failed
        }
        boundSampleRate = rate
        listenForDeviceChanges(on: device.id)

        // One tap per stream the pair is in: one, unless the pair spans two.
        func describeTap(stream: Int) -> CATapDescription {
            let description = CATapDescription()
            // Mixdown off: with it on, a device-bound tap delivers the right peaks
            // but half the energy, which is not a waveform to measure loudness on.
            description.isMixdown = false
            description.isMono = false
            description.deviceUID = boundUID
            // Required. Left unset, the tap is created without complaint and then
            // never delivers a callback.
            description.stream = UInt(stream)
            description.isExclusive = true
            description.processes = []
            description.name = "LUFSBar System Tap"
            description.muteBehavior = .unmuted
            description.isPrivate = true
            return description
        }
        if pair.spansStreams {
            Self.log.notice("measuring everything on \(boundUID, privacy: .public) (left: stream \(pair.leftStream) channel \(pair.left + 1), right: stream \(pair.rightStream) channel \(pair.right + 1))")
        } else {
            Self.log.notice("measuring everything on \(boundUID, privacy: .public) (stream \(pair.leftStream), channels \(pair.left + 1)-\(pair.right + 1))")
        }
        let description = describeTap(stream: pair.leftStream)
        tapDescription = description

        var newTapID: AudioObjectID = kAudioObjectUnknown
        let tapErr = Self.shouldFail(at: "tap") ? kAudioHardwareUnspecifiedError : AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapErr == noErr else {
            Self.log.error("failed to create the tap (OSStatus \(tapErr))")
            return .failed
        }
        tapID = newTapID
        Self.log.notice("tap created id=\(self.tapID)")
        var subTaps: [[String: Any]] = [
            [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
        ]
        if pair.spansStreams {
            let rightDescription = describeTap(stream: pair.rightStream)
            var rightTapID: AudioObjectID = kAudioObjectUnknown
            let rightErr = AudioHardwareCreateProcessTap(rightDescription, &rightTapID)
            guard rightErr == noErr else {
                Self.log.error("failed to create the tap for the right channel's stream (OSStatus \(rightErr))")
                return .failed
            }
            secondTapID = rightTapID
            Self.log.notice("tap created id=\(self.secondTapID) (right channel's stream)")
            subTaps.append([kAudioSubTapUIDKey: rightDescription.uuid.uuidString, kAudioSubTapDriftCompensationKey: true])
            guard let route = Self.spanRoute(pair: pair, leftTap: tapID, rightTap: rightTapID) else {
                return .failed
            }
            spanRoute = route
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LUFSBar-Tap-Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: subTaps
        ]

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        let aggErr = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        if aggErr == noErr { aggregateID = newAggregateID }
        guard aggErr == noErr, !Self.shouldFail(at: "aggregate") else {
            Self.log.error("failed to create the aggregate device (OSStatus \(aggErr))")
            return .failed
        }
        Self.log.notice("aggregate device created id=\(self.aggregateID)")

        var newIOProcID: AudioDeviceIOProcID?
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateID, nil) { [weak self] _, inInputData, _, _, _ in
            self?.handleAudio(inInputData)
        }
        if ioErr == noErr, let newIOProcID { ioProcID = newIOProcID }
        guard ioErr == noErr, let newIOProcID, !Self.shouldFail(at: "ioproc") else {
            Self.log.error("failed to create the IOProc (OSStatus \(ioErr))")
            return .failed
        }

        let startErr = Self.shouldFail(at: "devicestart") ? kAudioHardwareUnspecifiedError : AudioDeviceStart(aggregateID, newIOProcID)
        guard startErr == noErr else {
            Self.log.error("AudioDeviceStart failed (OSStatus \(startErr))")
            return .failed
        }
        started = true
        Self.log.notice("capture started")
        return .started
    }

    func stop() {
        if let listener = defaultOutputDeviceListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputDeviceAddress, DispatchQueue.main, listener
            )
            defaultOutputDeviceListener = nil
        }
        meterDropTimer?.invalidate()
        meterDropTimer = nil
        levelLogTimer?.invalidate()
        levelLogTimer = nil
        meterPoll?.invalidate()
        meterPoll = nil
        startRetry?.invalidate()
        startRetry = nil
        stopTap()
    }

    private func stopTap() {
        if let listener = deviceListener {
            for var address in Self.deviceListenerAddresses {
                AudioObjectRemovePropertyListenerBlock(deviceListenerDevice, &address, nil, listener)
            }
            deviceListener = nil
            deviceListenerDevice = AudioObjectID(kAudioObjectUnknown)
        }
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        // The IOProc has stopped, so nothing stamps this until the next tap runs.
        lastFedTicks = 0
        if aggregateID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            Self.log.notice("aggregate device destroyed id=\(self.aggregateID) (OSStatus \(status))")
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            Self.log.notice("tap destroyed id=\(self.tapID) (OSStatus \(status))")
            tapID = kAudioObjectUnknown
        }
        if secondTapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(secondTapID)
            Self.log.notice("tap destroyed id=\(self.secondTapID) (OSStatus \(status))")
            secondTapID = kAudioObjectUnknown
        }
        spanRoute = nil
        setLoudnessMeter(nil)
        // A request not taken up yet belongs to this tap and goes with it; one
        // that failed left the flag up on purpose. Either way the next tap may
        // ask again.
        meterRetry?.invalidate()
        meterRetry = nil
        meterFailures = 0
        os_unfair_lock_lock(loudnessMeterLock)
        let dropped = pendingMeterRequest != nil
        pendingMeterRequest = nil
        isBuildingLoudnessMeter = false
        os_unfair_lock_unlock(loudnessMeterLock)
        if dropped { Self.log.notice("dropping a meter request from an earlier tap") }
    }

    /// Resets the Integrated measurement (MeterState, after silence or a stall).
    func resetIntegrated() {
        loudnessMeter?.resetIntegrated()
    }

    private func listenForDeviceChanges(on device: AudioObjectID) {
        // Delivered on Core Audio's own thread (no queue) and handed to the main
        // run loop in the common modes, so it is acted on while a menu is
        // tracking too. Not rebuilt from inside the callback, since the rebuild
        // removes this very listener.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
                guard let self, self.deviceListenerDevice == device else { return }
                // Read back and compared, so a burst of notifications, or a rate
                // that went somewhere and came back before this ran, does nothing.
                let pairChanged = Self.stereoPair(of: device) != self.stereoPair
                // A rate that cannot be read in the middle of a burst says
                // nothing; if it did change, a later notification shows it.
                let rate = Self.nominalSampleRate(of: device)
                let rateChanged = rate.map { $0 != self.boundSampleRate } ?? false
                guard pairChanged || rateChanged else { return }
                if pairChanged { Self.log.notice("stereo pair changed: rebuilding the tap") }
                if rateChanged { Self.log.notice("sample rate changed from \(self.boundSampleRate) to \(rate ?? 0) Hz: rebuilding the tap") }
                self.rebuild()
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        var listening = false
        for var address in Self.deviceListenerAddresses {
            let status = AudioObjectAddPropertyListenerBlock(device, &address, nil, listener)
            if status == noErr {
                listening = true
            } else {
                Self.log.error("no listener on the device's property \(address.mSelector) (OSStatus \(status)); changes to it will not be followed")
            }
        }
        guard listening else { return }
        deviceListener = listener
        deviceListenerDevice = device
    }

    /// The device's stereo pair (Audio MIDI Setup > Configure Speakers), as the
    /// output stream that holds each side and the channel within it. The pair
    /// is numbered across all of the device's output streams, so it is walked
    /// stream by stream. Channels 1-2 of the first stream when the pair cannot
    /// be read or a side is in no stream. (A pair across two streams used to
    /// fall back to that too, and a tone read 3 dB low: tests/streams.sh 2.)
    private static func stereoPair(of device: AudioObjectID) -> StereoPair {
        var channels: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        if AudioObjectGetPropertyData(device, &stereoPairAddress, 0, nil, &size, &channels) != noErr {
            channels = [1, 2]
        }
        let left = Int(channels[0]) - 1
        let right = Int(channels[1]) - 1

        // The address the device listener watches, so what triggers a rebuild
        // and what is compared cannot drift apart.
        var address = streamConfigurationAddress
        var dataSize: UInt32 = 0
        guard left >= 0, right >= 0,
              AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return StereoPair()
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, raw) == noErr else { return StereoPair() }

        var first = 0
        var found = StereoPair()
        var foundLeft = false, foundRight = false
        for (stream, buffer) in UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).enumerated() {
            let channels = Int(buffer.mNumberChannels)
            let range = first..<(first + channels)
            if range.contains(left) {
                found.leftStream = stream; found.left = left - first; found.leftStreamChannels = channels
                foundLeft = true
            }
            if range.contains(right) {
                found.rightStream = stream; found.right = right - first; found.rightStreamChannels = channels
                foundRight = true
            }
            first = range.upperBound
        }
        guard foundLeft, foundRight else { return StereoPair() }
        return found
    }

    /// The Mac's current default output. `failingTheRead` is the test switch
    /// (LUFSBAR_FAIL_START_AT = defaultdevice).
    private static func defaultOutput(failingTheRead: Bool = false) -> DefaultOutput {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var deviceIDSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let deviceErr = failingTheRead ? kAudioHardwareUnspecifiedError : AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutputDeviceAddress, 0, nil, &deviceIDSize, &deviceID
        )
        // A read that fails is not "no output": nothing would tell the app to
        // look again, so it is a failed build, tried again on the schedule.
        guard deviceErr == noErr else { return .unreadable(AudioObjectID(kAudioObjectUnknown)) }
        guard deviceID != kAudioObjectUnknown else { return .none }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
              let uid else { return .unreadable(deviceID) }
        return .device(OutputDevice(id: deviceID, uid: uid.takeRetainedValue() as String))
    }

    private func nominalSampleRate() -> Float64? {
        Self.nominalSampleRate(of: aggregateID)
    }

    /// A device's nominal sample rate, or nil when it cannot be read or is not
    /// a rate. (It used to answer 48000 then, and a meter built for 48 kHz read
    /// 96 kHz audio wrong.)
    private static func nominalSampleRate(of device: AudioObjectID) -> Float64? {
        var sampleRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &sampleRateAddress, 0, nil, &size, &sampleRate) == noErr,
              sampleRate.isFinite, sampleRate > 0 else { return nil }
        return sampleRate
    }

    /// A tap's stream format, or nil when it cannot be read.
    private static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr,
              format.mChannelsPerFrame > 0 else { return nil }
        return format
    }

    /// Where each side of a pair across two streams arrives in the IOProc: the
    /// left tap's buffers come first, then the right one's, each either one
    /// interleaved buffer or one buffer per channel, as its format says (or,
    /// when the format cannot be read, one interleaved buffer as wide as the
    /// stream, which is what the taps deliver). The IOProc checks what it gets
    /// against this and measures nothing if it differs, so a wrong guess shows
    /// "--", never a wrong figure. Nil, after a log line, when a tap delivers
    /// something other than 32-bit float, which is all the IOProc reads.
    private static func spanRoute(pair: StereoPair, leftTap: AudioObjectID, rightTap: AudioObjectID) -> SpanRoute? {
        func layout(_ tap: AudioObjectID, streamChannels: Int) -> (channels: Int, separate: Bool)? {
            guard let format = tapFormat(tap) else { return (streamChannels, false) }
            let isFloat32 = format.mFormatID == kAudioFormatLinearPCM
                && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
            guard isFloat32 else {
                log.error("a tap delivers a format the meter cannot read (flags \(format.mFormatFlags), \(format.mBitsPerChannel) bits)")
                return nil
            }
            return (Int(format.mChannelsPerFrame), format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0)
        }
        guard let left = layout(leftTap, streamChannels: pair.leftStreamChannels),
              let right = layout(rightTap, streamChannels: pair.rightStreamChannels),
              pair.left < left.channels, pair.right < right.channels else { return nil }
        let leftBuffers = left.separate ? left.channels : 1
        let rightBuffers = right.separate ? right.channels : 1
        return SpanRoute(
            buffers: leftBuffers + rightBuffers,
            leftBuffer: left.separate ? pair.left : 0,
            leftOffset: left.separate ? 0 : pair.left,
            leftStride: left.separate ? 1 : left.channels,
            rightBuffer: leftBuffers + (right.separate ? pair.right : 0),
            rightOffset: right.separate ? 0 : pair.right,
            rightStride: right.separate ? 1 : right.channels
        )
    }

    /// How many channels the tap delivers: the bound device stream's own count
    /// (ten on a ten output interface), in one interleaved buffer or one buffer
    /// per channel.
    private static func availableChannels(in abl: UnsafeMutableAudioBufferListPointer) -> Int {
        abl.count == 1 ? Int(abl.first?.mNumberChannels ?? 0) : abl.count
    }

    /// The channels measured, as positions in what the tap delivers: the
    /// device's stereo pair, or channels 1-2 if the pair is no longer inside the
    /// stream (it is re-read whenever the tap is built), or the one channel of a
    /// mono device. No array, because this runs on the IO thread.
    private func measuredChannels(available: Int) -> (count: Int, left: Int, right: Int) {
        guard available >= 2 else { return (available, 0, 0) }
        let pair = stereoPair
        guard pair.left < available, pair.right < available else { return (2, 0, 1) }
        return (2, pair.left, pair.right)
    }

    private func handleAudio(_ bufferList: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard abl.count > 0 else { return }
        // Test only: behaves as though the callbacks had stopped coming.
        if stallAfterTicks != 0 {
            let now = mach_absolute_time()
            if stallAtTicks == 0 { stallAtTicks = now + stallAfterTicks }
            if now > stallAtTicks && (stallForTicks == 0 || now < stallAtTicks + stallForTicks) { return }
        }

        if let route = spanRoute {
            handleSpanningPair(abl, route)
            return
        }

        let available = Self.availableChannels(in: abl)
        let (measured, left, right) = measuredChannels(available: available)
        guard measured > 0 else { return }

        guard let meter = loudnessMeter else {
            requestLoudnessMeter(channels: measured, replacing: false, tapChannels: available, buffers: abl.count)
            return
        }
        // The meter reads `channels` samples per frame. If the device changed its
        // layout under the same tap, feeding it the new layout would make it read
        // past what was copied, so a meter for the new one is asked for instead.
        guard measured == Int(meter.channels) else {
            requestLoudnessMeter(channels: measured, replacing: true, tapChannels: available, buffers: abl.count)
            return
        }
        if Self.meterHoldMicroseconds > 0 { usleep(Self.meterHoldMicroseconds) }

        // The measured channels are copied into scratch, interleaved, a piece at
        // a time if the buffer holds more frames than the scratch does. Either
        // one interleaved buffer carrying every channel of the stream, or one
        // buffer per channel (measuredChannels keeps left and right below
        // abl.count).
        let interleaved = abl.count == 1
        let channelStride = interleaved ? available : 1
        let leftBuffer = interleaved ? abl[0] : abl[left]
        let rightBuffer = interleaved ? abl[0] : abl[right]
        guard let leftData = leftBuffer.mData, let rightData = rightBuffer.mData else { return }
        let frameCount = min(
            Int(leftBuffer.mDataByteSize) / (MemoryLayout<Float32>.size * channelStride),
            Int(rightBuffer.mDataByteSize) / (MemoryLayout<Float32>.size * channelStride)
        )
        guard frameCount > 0 else { return }
        let leftSamples = leftData.assumingMemoryBound(to: Float32.self) + (interleaved ? left : 0)
        let rightSamples = rightData.assumingMemoryBound(to: Float32.self) + (interleaved ? right : 0)

        interleaveScratch.withUnsafeMutableBufferPointer { scratch in
            guard let dst = scratch.baseAddress else { return }
            var done = 0
            while done < frameCount {
                let frames = min(frameCount - done, Self.scratchFrames)
                for frame in 0..<frames {
                    let source = (done + frame) * channelStride
                    dst[frame * measured] = leftSamples[source]
                    if measured == 2 {
                        dst[frame * 2 + 1] = rightSamples[source]
                    }
                }
                meter.addInterleavedFrames(dst, frameCount: frames)
                done += frames
            }
        }
        // Here, once the meter has been fed (see lastFedTicks).
        lastFedTicks = mach_absolute_time()
    }

    /// handleAudio for a stereo pair across two streams: one side from each
    /// tap's buffers, where spanRoute says. Anything other than the layout it
    /// expects is not measured (the menu bar goes to "--").
    private func handleSpanningPair(_ abl: UnsafeMutableAudioBufferListPointer, _ route: SpanRoute) {
        guard abl.count == route.buffers else { return }
        let leftBuffer = abl[route.leftBuffer], rightBuffer = abl[route.rightBuffer]
        guard Int(leftBuffer.mNumberChannels) == route.leftStride, Int(rightBuffer.mNumberChannels) == route.rightStride,
              let leftData = leftBuffer.mData, let rightData = rightBuffer.mData else { return }
        let tapChannels = route.leftStride + route.rightStride
        guard let meter = loudnessMeter else {
            requestLoudnessMeter(channels: 2, replacing: false, tapChannels: tapChannels, buffers: abl.count)
            return
        }
        guard meter.channels == 2 else {
            requestLoudnessMeter(channels: 2, replacing: true, tapChannels: tapChannels, buffers: abl.count)
            return
        }
        if Self.meterHoldMicroseconds > 0 { usleep(Self.meterHoldMicroseconds) }
        let frameCount = min(
            Int(leftBuffer.mDataByteSize) / (MemoryLayout<Float32>.size * route.leftStride),
            Int(rightBuffer.mDataByteSize) / (MemoryLayout<Float32>.size * route.rightStride)
        )
        guard frameCount > 0 else { return }
        let leftSamples = leftData.assumingMemoryBound(to: Float32.self) + route.leftOffset
        let rightSamples = rightData.assumingMemoryBound(to: Float32.self) + route.rightOffset
        interleaveScratch.withUnsafeMutableBufferPointer { scratch in
            guard let dst = scratch.baseAddress else { return }
            var done = 0
            while done < frameCount {
                let frames = min(frameCount - done, Self.scratchFrames)
                for frame in 0..<frames {
                    dst[frame * 2] = leftSamples[(done + frame) * route.leftStride]
                    dst[frame * 2 + 1] = rightSamples[(done + frame) * route.rightStride]
                }
                meter.addInterleavedFrames(dst, frameCount: frames)
                done += frames
            }
        }
        lastFedTicks = mach_absolute_time()
    }
}
