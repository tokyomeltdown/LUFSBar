// Test helper: prints or sets a device's nominal sample rate.
// Usage: sample_rate "<name or UID>"           -> prints the rate
//        sample_rate "<name or UID>" <rate>    -> sets it, waits up to 5 s for the
//                                               device to report it, then prints it
// Exits 1 when the device is not found, the rate cannot be set, or the device
// keeps its old rate.
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
var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
func rate(_ d: AudioObjectID) -> Float64? {
    var r: Float64 = 0
    var s = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectGetPropertyData(d, &rateAddress, 0, nil, &s, &r) == noErr ? r : nil
}

let args = CommandLine.arguments
guard args.count == 2 || args.count == 3 else { print("usage: sample_rate <device> [rate]"); exit(2) }
let all = devices()
guard let dev = all.first(where: { string($0, kAudioDevicePropertyDeviceUID) == args[1] })
        ?? all.first(where: { string($0, kAudioObjectPropertyName) == args[1] }) else {
    print("no device named \(args[1])"); exit(1)
}
if args.count == 3 {
    guard var wanted = Float64(args[2]) else { print("the rate must be a number"); exit(2) }
    let err = AudioObjectSetPropertyData(dev, &rateAddress, 0, nil, UInt32(MemoryLayout<Float64>.size), &wanted)
    guard err == noErr else { print("set failed (\(err))"); exit(1) }
    var waited = 0
    while rate(dev) != wanted && waited < 50 { Thread.sleep(forTimeInterval: 0.1); waited += 1 }
    guard rate(dev) == wanted else { print("the device kept \(rate(dev).map { "\($0)" } ?? "?")"); exit(1) }
}
guard let r = rate(dev) else { print("cannot read the rate"); exit(1) }
print(Int(r))
