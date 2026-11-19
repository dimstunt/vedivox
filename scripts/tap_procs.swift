#!/usr/bin/env swift
// Lists audio processes visible to Core Audio taps (same as what
// SystemAudioCapture sees when creating a tap).
// No TCC permission needed — enumeration is unrestricted.
//
// Usage: swift scripts/tap_procs.swift

import AppKit
import AudioToolbox
import CoreAudio
import Foundation

func readProcessObjectIDs() -> [AudioObjectID] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func readPID(_ id: AudioObjectID) -> pid_t {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var pid: pid_t = -1
    var size: UInt32 = UInt32(MemoryLayout<pid_t>.size)
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &pid)
    return pid
}

func readBundleID(_ id: AudioObjectID) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyBundleID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = UInt32(MemoryLayout<CFString>.size)
    var bundleID: CFString = "" as CFString
    let err = withUnsafeMutablePointer(to: &bundleID) {
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
    }
    guard err == noErr else { return nil }
    let s = bundleID as String
    return s.isEmpty ? nil : s
}

func readIsRunning(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var val: UInt32 = 0
    var size: UInt32 = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &val)
    return val != 0
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

let ids = readProcessObjectIDs()
let myPID = ProcessInfo.processInfo.processIdentifier

print("Total audio process objects: \(ids.count)")
print("")
print(pad("ObjectID", 10) + pad("PID", 8) + pad("Output?", 10) + pad("Input?", 10) + pad("BundleID", 45) + "App name")
print(String(repeating: "-", count: 120))

var outputCount = 0
for id in ids {
    let pid = readPID(id)
    guard pid > 0 else { continue }
    let bundleID = readBundleID(id) ?? "-"
    let isOut = readIsRunning(id, selector: kAudioProcessPropertyIsRunningOutput)
    let isIn = readIsRunning(id, selector: kAudioProcessPropertyIsRunningInput)
    let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "-"
    if isOut { outputCount += 1 }
    let marker = pid == myPID ? " (self)" : ""
    print(pad("\(id)", 10)
        + pad("\(pid)", 8)
        + pad(isOut ? "YES" : "no", 10)
        + pad(isIn ? "YES" : "no", 10)
        + pad(bundleID, 45)
        + appName + marker)
}

print("")
print("Summary: \(ids.count) total process objects, \(outputCount) currently outputting audio")
