// Test helper: writes a 1 kHz sine, stereo, as 32-bit float WAV, at a given
// peak level. Float, because a level such as -100 dBFS has to reach the meter
// as it is; in 16-bit it would be a few steps of dither, or nothing.
// Usage: make_tone <peak dBFS> <seconds> <sample rate> <out.wav>
import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count == 5, let peak = Double(args[1]), let seconds = Double(args[2]), let rate = Double(args[3]) else {
    print("usage: make_tone <peak dBFS> <seconds> <sample rate> <out.wav>"); exit(2)
}
let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: rate,
    AVNumberOfChannelsKey: 2,
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsNonInterleaved: false,
]
// In a function, because the file is only finished (its header written) when
// the AVAudioFile goes away, and a top-level one never does.
func write() throws {
    let file = try AVAudioFile(forWriting: URL(fileURLWithPath: args[4]), settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
    buffer.frameLength = frames
    let amp = Float(pow(10.0, peak / 20.0))
    for f in 0..<Int(frames) {
        let v = amp * Float(sin(2 * Double.pi * 1000 * Double(f) / rate))
        buffer.floatChannelData![0][f] = v
        buffer.floatChannelData![1][f] = v
    }
    try file.write(from: buffer)
}
try write()
