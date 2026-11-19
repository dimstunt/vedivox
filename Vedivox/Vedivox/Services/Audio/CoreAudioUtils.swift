import AudioToolbox
import Foundation

// MARK: - AudioObjectID Extensions for Core Audio Taps

extension AudioObjectID {

    /// Reads `kAudioHardwarePropertyProcessObjectList` from the system object.
    static func readAllProcessObjectIDs() throws -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize)
        guard err == noErr else {
            throw CoreAudioError.propertyReadFailed("ProcessObjectList size", err)
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        err = AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &objectIDs)
        guard err == noErr else {
            throw CoreAudioError.propertyReadFailed("ProcessObjectList data", err)
        }

        return objectIDs
    }

    /// Reads `kAudioHardwarePropertyDefaultSystemOutputDevice` from the system object.
    static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        let err = AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &deviceID)
        guard err == noErr else {
            throw CoreAudioError.propertyReadFailed("DefaultSystemOutputDevice", err)
        }
        return deviceID
    }

    /// Reads `kAudioHardwarePropertyDefaultOutputDevice` — where playback goes,
    /// unlike the system output device above, which carries alert sounds.
    static func readDefaultOutputDevice() -> AudioDeviceID? {
        readDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// Reads `kAudioHardwarePropertyDefaultInputDevice` — what an unbound
    /// engine records from ("System default" in the mic picker).
    static func readDefaultInputDevice() -> AudioDeviceID? {
        readDefaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func readDefaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        let err = AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &deviceID)
        guard err == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// `kAudioDevicePropertyMute` on the output's main element; nil when the
    /// device has no such control (many aggregate, virtual and HDMI outputs).
    func readOutputMute() -> Bool? {
        var address = Self.outputMuteAddress
        guard AudioObjectHasProperty(self, &address) else { return nil }
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &value)
        guard err == noErr else { return nil }
        return value != 0
    }

    /// Sets output mute; false when the control is missing or read-only.
    func writeOutputMute(_ muted: Bool) -> Bool {
        var address = Self.outputMuteAddress
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(self, &address),
              AudioObjectIsPropertySettable(self, &address, &settable) == noErr,
              settable.boolValue
        else { return false }
        var value: UInt32 = muted ? 1 : 0
        let err = AudioObjectSetPropertyData(
            self, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        )
        return err == noErr
    }

    private static var outputMuteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Reads `kAudioDevicePropertyDeviceUID` for this device.
    func readDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        var uid: CFString = "" as CFString
        let err = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, ptr)
        }
        guard err == noErr else {
            throw CoreAudioError.propertyReadFailed("DeviceUID", err)
        }
        return uid as String
    }

    /// Reads `kAudioTapPropertyFormat` for this tap object.
    func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var desc = AudioStreamBasicDescription()
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &desc)
        guard err == noErr else {
            throw CoreAudioError.propertyReadFailed("TapFormat", err)
        }
        return desc
    }

    /// Reads the nominal sample rate of this audio device.
    func readNominalSampleRate() -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        var rate: Float64 = 0
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &rate)
        guard err == noErr, rate > 0 else { return nil }
        return rate
    }

    // MARK: - Input Device Enumeration

    /// Reads all audio devices from the system.
    static func readAllAudioDevices() -> [AudioDeviceID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &devices) == noErr else {
            return []
        }
        return devices
    }

    /// Reads the human-readable name for this audio device.
    func readDeviceName() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        var name: CFString = "" as CFString
        let err = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, ptr)
        }
        guard err == noErr else { return nil }
        return name as String
    }

    /// Returns true if this device has input streams (i.e. is a microphone).
    func hasInputStreams() -> Bool {
        readInputChannelCount() > 0
    }

    /// Channels an IOProc on this device gets as input, over all of its input
    /// streams (`kAudioDevicePropertyStreamConfiguration`: one buffer per
    /// stream). 0 when it has none.
    func readInputChannelCount() -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return 0
        }
        let bufferListData = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListData.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, bufferListData) == noErr else {
            return 0
        }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferListData.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }

    /// The format an IOProc on this device gets its input in: the virtual
    /// format of the first input stream. nil when there is no such stream or
    /// it cannot be read.
    func readInputStreamFormat() -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioStreamID>.size) else {
            return nil
        }
        var streams = [AudioStreamID](repeating: kAudioObjectUnknown, count: Int(dataSize) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &streams) == noErr,
              let stream = streams.first else {
            return nil
        }
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var format = AudioStreamBasicDescription()
        guard AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &formatSize, &format) == noErr else {
            return nil
        }
        return format
    }

    /// `kAudioDevicePropertyTransportType` — `'grup'` for aggregate devices,
    /// `'bltn'` built-in, `'blue'` Bluetooth, `'virt'` virtual (BlackHole).
    func readTransportType() -> UInt32? {
        readUInt32(selector: kAudioDevicePropertyTransportType)
    }

    /// `kAudioDevicePropertyBufferFrameSize` — the device's IO cycle in frames.
    func readBufferFrameSize() -> UInt32? {
        readUInt32(selector: kAudioDevicePropertyBufferFrameSize)
    }

    /// `kAudioObjectPropertyClass` — `kAudioAggregateDeviceClassID` for aggregates.
    func readObjectClass() -> AudioClassID? {
        readUInt32(selector: kAudioObjectPropertyClass)
    }

    /// Aggregate devices are never a microphone a person meant to pick: the
    /// system's private `CADefaultDeviceAggregate-<pid>` under an unbound
    /// engine, our own `Vedivox-SystemTap`, or one built in Audio MIDI Setup
    /// Transport type or object class — either says so.
    func isAggregateDevice() -> Bool {
        readTransportType() == kAudioDeviceTransportTypeAggregate
            || readObjectClass() == kAudioAggregateDeviceClassID
    }

    /// `'grup'`, `'bltn'`, `'blue'`… — the way Core Audio spells these codes.
    static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(value)
    }

    private func readUInt32(selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &value)
        guard err == noErr else { return nil }
        return value
    }

    /// Translates a device UID string to an AudioDeviceID.
    static func deviceIDForUID(_ uid: String) -> AudioDeviceID? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString
        let err = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size), uidPtr, &dataSize, &deviceID)
        }
        guard err == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Reads `kAudioProcessPropertyPID` for this process object. Returns -1 on failure.
    func readProcessPID() -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        var pid: pid_t = -1
        AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &pid)
        return pid
    }

    /// Reads `kAudioProcessPropertyBundleID` for this process object.
    /// For bundleless daemons Core Audio reports the executable name
    /// (e.g. "systemsoundserverd"). Returns nil when empty/unreadable.
    func readProcessBundleID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        var bundleID: CFString = "" as CFString
        let err = withUnsafeMutablePointer(to: &bundleID) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, $0)
        }
        guard err == noErr else { return nil }
        let s = bundleID as String
        return s.isEmpty ? nil : s
    }

    /// Reads a boolean `kAudioProcessProperty*` flag (IsRunning / IsRunningInput /
    /// IsRunningOutput) for this process object. macOS 14.0+ C API — used on the
    /// pre-macOS-15 path where the `AudioHardwareProcess` Swift API is unavailable
    func readProcessBool(_ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &value)
        guard err == noErr else { return false }
        return value != 0
    }
}

enum CoreAudioError: Error, LocalizedError {
    case propertyReadFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .propertyReadFailed(let property, let status):
            "CoreAudio property read failed (\(property)): \(status)"
        }
    }
}
