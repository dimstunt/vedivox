import AppKit
import CoreAudio
import Foundation

struct AudioProcessInfo: Sendable {
    let pid: pid_t
    let bundleIdentifier: String?
    let localizedName: String?
    let isRunningInput: Bool
    let isRunningOutput: Bool
}

struct AudioActivityMonitor: Sendable {

    /// Returns processes currently running audio IO.
    ///
    /// macOS 15+ uses the `AudioHardwareSystem` Swift API (replaces the broken
    /// `kAudioProcessPropertyDevices` C API that returns 0 on macOS 26). macOS 14
    /// falls back to the CoreAudio C process-object API.
    func activeAudioProcesses() -> [AudioProcessInfo] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var results: [AudioProcessInfo] = []

        if #available(macOS 15.0, *) {
            let system = AudioHardwareSystem.shared
            let processes: [AudioHardwareProcess]
            do {
                processes = try system.processes
            } catch {
                return []
            }

            for process in processes {
                do {
                    let pid = try process.pid
                    guard pid > 0, pid != selfPID, try process.isRunning else { continue }

                    let app = NSRunningApplication(processIdentifier: pid)
                    var bundleID = try? process.bundleID
                    let name = app?.localizedName

                    // WebKit.GPU is shared by many apps. Resolve parent from localizedName
                    // (e.g. "Safari Graphics and Media" → "com.apple.Safari").
                    if bundleID == "com.apple.WebKit.GPU", let name {
                        bundleID = resolveWebKitParentBundleId(from: name)
                    }

                    let isInput = (try? process.isRunningInput) ?? false
                    let isOutput = (try? process.isRunningOutput) ?? false

                    results.append(AudioProcessInfo(
                        pid: pid,
                        bundleIdentifier: bundleID ?? app?.bundleIdentifier,
                        localizedName: name,
                        isRunningInput: isInput,
                        isRunningOutput: isOutput
                    ))
                } catch {
                    continue
                }
            }
        } else {
            // macOS 14: the AudioHardwareProcess Swift API is 15+. Enumerate process
            // objects via the CoreAudio C API (kAudioHardwarePropertyProcessObjectList,
            // 14.0+) and read the IsRunning* flags directly.
            let processObjectIDs = (try? AudioObjectID.readAllProcessObjectIDs()) ?? []
            for objID in processObjectIDs {
                let pid = objID.readProcessPID()
                guard pid > 0, pid != selfPID else { continue }
                guard objID.readProcessBool(kAudioProcessPropertyIsRunning) else { continue }

                let app = NSRunningApplication(processIdentifier: pid)
                var bundleID = objID.readProcessBundleID()
                let name = app?.localizedName

                if bundleID == "com.apple.WebKit.GPU", let name {
                    bundleID = resolveWebKitParentBundleId(from: name)
                }

                let isInput = objID.readProcessBool(kAudioProcessPropertyIsRunningInput)
                let isOutput = objID.readProcessBool(kAudioProcessPropertyIsRunningOutput)

                results.append(AudioProcessInfo(
                    pid: pid,
                    bundleIdentifier: bundleID ?? app?.bundleIdentifier,
                    localizedName: name,
                    isRunningInput: isInput,
                    isRunningOutput: isOutput
                ))
            }
        }
        return results
    }

    /// Extracts parent app name from WebKit.GPU localizedName (e.g. "Safari Graphics and Media")
    /// and resolves it to a bundle ID via NSWorkspace.
    private func resolveWebKitParentBundleId(from localizedName: String) -> String? {
        // Format is "<AppName> Graphics and Media"
        guard let range = localizedName.range(of: " Graphics and Media") else { return nil }
        let appName = String(localizedName[..<range.lowerBound])
        guard !appName.isEmpty else { return nil }

        // Find running app with this name
        for app in NSWorkspace.shared.runningApplications where app.localizedName == appName {
            return app.bundleIdentifier
        }
        return nil
    }
}
