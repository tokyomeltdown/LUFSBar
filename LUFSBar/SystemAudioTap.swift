import Foundation
import CoreAudio
import os

// macOS 14.4+ の Core Audio process tap で、Macで再生される全プロセスの音声を
// 1つのaggregate device(tapのみ・private)経由でキャプチャする。
// 参考: https://github.com/insidegui/AudioCap
final class SystemAudioTap {
    static let shared = SystemAudioTap()

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?

    // loudnessMeterはメインスレッド(デバイス切替リスナー、破棄)とCore Audio IOスレッド
    // (handleAudio、生成・使用)の両方から触るため、参照そのものの差し替えをロックで守る。
    // (LoudnessMeter内部のos_unfair_lockはstateポインタ用の別ロックで、これとは独立)
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

    // Core Audio process tapは、出力先デバイスのステレオペア数に比例して
    // レベルが減衰する既知の挙動がある(4ステレオペア=8ch出力デバイスで約-12dB、
    // 2chデバイスでは0dB。miniaudio issue #875 と同系統)。デフォルト出力デバイスの
    // チャンネル数から補正ゲインを検出し、キャプチャしたサンプルに掛けて相殺する。
    private var inputGainLinear: Float = 1.0

    // デフォルト出力デバイスが切り替わるたびにinputGainLinearを再検出するための
    // リスナー。保持しておかないとstop()時に正しいブロック参照で解除できない。
    private var defaultOutputDeviceListener: AudioObjectPropertyListenerBlock?

    private static var defaultOutputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var callbackCount: Int = 0
    private let logEveryNCallbacks = 40  // 過剰なログを避けるための間引き

    func start() {
        inputGainLinear = Self.detectStereoPairCorrection()

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let newGain = Self.detectStereoPairCorrection()
            self.inputGainLinear = newGain
            // サンプルレート/チャンネル数がデバイスごとに違うことがあるため、
            // 既存のLoudnessMeterを破棄し次のオーディオコールバックで作り直させる。
            self.setLoudnessMeter(nil)
            NSLog("[LUFSBar][Tap] デフォルト出力デバイス変更を検知、補正ゲイン再検出とLoudnessMeter再初期化")
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
            NSLog("[LUFSBar][Tap] tap作成失敗 (OSStatus %d)", tapErr)
            MeterState.shared.reportAudioAccessError()
            return
        }
        tapID = newTapID
        NSLog("[LUFSBar][Tap] tap作成成功 id=%d", tapID)

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
            NSLog("[LUFSBar][Tap] aggregate device作成失敗 (OSStatus %d)", aggErr)
            MeterState.shared.reportAudioAccessError()
            return
        }
        aggregateID = newAggregateID
        NSLog("[LUFSBar][Tap] aggregate device作成成功 id=%d", aggregateID)

        var newIOProcID: AudioDeviceIOProcID?
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateID, nil) { [weak self] _, inInputData, _, _, _ in
            self?.handleAudio(inInputData)
        }
        guard ioErr == noErr, let newIOProcID else {
            NSLog("[LUFSBar][Tap] IOProc作成失敗 (OSStatus %d)", ioErr)
            return
        }
        ioProcID = newIOProcID

        let startErr = AudioDeviceStart(aggregateID, newIOProcID)
        guard startErr == noErr else {
            NSLog("[LUFSBar][Tap] AudioDeviceStart失敗 (OSStatus %d)", startErr)
            MeterState.shared.reportAudioAccessError()
            return
        }
        NSLog("[LUFSBar][Tap] キャプチャ開始")
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

    /// Integratedの計測をリセットする(ポップオーバーのリセットボタンから呼ばれる想定)。
    func resetIntegrated() {
        loudnessMeter?.resetIntegrated()
    }

    /// デフォルト出力デバイスの総チャンネル数からステレオペア数を求め、
    /// process tapの既知の減衰(20*log10(ステレオペア数) dB)を相殺するための
    /// 線形ゲインを返す。取得に失敗した場合や2ch以下のデバイスでは1.0(補正なし)。
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
            NSLog("[LUFSBar][Tap] デフォルト出力デバイス取得失敗、補正なしで続行")
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
        NSLog("[LUFSBar][Tap] 出力デバイスの総チャンネル数=%d ステレオペア数=%d 補正ゲイン=+%.1fdB",
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
        NSLog("[LUFSBar][Tap] LoudnessMeter初期化 sampleRate=%d channels=%d nonInterleavedBuffers=%d",
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
            // インターリーブされた単一バッファ。tap由来のバッファを直接書き換えず、
            // ゲイン適用のためスクラッチにコピーしてから渡す。
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
            // チャンネルごとに分かれた非インターリーブバッファ → ゲイン適用しつつインターリーブに変換
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
