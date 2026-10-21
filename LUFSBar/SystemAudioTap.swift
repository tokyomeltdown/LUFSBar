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
    private static func shouldFail(at point: String) -> Bool {
        guard ProcessInfo.processInfo.environment["LUFSBAR_FAIL_START_AT"] == point else { return false }
        log.error("failing on purpose at \(point, privacy: .public)")
        return true
    }

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?

    // loudnessMeter is touched from the main thread (device-change listener, teardown)
    // and from the Core Audio IO thread (handleAudio, creation and use), so swapping
    // the reference itself is guarded by a lock. (The os_unfair_lock inside
    private var loudnessMeterLock = os_unfair_lock()
    private var _loudnessMeter: LoudnessMeter?

    var loudnessMeter: LoudnessMeter? {
        os_unfair_lock_lock(&loudnessMeterLock)
        defer { os_unfair_lock_unlock(&loudnessMeterLock) }
        return _loudnessMeter
    }

    private func setLoudnessMeter(_ meter: LoudnessMeter?) {
        os_unfair_lock_lock(&loudnessMeterLock)
        _loudnessMeter = meter
        os_unfair_lock_unlock(&loudnessMeterLock)
    }

    private var interleaveScratch: [Float32] = []

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
    // Rebuilds the tap when the bound device's stereo pair is changed in Audio
    // MIDI Setup. Belongs to one device, so it is removed with the tap.
    private var stereoPairListener: AudioObjectPropertyListenerBlock?
    private var stereoPairListenerDevice = AudioObjectID(kAudioObjectUnknown)

    private static var stereoPairAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static var defaultOutputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var callbackCount: Int = 0
    private let logEveryNCallbacks = 40  // thinned out to avoid flooding the log

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
        startTap()

        // LUFSBAR_DROP_METER_EVERY_MS = n: test only. Lets go of the meter every
        // n ms the way a device change does, so the next callback needs a new
        // one. Used with LUFSBAR_METER_HOLD_MS.
        _ = Self.meterHoldMicroseconds
        meterDropTimer?.invalidate()
        meterDropTimer = nil
        if let ms = TestSwitch.number("LUFSBAR_DROP_METER_EVERY_MS", limit: 60_000) {
            Self.log.error("dropping the meter on purpose every \(ms) ms")
            meterDropTimer = Timer.scheduledTimer(withTimeInterval: ms / 1000, repeats: true) { [weak self] _ in
                self?.setLoudnessMeter(nil)
            }
        }
    }

    private func startTap() {
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
        listenForStereoPairChanges(on: device.id)

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
        stopTap()
    }

    private func stopTap() {
        if let listener = stereoPairListener {
            AudioObjectRemovePropertyListenerBlock(stereoPairListenerDevice, &Self.stereoPairAddress, DispatchQueue.main, listener)
            stereoPairListener = nil
            stereoPairListenerDevice = AudioObjectID(kAudioObjectUnknown)
        }
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
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
    }

    /// Resets the Integrated measurement (called from the reset button in the popover).
    func resetIntegrated() {
        loudnessMeter?.resetIntegrated()
    }

    private func listenForStereoPairChanges(on device: AudioObjectID) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Rebuilt on the next turn of the main queue rather than here: the
            // rebuild removes this very listener, which is not something to do
            // from inside its own callback.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.stereoPairListenerDevice == device,
                      Self.stereoPair(of: device) != self.stereoPair else { return }
                Self.log.notice("stereo pair changed: rebuilding the tap")
                self.stopTap()
                self.startTap()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &Self.stereoPairAddress, DispatchQueue.main, listener)
        guard status == noErr else {
            Self.log.error("no listener on the stereo pair (OSStatus \(status)); changes to it will not be followed")
            return
        }
        stereoPairListener = listener
        stereoPairListenerDevice = device
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
        var sampleRate: Float64 = 48000
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &sampleRate)
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

    @discardableResult
    private func setupLoudnessMeter(abl: UnsafeMutableAudioBufferListPointer) -> LoudnessMeter? {
        let available = Self.availableChannels(in: abl)
        let measured = measuredChannels(available: available)
        guard measured.count > 0 else { return nil }
        let sampleRate = UInt32(nominalSampleRate())
        let meter = LoudnessMeter(sampleRate: sampleRate, channels: UInt32(measured.count))
        setLoudnessMeter(meter)
        guard meter != nil else { return nil }
        Self.log.notice("LoudnessMeter init sampleRate=\(sampleRate) channels=\(measured.count) of tapChannels=\(available) nonInterleavedBuffers=\(abl.count) on the \(Thread.isMainThread ? "main" : "audio", privacy: .public) thread")
        return meter
    }

    private func handleAudio(_ bufferList: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard abl.count > 0 else { return }

        var meter = loudnessMeter
        if meter == nil {
            meter = setupLoudnessMeter(abl: abl)
        }
        guard let meter else { return }

        // The meter reads `channels` samples per frame. If the device changed its
        // layout under the same tap, feeding it the new layout would make it read
        // past what was copied, so it is dropped and built again for the new one.
        let available = Self.availableChannels(in: abl)
        let (measured, left, right) = measuredChannels(available: available)
        guard measured > 0 else { return }
        guard measured == Int(meter.channels) else {
            setLoudnessMeter(nil)
            return
        }
        if Self.meterHoldMicroseconds > 0 { usleep(Self.meterHoldMicroseconds) }

        if abl.count == 1 {
            // A single interleaved buffer carrying every channel of the stream.
            // The measured channels of each frame are copied into scratch.
            guard let buffer = abl.first, let data = buffer.mData else { return }
            let frameCount = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * available)
            guard frameCount > 0 else { return }
            let samples = data.bindMemory(to: Float32.self, capacity: frameCount * available)

            let needed = frameCount * measured
            if interleaveScratch.count < needed {
                interleaveScratch = [Float32](repeating: 0, count: needed)
            }
            interleaveScratch.withUnsafeMutableBufferPointer { scratch in
                guard let dst = scratch.baseAddress else { return }
                for frame in 0..<frameCount {
                    dst[frame * measured] = samples[frame * available + left]
                    if measured == 2 {
                        dst[frame * 2 + 1] = samples[frame * available + right]
                    }
                }
                meter.addInterleavedFrames(dst, frameCount: frameCount)
            }
        } else {
            // One buffer per channel: the measured ones are interleaved.
            // (measuredChannels keeps left and right below abl.count.)
            let frameCount = Int(abl[left].mDataByteSize) / MemoryLayout<Float32>.size
            guard frameCount > 0, let leftData = abl[left].mData else { return }
            var rightData: UnsafeMutableRawPointer?
            if measured == 2 {
                guard Int(abl[right].mDataByteSize) / MemoryLayout<Float32>.size >= frameCount,
                      let data = abl[right].mData else { return }
                rightData = data
            }

            let needed = frameCount * measured
            if interleaveScratch.count < needed {
                interleaveScratch = [Float32](repeating: 0, count: needed)
            }
            let leftSamples = leftData.bindMemory(to: Float32.self, capacity: frameCount)
            let rightSamples = rightData?.bindMemory(to: Float32.self, capacity: frameCount)
            interleaveScratch.withUnsafeMutableBufferPointer { scratch in
                guard let dst = scratch.baseAddress else { return }
                for frame in 0..<frameCount {
                    dst[frame * measured] = leftSamples[frame]
                    if let rightSamples {
                        dst[frame * 2 + 1] = rightSamples[frame]
                    }
                }
                meter.addInterleavedFrames(dst, frameCount: frameCount)
            }
        }

        callbackCount += 1
        guard callbackCount % logEveryNCallbacks == 0 else { return }
        Self.log.notice("M=\(String(format: "%.1f", meter.momentaryLUFS), privacy: .public) S=\(String(format: "%.1f", meter.shortTermLUFS), privacy: .public) I=\(String(format: "%.1f", meter.integratedLUFS), privacy: .public) TP=\(String(format: "%.1f", meter.truePeakDBTP), privacy: .public)")
    }
}
