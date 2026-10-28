import Foundation
import CoreAudio
import os

/// The LUFSBAR_* test switches, read in one place: a positive, finite value no
/// larger than `limit`, or nil, so a typo cannot reach a conversion that traps.
enum TestSwitch {
    static func number(_ name: String, limit: Double) -> Double? {
        guard let raw = ProcessInfo.processInfo.environment[name],
              let value = Double(raw), value.isFinite, value > 0 else { return nil }
        return min(value, limit)
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
    /// LUFSBAR_FAIL_START_AT = tap | aggregate | ioproc | devicestart
    /// LUFSBAR_FAIL_START_TIMES = n: only the first n attempts fail (default: all).
    private static let failStartAt = ProcessInfo.processInfo.environment["LUFSBAR_FAIL_START_AT"]
    private static var failStartsLeft: Int? =
        TestSwitch.number("LUFSBAR_FAIL_START_TIMES", limit: 1000).map { Int($0) }
    private static func shouldFail(at point: String) -> Bool {
        guard failStartAt == point else { return false }
        if let left = failStartsLeft {
            guard left > 0 else { return false }
            failStartsLeft = left - 1
        }
        log.error("failing on purpose at \(point, privacy: .public)")
        return true
    }

    private var tapID: AudioObjectID = kAudioObjectUnknown
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
    /// Set while a meter is being built on the main thread, under the same lock,
    /// so a second callback does not ask for a second one.
    private var isBuildingLoudnessMeter = false

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
    /// rate, and this is called from the IOProc. Metering waits the two or
    /// three buffers the answer takes. With `replacing`, the current meter is
    /// swapped for the new one (the tap's layout changed under it).
    private func requestLoudnessMeter(channels: Int, replacing: Bool, tapChannels: Int, buffers: Int) {
        os_unfair_lock_lock(loudnessMeterLock)
        let alreadyAsked = isBuildingLoudnessMeter
        isBuildingLoudnessMeter = true
        os_unfair_lock_unlock(loudnessMeterLock)
        guard !alreadyAsked else { return }
        // Through the main run loop in the common modes rather than the main
        // dispatch queue: while the right-click menu is open the queue is not
        // served, and the meter was only built once the menu closed. The CF call,
        // because it is the one documented as safe from any thread.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            // The tap can be torn down while this is queued, and a meter put in
            // afterwards would show figures nothing is feeding. stopTap() has
            // already lowered the flag in that case.
            guard self.ioProcID != nil else { return }
            let sampleRate = UInt32(self.nominalSampleRate())
            // ebur128_init only fails on a nonsense sample rate or a failed
            // malloc. If it does, the flag stays up: lowering it would have the
            // next callback ask again, a hundred times a second. stopTap()
            // lowers it, so the next tap tries again.
            guard let meter = LoudnessMeter(sampleRate: sampleRate, channels: UInt32(channels)) else {
                Self.log.error("the meter could not be built at \(sampleRate) Hz; not trying again until the tap is rebuilt")
                return
            }
            os_unfair_lock_lock(self.loudnessMeterLock)
            // Only into an empty place, unless asked to replace: a request left
            // over from before a rebuild can land after the new tap has one.
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
            Self.log.notice("LoudnessMeter init sampleRate=\(sampleRate) channels=\(channels) of tapChannels=\(tapChannels) buffers=\(buffers) on the \(Thread.isMainThread ? "main" : "audio", privacy: .public) thread")
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
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

    /// When the IOProc last ran, so the display can tell a reading that is current
    /// from one that stopped being fed. Written on the audio thread and read on
    /// the main one without a lock: an aligned 64 bit store is a single
    /// instruction here, and a lock is the one thing that cannot go in an IOProc.
    private var lastCallbackTicks: UInt64 = 0

    /// False when nothing has arrived for two seconds, which covers every reason
    /// the callbacks can stop: the bound device sleeping or being unplugged, the
    /// HAL rebuilding, a format change nobody listened for. Without it the menu
    /// bar went on showing the last number measured, which looks like an answer.
    var isDelivering: Bool {
        // The stamp is read once, before the clock, and the difference is floored
        // at zero: read the other way round, a newer stamp landing between the two
        // reads makes the unsigned subtraction go negative, which traps (measured
        // in LUFSBar Pro, tests/isdelivering_race.swift there).
        let last = lastCallbackTicks
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

    // The device the tap is bound to, so the listener can tell a change of
    // default output that matters from the bursts of notifications that do not.
    // The object ID is compared as well as the UID: a driver that reloads, or a
    // device that comes back from sleep, can return under the same UID as a new
    // object, and a tap bound to the old one delivers nothing.
    // nil until a tap has been fully built, so a failed build is retried by the
    // next notification instead of being taken for "nothing moved".
    private var boundDevice: OutputDevice?

    // Listener that rebuilds the tap on the new device whenever the default output
    // changes. It has to be retained, or stop() cannot remove it with the right block.
    private var defaultOutputDeviceListener: AudioObjectPropertyListenerBlock?

    /// Where the device's stereo pair sits: which output stream the tap is bound
    /// to, and the two channels within it (zero-based).
    private struct StereoPair: Equatable {
        var stream = 0
        var left = 0
        var right = 1
    }
    private var stereoPair = StereoPair()
    /// The bound device's nominal sample rate when the tap was built. The device
    /// can change rate and stay the same object, so no default output change
    /// says so; before this was watched (and in 1.1), 96 kHz audio went on
    /// feeding a meter built for 48 kHz and read M -18.7, TP -17.2 for a -18.0 tone.
    private var boundSampleRate: Float64 = 0
    // Rebuilds the tap when the bound device's stereo pair (Audio MIDI Setup) or
    // its sample rate changes. Belongs to one device, so it is removed with the tap.
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
                let newDevice = Self.defaultOutputDevice()
                guard newDevice != self.boundDevice else { return }
                Self.log.notice("default output device changed: rebuilding the tap on \(newDevice?.uid ?? "nothing", privacy: .public)")
                // Sample rate and channel count can differ per device, so the tap
                // and the LoudnessMeter are both built again for the new one.
                self.stopTap()
                self.startTap()
            }
            defaultOutputDeviceListener = listener
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputDeviceAddress, DispatchQueue.main, listener
            )
        }
        // Test switches, read here on the main thread before the IOProc exists,
        // so the audio thread never sets up a static or reads the environment.
        _ = Self.meterHoldMicroseconds
        stallAfterTicks = 0
        stallForTicks = 0
        if let seconds = TestSwitch.number("LUFSBAR_STALL_AFTER_SECONDS", limit: 86_400) {
            stallAfterTicks = UInt64(seconds * 1_000_000_000 / Self.nanosecondsPerTick)
            if let resume = TestSwitch.number("LUFSBAR_STALL_FOR_SECONDS", limit: 86_400) {
                stallForTicks = UInt64(resume * 1_000_000_000 / Self.nanosecondsPerTick)
            }
            Self.log.error("stalling on purpose \(seconds) s after the first callback")
        }
        startTap()

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

