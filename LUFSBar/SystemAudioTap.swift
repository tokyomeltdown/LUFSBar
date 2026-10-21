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

    private static var defaultOutputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var callbackCount: Int = 0
    private let logEveryNCallbacks = 40  // thinned out to avoid flooding the log

    func start() {
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

        let description = CATapDescription()
        // Mixdown off: with it on, a device-bound tap delivers the right peaks
        // but half the energy, which is not a waveform to measure loudness on.
        description.isMixdown = false
        description.isMono = false
        description.deviceUID = boundUID
        // Required. Left unset, the tap is created without complaint and then
        // never delivers a callback.
        description.stream = 0
        description.isExclusive = true
        description.processes = []
        NSLog("[LUFSBar][Tap] measuring everything on %@", boundUID)
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

    /// How many channels the tap delivers: the bound device's own count (ten on a
    /// ten output interface), in one interleaved buffer or one buffer per channel.
    private static func availableChannels(in abl: UnsafeMutableAudioBufferListPointer) -> Int {
        abl.count == 1 ? Int(abl.first?.mNumberChannels ?? 0) : abl.count
    }

    /// Channels one and two are measured: the monitor pair. A source playing out
    /// of three and four is not measured, which is a known limit.
    private static func measuredChannels(in abl: UnsafeMutableAudioBufferListPointer) -> Int {
        min(availableChannels(in: abl), 2)
    }

    @discardableResult
    private func setupLoudnessMeter(abl: UnsafeMutableAudioBufferListPointer) -> LoudnessMeter? {
        let channelCount = UInt32(Self.measuredChannels(in: abl))
        guard channelCount > 0 else { return nil }
        let sampleRate = UInt32(nominalSampleRate())
        let meter = LoudnessMeter(sampleRate: sampleRate, channels: channelCount)
        setLoudnessMeter(meter)
        NSLog("[LUFSBar][Tap] LoudnessMeter init sampleRate=%d channels=%d of tapChannels=%ld nonInterleavedBuffers=%ld",
              sampleRate, channelCount, Self.availableChannels(in: abl), abl.count)
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
        let measured = Self.measuredChannels(in: abl)
        guard measured > 0 else { return }
        guard measured == Int(meter.channels) else {
            setLoudnessMeter(nil)
            return
        }

        if abl.count == 1 {
            // A single interleaved buffer carrying every channel of the device.
            // The first `measured` channels of each frame are copied into scratch.
            guard let buffer = abl.first, let data = buffer.mData else { return }
            let channelCount = Int(buffer.mNumberChannels)
            let frameCount = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * channelCount)
            guard frameCount > 0 else { return }
            let samples = data.bindMemory(to: Float32.self, capacity: frameCount * channelCount)

            let needed = frameCount * measured
            if interleaveScratch.count < needed {
                interleaveScratch = [Float32](repeating: 0, count: needed)
            }
            interleaveScratch.withUnsafeMutableBufferPointer { scratch in
                guard let dst = scratch.baseAddress else { return }
                for frame in 0..<frameCount {
                    for ch in 0..<measured {
                        dst[frame * measured + ch] = samples[frame * channelCount + ch]
                    }
                }
                meter.addInterleavedFrames(dst, frameCount: frameCount)
            }
        } else {
            // Per-channel non-interleaved buffers: the first `measured` are interleaved
            guard let first = abl.first, first.mData != nil else { return }
            let frameCount = Int(first.mDataByteSize) / MemoryLayout<Float32>.size
            guard frameCount > 0 else { return }
            for ch in 0..<measured {
                guard abl[ch].mData != nil,
                      Int(abl[ch].mDataByteSize) / MemoryLayout<Float32>.size >= frameCount else { return }
            }

            let needed = frameCount * measured
            if interleaveScratch.count < needed {
                interleaveScratch = [Float32](repeating: 0, count: needed)
            }
            interleaveScratch.withUnsafeMutableBufferPointer { scratch in
                guard let dst = scratch.baseAddress else { return }
                for ch in 0..<measured {
                    let samples = abl[ch].mData!.bindMemory(to: Float32.self, capacity: frameCount)
                    for frame in 0..<frameCount {
                        dst[frame * measured + ch] = samples[frame]
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
