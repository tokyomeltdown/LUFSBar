// Test helper: makes a public aggregate device (or, stacked, a Multi-Output
// Device) of two devices, prints its UID, and destroys it when sent SIGTERM
// (or after 10 minutes, so a test that dies does not leave it behind).
// Usage: aggregate <stacked 0|1> <name> <device UID 1> <device UID 2>
//        aggregate destroy <aggregate UID>   (one left behind by a run that died)
// The first device is the clock; the second gets drift compensation.
import CoreAudio
import Foundation

let args = CommandLine.arguments
if args.count == 3, args[1] == "destroy" {
    var translation = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var uid = args[2] as CFString
    var found = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafeMutablePointer(to: &uid) { qualifier in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &translation,
                                   UInt32(MemoryLayout<CFString>.size), qualifier, &size, &found)
    }
    guard status == noErr, found != kAudioObjectUnknown else { exit(0) }
    exit(AudioHardwareDestroyAggregateDevice(found) == noErr ? 0 : 1)
}
guard args.count == 5 else { print("usage: aggregate <stacked 0|1> <name> <uid1> <uid2>"); exit(2) }
let uid = "com.tokyomeltdown.lufsbar.test.\(args[2])"
let description: [String: Any] = [
    kAudioAggregateDeviceNameKey: args[2],
    kAudioAggregateDeviceUIDKey: uid,
    kAudioAggregateDeviceIsPrivateKey: false,
    kAudioAggregateDeviceIsStackedKey: args[1] == "1",
    kAudioAggregateDeviceMasterSubDeviceKey: args[3],
    kAudioAggregateDeviceSubDeviceListKey: [
        [kAudioSubDeviceUIDKey: args[3]],
        [kAudioSubDeviceUIDKey: args[4], kAudioSubDeviceDriftCompensationKey: 1],
    ],
]
var device = AudioObjectID(kAudioObjectUnknown)
let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
guard status == noErr else { print("could not make the aggregate (OSStatus \(status))"); exit(1) }
print(uid)
fflush(stdout)

func destroy() -> Never {
    _ = AudioHardwareDestroyAggregateDevice(device)
    exit(0)
}
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { destroy() }
term.resume()
DispatchQueue.main.asyncAfter(deadline: .now() + 600) { destroy() }
dispatchMain()
