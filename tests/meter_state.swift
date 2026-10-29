// Runs the app's MeterState on its own poll (10 a second, in real time) over a
// LoudnessMeter fed from here, with SystemAudioTap stood in for by
// meter_state_stub.swift, and checks what it decides from what it reads.
//
//   lag       near silence (-700 dBFS) for 3 s, then a -18 dBFS tone, Momentary
//             in the menu bar: 1 s into the tone the menu bar shows a figure
//             near it (within 6 dB; the smoothing still closes the last dB or
//             two, as after digital silence), rather than -70.0 while it climbs
//             up from the near silence (52 dB off before the fix)
//   reset110  -18 dBFS 5 s, -110 dBFS 3 s, -30 dBFS 3 s: the near silence
//             (below -100 LUFS) starts the measurement over
//   pause85   -18 dBFS 5 s, -85 dBFS 4 s, -18 dBFS 3 s: a quiet passage
//             (below the -70 LUFS gate, above -100) does not
//   floor     -85 dBFS for 4 s: below the -70 LUFS gate the menu bar and the
//             popover's figures show "--", not a "-70.0" that reads like a level
//
// Args: the case. Build with MeterState.swift, LoudnessMeter.swift and the stub
// (see build_meter_tests.sh).
import Foundation

let rate = 48000.0
let chunk = 480
let scenario = CommandLine.arguments[1]
let phases: [(dBFS: Double, seconds: Double)]
switch scenario {
case "lag": phases = [(-700, 3), (-18, 3)]
case "reset110": phases = [(-18, 5), (-110, 3), (-30, 3)]
case "pause85": phases = [(-18, 5), (-85, 4), (-18, 3)]
case "floor": phases = [(-85, 4)]
default: print("unknown case \(scenario)"); exit(2)
}

let meter = LoudnessMeter(sampleRate: UInt32(rate), channels: 2)!
SystemAudioTap.shared.loudnessMeter = meter
let state = MeterState.shared
state.menuBarMetric = scenario == "lag" ? .momentary : .shortTerm

var buffer = [Float](repeating: 0, count: chunk * 2)
var phase = 0.0
var fed = 0.0
let start = Date()
// The phase playing `seconds` into the run.
func phaseIndex(at seconds: Double) -> Int? {
    var t = 0.0
    for (i, p) in phases.enumerated() {
        t += p.seconds
        if seconds < t { return i }
    }
    return nil
}
// Fed in real time from a timer on the main run loop, so MeterState's own poll
// sees the meter move as it would in the app.
let feeder = Timer(timeInterval: 0.005, repeats: true) { _ in
    let now = Date().timeIntervalSince(start)
    while fed < now, let i = phaseIndex(at: fed) {
        let amp = Float(pow(10.0, phases[i].dBFS / 20.0))
        for f in 0..<chunk {
            let v = amp * Float(sin(phase)); phase += 2 * .pi * 1000 / rate
            buffer[2 * f] = v; buffer[2 * f + 1] = v
        }
        buffer.withUnsafeBufferPointer { meter.addInterleavedFrames($0.baseAddress!, frameCount: chunk) }
        fed += Double(chunk) / rate
    }
}
RunLoop.main.add(feeder, forMode: .common)
state.startPolling()

// The figure in the menu bar text, or nil for "--".
func shownFigure() -> Double? {
    let digits = state.menuBarText.filter { "-0123456789.".contains($0) }
    return Double(digits)
}

let total = phases.reduce(0) { $0 + $1.seconds }
var resetsAtTone = 0
var lagCheck: (shown: Double?, momentary: Double)?
func run(until seconds: Double) {
    RunLoop.main.run(until: start.addingTimeInterval(seconds))
}
switch scenario {
case "lag":
    run(until: phases[0].seconds + 1.0)
    lagCheck = (shownFigure(), state.momentaryLUFS)
case "floor":
    run(until: total)
case "reset110", "pause85":
    run(until: phases[0].seconds)
    resetsAtTone = SystemAudioTap.shared.resets
    run(until: total)
default: break
}

let ok: Bool
switch scenario {
case "lag":
    let (shown, momentary) = lagCheck!
    ok = shown.map { abs($0 - momentary) <= 6 } ?? false
    print(String(format: "lag: 1 s into the tone, Momentary %.1f, menu bar %@ %@", momentary,
                 shown.map { String(format: "%.1f", $0) } ?? "--", ok ? "PASS" : "FAIL (want within 6 dB)"))
case "reset110":
    let resets = SystemAudioTap.shared.resets - resetsAtTone
    ok = resets >= 1
    print("reset110: \(resets) resets after the -110 dBFS stretch \(ok ? "PASS" : "FAIL (want 1 or more)")")
case "pause85":
    let resets = SystemAudioTap.shared.resets - resetsAtTone
    ok = resets == 0
    print("pause85: \(resets) resets across the -85 dBFS passage \(ok ? "PASS" : "FAIL (want none)")")
case "floor":
    let popover = MeterState.displayString(state.shortTermLUFS)
    ok = shownFigure() == nil && popover == "--" && state.shortTermLUFS.isFinite
    print(String(format: "floor: Short-term %.1f, menu bar \"%@\", popover \"%@\" %@", state.shortTermLUFS,
                 state.menuBarText, popover, ok ? "PASS" : "FAIL (want -- in both)"))
default: ok = false
}
exit(ok ? 0 : 1)