    private func startTap() {
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
        boundDevice = nil
        guard let device = Self.defaultOutputDevice() else {
            // Nothing to measure until an output appears, and when one does the
            // listener sees the default output change and builds the tap then.
            Self.log.notice("no default output device; waiting for one")
            return
        }
        let boundUID = device.uid

        // Every way of giving up below tears down whatever was already built,
        // because the next attempt overwrites tapID and aggregateID and would
        // otherwise leak them.
        var started = false
        defer {
            if started {
                boundDevice = device
            } else {
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
        boundSampleRate = Self.nominalSampleRate(of: device.id)
        listenForDeviceChanges(on: device.id)

        let description = CATapDescription()
        // Mixdown off: with it on, a device-bound tap delivers the right peaks
        // but half the energy, which is not a waveform to measure loudness on.
        description.isMixdown = false
        description.isMono = false
        description.deviceUID = boundUID
        // Required. Left unset, the tap is created without complaint and then
        // never delivers a callback.
        description.stream = UInt(pair.stream)
        description.isExclusive = true
        description.processes = []
        Self.log.notice("measuring everything on \(boundUID, privacy: .public) (stream \(pair.stream), channels \(pair.left + 1)-\(pair.right + 1))")
        description.name = "LUFSBar System Tap"
        description.muteBehavior = .unmuted
        description.isPrivate = true
        tapDescription = description

        var newTapID: AudioObjectID = kAudioObjectUnknown
        let tapErr = Self.shouldFail(at: "tap") ? kAudioHardwareUnspecifiedError : AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapErr == noErr else {
            Self.log.error("failed to create the tap (OSStatus \(tapErr))")
            MeterState.shared.reportAudioAccessError()
            return
        }
        tapID = newTapID
        Self.log.notice("tap created id=\(self.tapID)")

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LUFSBar-Tap-Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        let aggErr = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        if aggErr == noErr { aggregateID = newAggregateID }
        guard aggErr == noErr, !Self.shouldFail(at: "aggregate") else {
            Self.log.error("failed to create the aggregate device (OSStatus \(aggErr))")
            MeterState.shared.reportAudioAccessError()
            return
        }
        Self.log.notice("aggregate device created id=\(self.aggregateID)")

        var newIOProcID: AudioDeviceIOProcID?
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateID, nil) { [weak self] _, inInputData, _, _, _ in
            self?.handleAudio(inInputData)
        }
        if ioErr == noErr, let newIOProcID { ioProcID = newIOProcID }
        guard ioErr == noErr, let newIOProcID, !Self.shouldFail(at: "ioproc") else {
            Self.log.error("failed to create the IOProc (OSStatus \(ioErr))")
            MeterState.shared.reportAudioAccessError()
            return
        }

        let startErr = Self.shouldFail(at: "devicestart") ? kAudioHardwareUnspecifiedError : AudioDeviceStart(aggregateID, newIOProcID)
        guard startErr == noErr else {
            Self.log.error("AudioDeviceStart failed (OSStatus \(startErr))")
            MeterState.shared.reportAudioAccessError()
            return
        }
        started = true
        Self.log.notice("capture started")
        MeterState.shared.clearAudioAccessError()
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
        stopTap()
    }

    private func stopTap() {
        if let listener = deviceListener {
            AudioObjectRemovePropertyListenerBlock(deviceListenerDevice, &Self.stereoPairAddress, nil, listener)
            AudioObjectRemovePropertyListenerBlock(deviceListenerDevice, &Self.sampleRateAddress, nil, listener)
            deviceListener = nil
            deviceListenerDevice = AudioObjectID(kAudioObjectUnknown)
        }
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        // The IOProc has stopped, so nothing stamps this until the next tap runs.
        lastCallbackTicks = 0
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
        setLoudnessMeter(nil)
        // A request still queued finds no IOProc and gives up; one that failed
        // left this up on purpose. Either way the next tap may ask again.
        os_unfair_lock_lock(loudnessMeterLock)
        isBuildingLoudnessMeter = false
        os_unfair_lock_unlock(loudnessMeterLock)
    }

    /// Resets the Integrated measurement (called from the reset button in the popover).
    func resetIntegrated() {
        loudnessMeter?.resetIntegrated()
    }

    private func listenForDeviceChanges(on device: AudioObjectID) {
        // Delivered on Core Audio's own thread (no queue) and handed to the main
        // run loop in the common modes, not the main dispatch queue: that queue
        // is not served while the right-click menu is open, and a rate change
        // made then went unnoticed until it closed, with the meter (which keeps
        // running under the menu) reading 96 kHz audio as 48 kHz meanwhile.
        // Not rebuilt from inside the callback either, since the rebuild
        // removes this very listener.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
                guard let self, self.deviceListenerDevice == device else { return }
                // Read back and compared, so a burst of notifications, or a rate
                // that went somewhere and came back before this ran, does nothing.
                let pairChanged = Self.stereoPair(of: device) != self.stereoPair
                let rate = Self.nominalSampleRate(of: device)
                let rateChanged = rate != self.boundSampleRate
                guard pairChanged || rateChanged else { return }
                if pairChanged { Self.log.notice("stereo pair changed: rebuilding the tap") }
                if rateChanged { Self.log.notice("sample rate changed from \(self.boundSampleRate) to \(rate) Hz: rebuilding the tap") }
                self.stopTap()
                self.startTap()
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        var listening = false
        for var address in [Self.stereoPairAddress, Self.sampleRateAddress] {
            let status = AudioObjectAddPropertyListenerBlock(device, &address, nil, listener)
            if status == noErr {
                listening = true
            } else {
                Self.log.error("no listener on the device's \(address.mSelector == kAudioDevicePropertyNominalSampleRate ? "sample rate" : "stereo pair", privacy: .public) (OSStatus \(status)); changes to it will not be followed")
            }
        }
        guard listening else { return }
        deviceListener = listener
        deviceListenerDevice = device
    }

    /// The device's stereo pair (Audio MIDI Setup > Configure Speakers), as the
    /// output stream that holds it and the two channels within that stream. The
    /// pair is numbered across all of the device's output streams, so it is
    /// walked stream by stream. Channels 1-2 of the first stream when the pair
    /// cannot be read, or when its two channels are not in the same stream.
    private static func stereoPair(of device: AudioObjectID) -> StereoPair {
        var channels: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        if AudioObjectGetPropertyData(device, &stereoPairAddress, 0, nil, &size, &channels) != noErr {
            channels = [1, 2]
        }
        let left = Int(channels[0]) - 1
        let right = Int(channels[1]) - 1

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard left >= 0, right >= 0,
              AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return StereoPair()
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, raw) == noErr else { return StereoPair() }

        var first = 0
        for (stream, buffer) in UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).enumerated() {
            let range = first..<(first + Int(buffer.mNumberChannels))
            if range.contains(left) && range.contains(right) {
                return StereoPair(stream: stream, left: left - first, right: right - first)
            }
            first = range.upperBound
        }
        return StereoPair()
    }

    /// The Mac's current default output device, or nil when there is none.
    private static func defaultOutputDevice() -> OutputDevice? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var deviceIDSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let deviceErr = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutputDeviceAddress, 0, nil, &deviceIDSize, &deviceID
        )
        guard deviceErr == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
              let uid else { return nil }
        return OutputDevice(id: deviceID, uid: uid.takeRetainedValue() as String)
    }

    private func nominalSampleRate() -> Double {
        Self.nominalSampleRate(of: aggregateID)
    }

    /// A device's nominal sample rate, or 48000 when it cannot be read.
    private static func nominalSampleRate(of device: AudioObjectID) -> Float64 {
        var sampleRate: Float64 = 48000
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(device, &sampleRateAddress, 0, nil, &size, &sampleRate)
        return sampleRate
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
        lastCallbackTicks = mach_absolute_time()

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
    }
}
