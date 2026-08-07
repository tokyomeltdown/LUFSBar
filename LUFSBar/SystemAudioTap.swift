import Foundation
import CoreAudio
import os

// Uses the macOS 14.4+ Core Audio process tap to capture the audio of every
// process playing on the Mac through a single private, tap-only aggregate device.
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

    // A Core Audio process tap has a known behaviour where the level drops in
    // proportion to the number of stereo pairs on the output device (about -12dB on an
    // 8-channel device with 4 stereo pairs, 0dB on a 2-channel device; the same family
    // as miniaudio issue #875). The correction gain is derived from the channel count
    private var inputGainLinear: Float = 1.0

    // Listener that re-detects inputGainLinear whenever the default output device
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
        inputGainLinear = Self.detectStereoPairCorrection()

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let newGain = Self.detectStereoPairCorrection()
            self.inputGainLinear = newGain
            // Sample rate and channel count can differ per device, so the existing
            // LoudnessMeter is discarded and rebuilt on the next audio callback.
            self.setLoudnessMeter(nil)
            NSLog("[LUFSBar][Tap] default output device changed: re-detecting gain, reinitialising LoudnessMeter")
        }
        defaultOutputDeviceListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputDeviceAddress, DispatchQueue.main, listener
        )

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
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
            return
        }
        ioProcID = newIOProcID

        let startErr = AudioDeviceStart(aggregateID, newIOProcID)
        guard startErr == noErr else {
            NSLog("[LUFSBar][Tap] AudioDeviceStart failed (OSStatus %d)", startErr)
            MeterState.shared.reportAudioAccessError()
            return
        }
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

    /// Works out the number of stereo pairs from the total channel count of the default
    /// output device and returns the linear gain that cancels the tap known attenuation
    /// of 20*log10(stereo pairs) dB. Returns 1.0 (no correction) on failure or 2ch devices.
    private static func detectStereoPairCorrection() -> Float {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var deviceIDSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceErr = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceIDSize, &deviceID
        )
        guard deviceErr == noErr, deviceID != kAudioObjectUnknown else {
            NSLog("[LUFSBar][Tap] could not read the default output device; continuing without correction")
            return 1.0
        }

        var configAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &configAddress, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return 1.0
        }

        let bufferListPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        ).bindMemory(to: AudioBufferList.self, capacity: 1)
        defer { bufferListPtr.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &configAddress, 0, nil, &dataSize, bufferListPtr) == noErr else {
            return 1.0
        }

        let abl = UnsafeMutableAudioBufferListPointer(bufferListPtr)
        let totalChannels = abl.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard totalChannels > 2 else { return 1.0 }

        let stereoPairs = max(1, totalChannels / 2)
        let correction = Float(stereoPairs)
        NSLog("[LUFSBar][Tap] output device channels=%d stereo pairs=%d correction=+%.1fdB",
              totalChannels, stereoPairs, 20 * log10(correction))
        return correction
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

    @discardableResult
    private func setupLoudnessMeter(abl: UnsafeMutableAudioBufferListPointer) -> LoudnessMeter? {
        let channelCount: UInt32
        if abl.count == 1 {
            channelCount = max(abl.first?.mNumberChannels ?? 2, 1)
        } else {
            channelCount = UInt32(abl.count)
        }
        let sampleRate = UInt32(nominalSampleRate())
        let meter = LoudnessMeter(sampleRate: sampleRate, channels: channelCount)
        setLoudnessMeter(meter)
        NSLog("[LUFSBar][Tap] LoudnessMeter init sampleRate=%d channels=%d nonInterleavedBuffers=%d",
              sampleRate, channelCount, abl.count)
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

        let gain = inputGainLinear

        if abl.count == 1 {
            // A single interleaved buffer. The tap buffer is not modified in place: it is
            // copied into scratch so the gain can be applied before handing it over.
            guard let buffer = abl.first, let data = buffer.mData else { return }
            let channelCount = Int(buffer.mNumberChannels)
            guard channelCount > 0 else { return }
            let frameCount = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * channelCount)
            guard frameCount > 0 else { return }
            let samples = data.bindMemory(to: Float32.self, capacity: frameCount * channelCount)

            let needed = frameCount * channelCount
            if interleaveScratch.count < needed {
                interleaveScratch = [Float32](repeating: 0, count: needed)
            }
            if gain == 1.0 {
                interleaveScratch.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress?.update(from: samples, count: needed)
                }
            } else {
                for i in 0..<needed {
                    interleaveScratch[i] = samples[i] * gain
                }
            }

            interleaveScratch.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                meter.addInterleavedFrames(base, frameCount: frameCount)
            }
        } else {
            // Per-channel non-interleaved buffers: apply the gain while interleaving
            let channelCount = abl.count
            guard let first = abl.first, first.mData != nil else { return }
            let frameCount = Int(first.mDataByteSize) / MemoryLayout<Float32>.size
            guard frameCount > 0 else { return }

            let needed = frameCount * channelCount
            if interleaveScratch.count < needed {
                interleaveScratch = [Float32](repeating: 0, count: needed)
            }

            for (ch, buffer) in abl.enumerated() {
                guard let data = buffer.mData else { continue }
                let samples = data.bindMemory(to: Float32.self, capacity: frameCount)
                for frame in 0..<frameCount {
                    interleaveScratch[frame * channelCount + ch] = samples[frame] * gain
                }
            }

            interleaveScratch.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                meter.addInterleavedFrames(base, frameCount: frameCount)
            }
        }

        callbackCount += 1
        guard callbackCount % logEveryNCallbacks == 0 else { return }
        NSLog("[LUFSBar][Tap] M=%.1f S=%.1f I=%.1f TP=%.1f",
              meter.momentaryLUFS, meter.shortTermLUFS, meter.integratedLUFS, meter.truePeakDBTP)
    }
}
