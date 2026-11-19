import CoreAudio
import Foundation

func arr<T>(_ sel: AudioObjectPropertySelector, _ obj: AudioObjectID = AudioObjectID(kAudioObjectSystemObject)) -> [T] {
    var a = AudioObjectPropertyAddress(mSelector: sel,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var out = [T](repeating: unsafeBitCast(0 as UInt32, to: T.self), count: Int(size) / MemoryLayout<T>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr else { return [] }
    return out
}

func str(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var s: CFString? = nil
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &s) == noErr else { return "?" }
    return s as String? ?? "?"
}

func pid(_ obj: AudioObjectID) -> pid_t {
    var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<pid_t>.size)
    var p: pid_t = -1
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &p) == noErr else { return -1 }
    return p
}

func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var v: UInt32 = 0
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr else { return 0 }
    return v
}

let taps: [AudioObjectID] = arr(kAudioHardwarePropertyTapList)
print("=== PROCESS TAPS: \(taps.count) ===")
for t in taps { print("  tap #\(t) uid=\(str(t, kAudioTapPropertyUID))") }

let devs: [AudioObjectID] = arr(kAudioHardwarePropertyDevices)
print("=== DEVICES: \(devs.count) ===")
for d in devs {
    print("  dev #\(d) \(str(d, kAudioObjectPropertyName)) uid=\(str(d, kAudioDevicePropertyDeviceUID)) running=\(u32(d, kAudioDevicePropertyDeviceIsRunningSomewhere))")
}

let procs: [AudioObjectID] = arr(kAudioHardwarePropertyProcessObjectList)
print("=== AUDIO PROCESSES: \(procs.count) ===")
for p in procs {
    let running = u32(p, kAudioProcessPropertyIsRunning)
    let inp = u32(p, kAudioProcessPropertyIsRunningInput)
    let outp = u32(p, kAudioProcessPropertyIsRunningOutput)
    if running == 0 && inp == 0 && outp == 0 { continue }
    let pp = pid(p)
    let name = (try? String(contentsOf: URL(fileURLWithPath: "/dev/null"))) ?? ""
    _ = name
    print("  proc #\(p) pid=\(pp) running=\(running) in=\(inp) out=\(outp) bundle=\(str(p, kAudioProcessPropertyBundleID))")
}
