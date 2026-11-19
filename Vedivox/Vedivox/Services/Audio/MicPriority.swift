import CoreAudio
import Foundation

/// The microphone priority list: every input device Vedivox has seen,
/// in the user's order, and the recording takes the first one connected.
/// "System default" is an entry like any other — what sits below it is
/// never reached, since the system default is always there.
///
/// Off by default: with the toggle off the single `selectedMicDeviceUID`
/// picker decides, as before. The list is seeded from that picker the first
/// time it is read, so turning priority on keeps the mic the user chose.
///
/// Stored as JSON under `micPriorityList`, like `SystemCaptureExclusions`.
struct MicPriority: Codable, Equatable {
    struct Device: Codable, Equatable, Identifiable {
        /// Core Audio device UID; `""` is the system default (as in `selectedMicDeviceUID`).
        let uid: String
        var name: String
        /// Virtual drivers (Microsoft Teams Audio, BlackHole): listed, but new ones go last.
        var isVirtual = false
        var id: String { uid }
    }

    static let enabledKey = "micPriorityEnabled"
    static let listKey = "micPriorityList"
    static let systemDefault = Device(uid: "", name: "System default")

    var devices: [Device]

    /// The first entry that is connected; `nil` means the system default,
    /// also when nothing in the list is.
    func pick(connected: Set<String>) -> String? {
        for device in devices {
            if device.uid == Self.systemDefault.uid { return nil }
            if connected.contains(device.uid) { return device.uid }
        }
        return nil
    }

    /// Notes the devices connected now: a known one takes its current name, a
    /// new one goes to the end — a real mic before the trailing run of
    /// virtual ones, so a Teams or BlackHole driver never outranks it.
    mutating func remember(_ seen: [Device]) {
        for device in seen {
            if let index = devices.firstIndex(where: { $0.uid == device.uid }) {
                devices[index].name = device.name
                devices[index].isVirtual = device.isVirtual
            } else if device.isVirtual {
                devices.append(device)
            } else {
                let trailingVirtual = devices.reversed().prefix { $0.isVirtual }.count
                devices.insert(device, at: devices.count - trailingVirtual)
            }
        }
    }

    /// The list a user starts with: the mic picked in the single picker (named
    /// by its UID until it is seen), then the system default.
    static func seeded(selectedUID: String) -> MicPriority {
        let selected = selectedUID.isEmpty ? [] : [Device(uid: selectedUID, name: selectedUID)]
        return MicPriority(devices: selected + [systemDefault])
    }

    static func load(_ defaults: UserDefaults = .standard) -> MicPriority {
        if let data = defaults.data(forKey: listKey),
           let list = try? JSONDecoder().decode(MicPriority.self, from: data),
           list.devices.contains(where: { $0.uid == systemDefault.uid }) {
            return list
        }
        return seeded(selectedUID: defaults.string(forKey: "selectedMicDeviceUID") ?? "")
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.listKey) }
    }

    /// The inputs a recording may open, best first, `nil` for the system
    /// default; snapshotted at start and followed for the whole recording
    /// (`MicSwitchPolicy`). Priority off: the single picker, then the built-in
    /// mic, then the system default. On: the list down to "System default",
    /// after noting the devices connected now so the list grows as devices
    /// show up; the built-in mic stays the last resort for a system default
    /// that will not start.
    static func captureOrder(_ defaults: UserDefaults = .standard, connected: [Device]) -> [String?] {
        guard defaults.bool(forKey: enabledKey) else {
            let selected = defaults.string(forKey: "selectedMicDeviceUID") ?? ""
            return MicrophoneCapture.inputCandidates(selected: selected.isEmpty ? nil : selected)
        }
        var list = load(defaults)
        list.remember(connected)
        list.save(defaults)
        let listed: [String?] = list.devices.prefix { $0.uid != systemDefault.uid }.map(\.uid)
        let lastResort = listed.contains(MicrophoneCapture.builtInMicUID) ? [] : [MicrophoneCapture.builtInMicUID]
        return listed + [nil] + lastResort
    }

    /// Input devices connected now, aggregates left out — the system's private
    /// default-device aggregate and our own tap are not microphones.
    static func connectedInputs() -> [Device] {
        AudioObjectID.readAllAudioDevices().compactMap { deviceID in
            guard deviceID.hasInputStreams(),
                  let uid = try? deviceID.readDeviceUID(),
                  let name = deviceID.readDeviceName() else { return nil }
            let transport = deviceID.readTransportType()
            // Private aggregates exist only inside this process, so this is
            // the one place their transport type can be read.
            Log.debug("Input device: \(name) transport=\(transport.map(AudioObjectID.fourCC) ?? "nil") class=\(deviceID.readObjectClass().map(AudioObjectID.fourCC) ?? "nil") uid=\(uid)")
            guard !deviceID.isAggregateDevice() else { return nil }
            return Device(uid: uid, name: name, isVirtual: transport == kAudioDeviceTransportTypeVirtual)
        }
    }
}
