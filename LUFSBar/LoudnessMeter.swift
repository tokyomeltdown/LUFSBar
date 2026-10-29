import Foundation
import os

// A thin Swift wrapper around libebur128 (ITU-R BS.1770-4 / EBU R128).
final class LoudnessMeter {
    private var state: UnsafeMutablePointer<ebur128_state>?
    let channels: UInt32

    private var momentaryLUFS: Double = -Double.infinity
    private var shortTermLUFS: Double = -Double.infinity
    private var integratedLUFS: Double = -Double.infinity
    private var truePeakDBTP: Double = -Double.infinity

    /// The four figures from one refresh, read under the lock: the only way to
    /// read them, because the audio thread writes them. Read one by one they
    /// could come from different refreshes, and each read raced that write.
    struct Reading {
        let momentary: Double
        let shortTerm: Double
        let integrated: Double
        let truePeak: Double
    }

    var reading: Reading {
        os_unfair_lock_lock(unfairLock)
        defer { os_unfair_lock_unlock(unfairLock) }
        return Reading(momentary: momentaryLUFS, shortTerm: shortTermLUFS,
                       integrated: integratedLUFS, truePeak: truePeakDBTP)
    }

    // addInterleavedFrames() is called from the Core Audio realtime IO thread,
    // resetIntegrated() from a Timer on the main thread. Without a lock around
    // the state pointer, the IO thread can touch a freed state while the main
    // thread is between destroy and recreate (reproduced as a real SIGSEGV).
    /// A pointer rather than a stored value, because passing `&someProperty` to
    /// a C function can hand it a temporary copy, and a lock that gets copied is
    /// not a lock.
    private let unfairLock: UnsafeMutablePointer<os_unfair_lock_s> = {
        let lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())
        return lock
    }()

    /// The figures are read back from the library once per 100 ms of audio
    /// rather than on every callback. Short-term sums its whole 3 s window
    /// each time it is asked, so asking on every buffer cost the same however
    /// small the buffer: measured with this file and the vendored ebur128.c,
    /// 456 us a callback at 48 kHz / 512 (4% of the budget), 848 us at
    /// 96 kHz / 128 (64%) and 1683 us at 192 kHz / 256 (126%, more than the
    /// buffer lasts). The panel reads every 100 ms, and the
    /// library keeps the true peak between reads, so nothing shown changes.
    ///
    /// What is over the 100 ms is carried, not dropped. Dropped, the period
    /// rounded up to whole buffers: 9.4 reads a second at 48 kHz / 512 and 5.9
    /// at 4096, so the panel kept reading the same figures twice. The count
    /// starts half a period past due, so the first buffer, and the first after
    /// a reset, reads at once instead of showing "--" for 100 ms; the half also
    /// keeps the reads off the buffers where the library closes a 100 ms block.
    private let framesPerRefresh: Int
    private var framesSinceRefresh: Int

    // HISTOGRAM is not about what is measured, it is about what the library
    // keeps. Without it every 100 ms block is malloc'd and hung on a list
    // that is never trimmed, and the gated loudness walks that list on every
    // buffer. Both happen on the audio thread. Measured with a steady test
    // signal: the call took 0.030 ms after twenty minutes and
    // 0.095 ms after an hour, and rising, against a 10.67 ms budget.
    // tests/meter_growth.swift shows it: 30 minutes added 55 us to the slow
    // calls without it (and 43 us before the reads were thinned out).
    //
    // The histogram quantises block energies into 0.1 LU bins and counts each
    // block at its bin's centre, so it buys that with accuracy: Integrated can
    // be off by up to 0.05 LU. On programme material the errors average out
    // (0.025 LU at worst against an independent BS.1770 implementation). A
    // steady tone puts every block in the same bin and shows the whole of it:
    // the -18 dBFS calibration tone reads I = -17.950 instead of -17.993,
    // which still shows as -18.0, but a value right at a rounding edge can
    // move the displayed tenth. Momentary and Short-term do not use it.
    //
    // One constant, used by makeState, so a reset cannot rebuild the state
    // without it.
    private static let mode = Int32(
        EBUR128_MODE_M.rawValue | EBUR128_MODE_S.rawValue
            | EBUR128_MODE_I.rawValue | EBUR128_MODE_TRUE_PEAK.rawValue
            | EBUR128_MODE_HISTOGRAM.rawValue
    )

    init?(sampleRate: UInt32, channels: UInt32) {
        self.channels = channels
        framesPerRefresh = max(1, Int(sampleRate) / 10)
        framesSinceRefresh = framesPerRefresh + framesPerRefresh / 2
        guard let st = Self.makeState(sampleRate: sampleRate, channels: channels) else {
            return nil
        }
        state = st
        // Touched here so that its first use, in a deinit that might run on the
        // audio thread, does not also build it there.
        _ = Self.log
    }

    private static let log = Logger(subsystem: "com.tokyomeltdown.lufsbar", category: "meter")

    /// A nominal rate from the HAL as a rate to build a meter at, or nil when
    /// libebur128 would refuse it (it takes 16 Hz to 2,822,400 Hz). Checked
    /// before the conversion, which traps on a value out of range.
    static func sampleRate(fromNominal nominal: Double) -> UInt32? {
        guard nominal.isFinite, nominal >= 16, nominal <= 2_822_400 else { return nil }
        return UInt32(nominal.rounded())
    }

    /// Every state, the first and each one a reset builds, comes from here, so
    /// none is made with a different mode or channel map.
    ///
    /// A one-channel meter measures a mono output device. macOS folds a stereo
    /// programme into that channel at the same amplitude, and libebur128 counts
    /// a single channel once, so it read 3 dB below the same programme on any
    /// stereo device; marked dual mono, it counts it as both ears hearing it.
    private static func makeState(sampleRate: UInt32, channels: UInt32) -> UnsafeMutablePointer<ebur128_state>? {
        guard let state = ebur128_init(channels, UInt(sampleRate), mode) else { return nil }
        if channels == 1 {
            _ = ebur128_set_channel(state, 0, Int32(EBUR128_DUAL_MONO.rawValue))
        }
        return state
    }

    deinit {
        // ebur128_destroy is a run of free(), which has no place on the audio
        // thread. Logged so a test can count how often it happens.
        if !Thread.isMainThread {
            Self.log.error("a meter was freed off the main thread")
        }
        // Swift runs deinit even when init? returned nil, which it does when
        // ebur128_init refuses the sample rate, and ebur128_destroy follows
        // the pointer without checking it. Measured: a rate of 0 or 3,000,000
        // ended in SIGSEGV here instead of reaching the caller's error path.
        if state != nil {
            ebur128_destroy(&state)
        }
        unfairLock.deinitialize(count: 1)
        unfairLock.deallocate()
    }

    /// - Parameter interleaved: float samples with the channels interleaved
    func addInterleavedFrames(_ interleaved: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        os_unfair_lock_lock(unfairLock)
        defer { os_unfair_lock_unlock(unfairLock) }

        guard let state else { return }
        _ = ebur128_add_frames_float(state, interleaved, frameCount)
        framesSinceRefresh += frameCount
        guard framesSinceRefresh >= framesPerRefresh else { return }
        // Not -=: a buffer longer than two periods would leave it growing.
        framesSinceRefresh %= framesPerRefresh
        refresh(state: state)
    }

    /// Resets the Integrated measurement (and M/S with it). libebur128 has no API
    /// to reset Integrated alone, so the state is rebuilt.
    ///
    /// Building the replacement and freeing the old one both happen outside the
    /// lock, because each is a run of malloc and free and the IO thread waits on
    /// this same lock to add its frames. A reset comes while audio may be
    /// playing (a stall can end any moment), so the wait would be heard. Only
    /// the swap is held.
    ///
    /// Safe to do in two steps because this is only ever called from the main
    /// thread: MeterState's poll, after silence or when the callbacks stop.
    func resetIntegrated() {
        os_unfair_lock_lock(unfairLock)
        let sampleRate = state.map { UInt32($0.pointee.samplerate) }
        os_unfair_lock_unlock(unfairLock)
        guard let sampleRate else { return }

        guard let fresh = Self.makeState(sampleRate: sampleRate, channels: channels) else { return }

        os_unfair_lock_lock(unfairLock)
        var retired = state
        state = fresh
        momentaryLUFS = -Double.infinity
        shortTermLUFS = -Double.infinity
        integratedLUFS = -Double.infinity
        truePeakDBTP = -Double.infinity
        framesSinceRefresh = framesPerRefresh + framesPerRefresh / 2
        os_unfair_lock_unlock(unfairLock)

        ebur128_destroy(&retired)
    }

    /// Assumes the caller (addInterleavedFrames) already holds the lock.
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
