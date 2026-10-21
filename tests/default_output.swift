// Test helper: prints the default output device, or sets it by name or UID.
// Usage: default_output                  -> prints the current name
//        default_output -u               -> prints the current UID
//        default_output "<name or UID>"  -> sets it, then prints the new name
// Exits 1 when the device is not found or cannot be set.
import CoreAudio
import Foundation

var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
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
func name(_ d: AudioObjectID) -> String { string(d, kAudioObjectPropertyName) }
func uid(_ d: AudioObjectID) -> String { string(d, kAudioDevicePropertyDeviceUID) }
func current() -> AudioObjectID {
    var d = AudioObjectID(kAudioObjectUnknown)
    var s = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(sys, &addr, 0, nil, &s, &d)
    return d
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "-u" {
    let d = current()
    guard d != kAudioObjectUnknown else { print("no default output"); exit(1) }
    print(uid(d))
    exit(0)
}
if CommandLine.arguments.count > 1 {
    let wanted = CommandLine.arguments[1]
    // A UID is unique; a name may not be, so a UID match wins.
    let all = devices()
    guard var d = all.first(where: { uid($0) == wanted }) ?? all.first(where: { name($0) == wanted }) else {
        print("no device named \(wanted)"); exit(1)
    }
    let err = AudioObjectSetPropertyData(sys, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &d)
    guard err == noErr else { print("set failed (\(err))"); exit(1) }
    // Bluetooth and AirPlay devices can take a while to take over.
    var waited = 0
    while current() != d && waited < 30 { Thread.sleep(forTimeInterval: 0.1); waited += 1 }
    guard current() == d else { print("the default output did not change"); exit(1) }
}
print(name(current()))
