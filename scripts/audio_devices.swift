// Lists every audio device with input streams: UID, name, transport type and
// object class as FourCC (device-switch-capture 3.0). Private
// aggregates (CADefaultDeviceAggregate-<pid>, Vedivox-SystemTap) are visible only
// inside the process that owns them — for those, turn on debug logging in Vedivox
// and read the "Input device:" lines the picker writes while capturing.
// Build: swiftc -O -o "$TMPDIR/audio_devices" scripts/audio_devices.swift
import CoreAudio
import Foundation

func fourCC(_ v: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }
    return String(bytes: bytes, encoding: .macOSRoman) ?? String(v)
}
func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<UInt32>.size); var value: UInt32 = 0
    return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
}
func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString>.size); var value: CFString = "" as CFString
    let err = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
    return err == noErr ? value as String : "?"
}
func hasInput(_ id: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }
    let list = raw.assumingMemoryBound(to: AudioBufferList.self).pointee
    return list.mNumberBuffers > 0 && list.mBuffers.mNumberChannels > 0
}

var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
for id in devices where hasInput(id) {
    let transport = uint32(id, kAudioDevicePropertyTransportType).map(fourCC) ?? "nil"
    let cls = uint32(id, kAudioObjectPropertyClass).map(fourCC) ?? "nil"
    print("#\(id) transport=\(transport) class=\(cls) name=\(string(id, kAudioObjectPropertyName)) uid=\(string(id, kAudioDevicePropertyDeviceUID))")
}
