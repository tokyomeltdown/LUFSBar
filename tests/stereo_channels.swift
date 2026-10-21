// Test helper: prints or sets the channels a device uses for stereo
// (Audio MIDI Setup > Configure Speakers), and lists its output streams.
// Usage: stereo_channels "<name or UID>"            -> prints "L R" and the stream layout
//        stereo_channels "<name or UID>" <L> <R>    -> sets them (1-based), then prints
// Exits 1 when the device is not found or the property cannot be read or set.
import CoreAudio
import Foundation

let sys = AudioObjectID(kAudioObjectSystemObject)
func devices() -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var s: UInt32 = 0
    AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &s)
    var ids = [AudioObjectID](repeating: 0, count: Int(s) / 4)
    AudioObjectGetPropertyData(sys, &a, 0, nil, &s, &ids)
    return ids
}
func string(_ d: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: Unmanaged<CFString>?
    var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(d, &a, 0, nil, &s, &v) == noErr, let v else { return "?" }
    return v.takeRetainedValue() as String
}
func streamChannels(_ d: AudioObjectID) -> [Int] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var s: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(d, &a, 0, nil, &s) == noErr, s > 0 else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(s), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(d, &a, 0, nil, &s, raw) == noErr else { return [] }
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
}

let args = CommandLine.arguments
guard args.count == 2 || args.count == 4 else { print("usage: stereo_channels <device> [L R]"); exit(2) }
let all = devices()
guard let dev = all.first(where: { string($0, kAudioDevicePropertyDeviceUID) == args[1] })
        ?? all.first(where: { string($0, kAudioObjectPropertyName) == args[1] }) else {
    print("no device named \(args[1])"); exit(1)
}
var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyPreferredChannelsForStereo, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
if args.count == 4 {
    guard let l = UInt32(args[2]), let r = UInt32(args[3]) else { print("L and R must be numbers"); exit(2) }
    var pair: [UInt32] = [l, r]
    let err = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size * 2), &pair)
    guard err == noErr else { print("set failed (\(err))"); exit(1) }
    Thread.sleep(forTimeInterval: 0.5)
}
var pair: [UInt32] = [0, 0]
var size = UInt32(MemoryLayout<UInt32>.size * 2)
guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &pair) == noErr else { print("cannot read the stereo pair"); exit(1) }
print("\(pair[0]) \(pair[1]) streams=\(streamChannels(dev))")
// A driver can accept the call and keep its old pair, and a test that thinks it
// moved the pair would then pass without testing anything.
if args.count == 4, "\(pair[0]) \(pair[1])" != "\(args[2]) \(args[3])" {
    print("the device kept its stereo pair"); exit(1)
}
