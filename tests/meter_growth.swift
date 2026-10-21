// Whether LoudnessMeter gets slower the longer it runs. Without
// EBUR128_MODE_HISTOGRAM, libebur128 keeps every 100 ms block on a list that
// the gated (Integrated) loudness walks each time it is read, so a call costs
// more every minute. Feeds <minutes> of a 997 Hz stereo sine in IOProc-sized
// blocks as fast as it can, and compares the slow calls of the last minute with
// those of the second (the first one warms up).
//
// The slow calls are the 95th percentile of each minute. The figures are read
// back from the library only every 100 ms of audio, and those reads are where
// the list is walked, so a mean over every call would hide the growth (and
// before the reads were thinned out, a constant 0.46 ms per call for the
// short-term window hid it too: 30 minutes added 48 us to that, x1.1).
// Args: sampleRate frames minutes. Passes when the slow calls grew by 10 us or less.
// Build with LUFSBar/LoudnessMeter.swift (see tests/build_meter_tests.sh).
import Foundation
let rate = Double(CommandLine.arguments[1])!, frames = Int(CommandLine.arguments[2])!
let minutes = Int(CommandLine.arguments[3])!
let meter = LoudnessMeter(sampleRate: UInt32(rate), channels: 2)!
var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
let tick = Double(info.numer) / Double(info.denom) / 1000   // us per tick
let amp = Float(0.1 * 2.0.squareRoot())                     // -20 dBFS RMS sine
var buf = [Float](repeating: 0, count: frames * 2)
var phase = 0.0
let callsPerMinute = Int(60 * rate) / frames
var minuteP95: [Double] = []
var times = [Double](repeating: 0, count: callsPerMinute)
for _ in 0..<minutes {
    for call in 0..<callsPerMinute {
        for f in 0..<frames {
            let v = amp * Float(sin(phase)); phase += 2 * .pi * 997 / rate
            buf[2 * f] = v; buf[2 * f + 1] = v
        }
        let t0 = mach_absolute_time()
        buf.withUnsafeBufferPointer { meter.addInterleavedFrames($0.baseAddress!, frameCount: frames) }
        times[call] = Double(mach_absolute_time() - t0) * tick
    }
    minuteP95.append(times.sorted()[callsPerMinute * 95 / 100])
}
let early = minuteP95[1], late = minuteP95[minutes - 1]
let ok = late - early <= 10
print(String(format: "%6.0f Hz /%4d, %d min: slow calls (p95) minute 2 %.1f us, minute %d %.1f us (%+.1f us) %@  I=%.3f",
             rate, frames, minutes, early, minutes, late, late - early, ok ? "PASS" : "FAIL (want +10 us or less)",
             meter.reading.integrated))
exit(ok ? 0 : 1)
