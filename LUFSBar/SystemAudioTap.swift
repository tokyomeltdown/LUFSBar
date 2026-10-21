import Foundation
import CoreAudio
import os

// Uses the macOS 14.4+ Core Audio process tap to capture what every process is
// playing to the Mac's default output, through a single private, tap-only
// aggregate device. Audio sent to any other device is not measured.
// Reference: https://github.com/insidegui/AudioCap
final class SystemAudioTap {
    static let shared = SystemAudioTap()

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
                NSLog("[LUFSBar][Tap] default output device changed: rebuilding the tap on %@", newDevice?.uid ?? "nothing")
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
            NSLog("[LUFSBar][Tap] no default output device; waiting for one")
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
        NSLog("[LUFSBar][Tap] measuring everything on %@ (stream %ld, channels %ld-%ld)",
              boundUID, pair.stream, pair.left + 1, pair.right + 1)
        description.name = "LUFSBar System Tap"
        description.muteBehavior = .unmuted
        description.isPrivate = true
        tapDescription = description

        var newTapID: AudioObjectID = kAudioObjectUnknown
        let tapErr = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapErr == noErr else {
            NSLog("[LUFSBar][Tap] failed to create the tap (OSStatus %d)", tapErr)
            MeterState.shared.reportAudioAccessError()
            return
        }
        tapID = newTapID
        NSLog("[LUFSBar][Tap] tap created id=%d", tapID)

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
        guard aggErr == noErr else {
            NSLog("[LUFSBar][Tap] failed to create the aggregate device (OSStatus %d)", aggErr)
            MeterState.shared.reportAudioAccessError()
            return
        }
        aggregateID = newAggregateID
        NSLog("[LUFSBar][Tap] aggregate device created id=%d", aggregateID)

        var newIOProcID: AudioDeviceIOProcID?
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateID, nil) { [weak self] _, inInputData, _, _, _ in
            self?.handleAudio(inInputData)
        }
        guard ioErr == noErr, let newIOProcID else {
            NSLog("[LUFSBar][Tap] failed to create the IOProc (OSStatus %d)", ioErr)
            MeterState.shared.reportAudioAccessError()
            return
        }
        ioProcID = newIOProcID

        let startErr = AudioDeviceStart(aggregateID, newIOProcID)
        guard startErr == noErr else {
            NSLog("[LUFSBar][Tap] AudioDeviceStart failed (OSStatus %d)", startErr)
            MeterState.shared.reportAudioAccessError()
            return
        }
        started = true
        NSLog("[LUFSBar][Tap] capture started")
        MeterState.shared.clearAudioAccessError()
    }

    func stop() {
        if let listener = defaultOutputDeviceListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputDeviceAddress, DispatchQueue.main, listener
            )
            defaultOutputDeviceListener = nil
        }
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
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
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
                NSLog("[LUFSBar][Tap] stereo pair changed: rebuilding the tap")
                self.stopTap()
                self.startTap()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &Self.stereoPairAddress, DispatchQueue.main, listener)
        guard status == noErr else {
            NSLog("[LUFSBar][Tap] no listener on the stereo pair (OSStatus %d); changes to it will not be followed", status)
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
        NSLog("[LUFSBar][Tap] LoudnessMeter init sampleRate=%d channels=%ld of tapChannels=%ld nonInterleavedBuffers=%ld",
              sampleRate, measured.count, available, abl.count)
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
        NSLog("[LUFSBar][Tap] M=%.1f S=%.1f I=%.1f TP=%.1f",
              meter.momentaryLUFS, meter.shortTermLUFS, meter.integratedLUFS, meter.truePeakDBTP)
    }
}
