import Foundation
import os

// libebur128 (ITU-R BS.1770-4 / EBU R128) の薄いSwiftラッパー。
final class LoudnessMeter {
    private var state: UnsafeMutablePointer<ebur128_state>?
    let channels: UInt32

    private(set) var momentaryLUFS: Double = -Double.infinity
    private(set) var shortTermLUFS: Double = -Double.infinity
    private(set) var integratedLUFS: Double = -Double.infinity
    private(set) var truePeakDBTP: Double = -Double.infinity

    // addInterleavedFrames()はCore AudioのリアルタイムIOスレッドから、
    // resetIntegrated()はメインスレッドのTimerから呼ばれる。stateポインタを
    // 排他制御しないと、メインスレッドでのdestroy+recreateの最中にIOスレッドが
    // 解放済みのstateにアクセスしてクラッシュする(実際にSIGSEGVで再現した)。
    private var unfairLock = os_unfair_lock()

    init?(sampleRate: UInt32, channels: UInt32) {
        self.channels = channels
        let mode = Int32(
            EBUR128_MODE_M.rawValue | EBUR128_MODE_S.rawValue
                | EBUR128_MODE_I.rawValue | EBUR128_MODE_TRUE_PEAK.rawValue
        )
        guard let st = ebur128_init(channels, UInt(sampleRate), mode) else {
            return nil
        }
        state = st
    }

    deinit {
        ebur128_destroy(&state)
    }

    /// - Parameter interleaved: チャンネルがインターリーブされたfloatサンプル配列
    func addInterleavedFrames(_ interleaved: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        guard let state else { return }
        _ = ebur128_add_frames_float(state, interleaved, frameCount)
        refresh(state: state)
    }

    /// Integrated(と付随してM/S)の計測をリセットする。libebur128はIntegratedのみの
    /// リセットAPIを持たないため、stateを作り直す。
    func resetIntegrated() {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        guard let oldState = state else { return }
        let sampleRate = UInt32(oldState.pointee.samplerate)
        ebur128_destroy(&state)
        let mode = Int32(
            EBUR128_MODE_M.rawValue | EBUR128_MODE_S.rawValue
                | EBUR128_MODE_I.rawValue | EBUR128_MODE_TRUE_PEAK.rawValue
        )
        state = ebur128_init(channels, UInt(sampleRate), mode)
        momentaryLUFS = -Double.infinity
        shortTermLUFS = -Double.infinity
        integratedLUFS = -Double.infinity
        truePeakDBTP = -Double.infinity
    }

    /// 呼び出し元(addInterleavedFrames)がすでにロックを保持している前提。
    private func refresh(state: UnsafeMutablePointer<ebur128_state>) {
        var m: Double = -Double.infinity
        if ebur128_loudness_momentary(state, &m) == EBUR128_SUCCESS.rawValue {
            momentaryLUFS = m
        }

        var s: Double = -Double.infinity
        if ebur128_loudness_shortterm(state, &s) == EBUR128_SUCCESS.rawValue {
            shortTermLUFS = s
        }

        var i: Double = -Double.infinity
        if ebur128_loudness_global(state, &i) == EBUR128_SUCCESS.rawValue {
            integratedLUFS = i
        }

        var maxPeak: Double = 0
        for ch in 0..<channels {
            var peak: Double = 0
            if ebur128_true_peak(state, ch, &peak) == EBUR128_SUCCESS.rawValue {
                maxPeak = max(maxPeak, peak)
            }
        }
        truePeakDBTP = maxPeak > 0 ? 20 * log10(maxPeak) : -Double.infinity
    }
}
