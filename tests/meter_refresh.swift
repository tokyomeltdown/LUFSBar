// How often LoudnessMeter's figures actually move, and whether Reset leaves
// them blank. A 997 Hz sine rises slowly in level, so Momentary is different
// at every refresh; counting its changes over 10 s of audio gives the refresh
// rate. Then Reset, one more buffer, and Momentary should already be a number
// rather than -inf ("--") until 100 ms have gone by.
// Args: sampleRate frames. Build with LUFSBar/LoudnessMeter.swift (see tests/build_meter_tests.sh).
import Foundation
let rate = Double(CommandLine.arguments[1])!, frames = Int(CommandLine.arguments[2])!
let meter = LoudnessMeter(sampleRate: UInt32(rate), channels: 2)!
var buf = [Float](repeating: 0, count: frames * 2)
var phase = 0.0, sample = 0
func feed() {
    for f in 0..<frames {
        // -40 dBFS rising to about -20 over the run.
        let amp = Float(0.01 * pow(10, Double(sample) / (rate * 12)))
        let v = amp * Float(sin(phase)); phase += 2 * .pi * 997 / rate; sample += 1
        buf[2 * f] = v; buf[2 * f + 1] = v
    }
    buf.withUnsafeBufferPointer { meter.addInterleavedFrames($0.baseAddress!, frameCount: frames) }
}
// One second to settle, then count.
for _ in 0..<(Int(rate) / frames) { feed() }
var last = meter.momentaryLUFS, changes = 0
let counted = Int(10 * rate) / frames
for _ in 0..<counted {
    feed()
    if meter.momentaryLUFS != last { changes += 1; last = meter.momentaryLUFS }
}
let seconds = Double(counted * frames) / rate
let hz = Double(changes) / seconds
let rateOK = hz >= 9.9 && hz <= 10.1
meter.resetIntegrated()
feed()
let afterReset = meter.momentaryLUFS
let resetOK = afterReset.isFinite
print(String(format: "%6.0f Hz /%4d: %.2f refreshes a second %@; Momentary after Reset + 1 buffer = %.1f %@",
             rate, frames, hz, rateOK ? "PASS" : "FAIL (want 10)", afterReset, resetOK ? "PASS" : "FAIL (want a number)"))
exit(rateOK && resetOK ? 0 : 1)
