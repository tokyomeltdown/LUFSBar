// Test helper: plays a WAV file in a loop to one output device, regardless of
// the default output, for a bounded number of seconds. The device is named by
// UID or by name, as default_output takes it, and only devices with outputs count.
// Usage: tone_to_device "<name or UID>" <seconds> <file.wav>
import AVFoundation
import CoreAudio
import Foundation

let args = CommandLine.arguments
guard args.count == 4, let seconds = Double(args[2]), seconds > 0, seconds <= 120 else {
    print("usage: tone_to_device <device name> <seconds 1-120> <file.wav>"); exit(2)
}

func devices() -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var s: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s)
    var ids = [AudioObjectID](repeating: 0, count: Int(s) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &ids)
    return ids
}
func string(_ d: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: Unmanaged<CFString>?
    var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(d, &a, 0, nil, &s, &v) == noErr, let v else { return nil }
    return v.takeRetainedValue() as String
}
func hasOutputs(_ d: AudioObjectID) -> Bool {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var s: UInt32 = 0
    return AudioObjectGetPropertyDataSize(d, &a, 0, nil, &s) == noErr && s > 0
}
let outputs = devices().filter(hasOutputs)
// A UID is unique; a name may not be, so a UID match wins.
guard var dev = outputs.first(where: { string($0, kAudioDevicePropertyDeviceUID) == args[1] })
        ?? outputs.first(where: { string($0, kAudioObjectPropertyName) == args[1] }) else {
    print("no output device named \(args[1])"); exit(1)
}

let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[3]))
let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
try file.read(into: buffer)

let engine = AVAudioEngine()
let unit = engine.outputNode.audioUnit!
let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioObjectID>.size))
guard err == noErr else { print("could not bind to the device (\(err))"); exit(1) }
let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
try engine.start()
player.scheduleBuffer(buffer, at: nil, options: .loops)
player.play()
print("playing on \(args[1]) (id \(dev)) for \(seconds) s")
Thread.sleep(forTimeInterval: seconds)
player.stop()
engine.stop()
print("done")
