// A one-channel meter (the default output is a mono device) must read a
// programme as a stereo device does: macOS folds L=R into the one channel at
// the same amplitude, and libebur128 counts a single channel once, which reads
// 3 dB low unless it is marked dual mono. Feeds a -18 dBFS peak 1 kHz sine for
// 10 s to a 1-channel and a 2-channel meter and compares Momentary.
// Args: sampleRate. Build with LUFSBar/LoudnessMeter.swift (see build_meter_tests.sh).
import Foundation
let rate = Double(CommandLine.arguments[1])!
let frames = 512
let mono = LoudnessMeter(sampleRate: UInt32(rate), channels: 1)!
let stereo = LoudnessMeter(sampleRate: UInt32(rate), channels: 2)!
let amp = Float(pow(10.0, -18.0 / 20.0))
var one = [Float](repeating: 0, count: frames), two = [Float](repeating: 0, count: frames * 2)
var phase = 0.0
for _ in 0..<(Int(10 * rate) / frames) {
    for f in 0..<frames {
        let v = amp * Float(sin(phase)); phase += 2 * .pi * 1000 / rate
        one[f] = v; two[2 * f] = v; two[2 * f + 1] = v
    }
    one.withUnsafeBufferPointer { mono.addInterleavedFrames($0.baseAddress!, frameCount: frames) }
    two.withUnsafeBufferPointer { stereo.addInterleavedFrames($0.baseAddress!, frameCount: frames) }
}
let m1 = mono.reading.momentary, m2 = stereo.reading.momentary
let ok = abs(m1 - m2) <= 0.1
print(String(format: "%6.0f Hz: mono M %.2f, stereo M %.2f %@", rate, m1, m2, ok ? "PASS" : "FAIL (want the same)"))
exit(ok ? 0 : 1)
