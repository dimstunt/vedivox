import ArgumentParser
import Foundation
import VedivoxMCPLib

/// `vedivox feedback` — one zip with what the owner needs to look into a problem.
///
/// Whitelist by construction: only the notes folder, `vedivox*.log` files and a
/// generated `system.txt` are staged, so the database and audio cannot end up
/// in the archive whatever lies in the data directory.
enum CLIFeedbackCore {
    static let warning = "logs contain meeting titles, speaker names and file paths — review the archive before sending"

    static func bundle(
        notesDir: URL,
        logsDir: URL,
        appBundle: URL,
        outputDir: URL,
        now: Date = Date(),
        json: Bool,
        db: () throws -> DatabaseReader
    ) throws -> String {
        let fm = FileManager.default
        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "vedivox-feedback-\(stampFormatter.string(from: now))"

        let tmp: URL
        do {
            tmp = try ScratchDirectory.make(prefix: "vedivox-feedback")
        } catch {
            throw CLIFailure.unavailable("could not stage the archive: \(error.message)")
        }
        let staging = tmp.appendingPathComponent(name, isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        var system: [String] = []
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)

            if fm.fileExists(atPath: notesDir.path) {
                try fm.copyItem(at: notesDir, to: staging.appendingPathComponent("feedback"))
            } else {
                system.append("feedback notes: none")
            }

            let logs = ((try? fm.contentsOfDirectory(atPath: logsDir.path)) ?? [])
                .filter { $0.hasPrefix("vedivox") && $0.hasSuffix(".log") }
            if logs.isEmpty {
                system.append("logs: none")
            } else {
                let logsOut = staging.appendingPathComponent("logs", isDirectory: true)
                try fm.createDirectory(at: logsOut, withIntermediateDirectories: true)
                for log in logs {
                    try fm.copyItem(at: logsDir.appendingPathComponent(log), to: logsOut.appendingPathComponent(log))
                }
            }

            let info = Bundle(url: appBundle)?.infoDictionary
            let version = (info?["CFBundleShortVersionString"] as? String).map {
                "\($0) (\(info?["CFBundleVersion"] as? String ?? "?"))"
            } ?? "not installed"
            let status: String
            do {
                status = try CLICommands.statusOverview(json: false, db: db(), now: now)
            } catch {
                status = "status unavailable: \(cliFailure(from: error).message)"
            }
            let text = [
                "vedivox: \(version)",
                "macos: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                "created: \(ISO8601DateFormatter().string(from: now))",
            ] + system + ["", status]
            // Not atomic: that goes through a scratch file in the system temp dir.
            try (text.joined(separator: "\n") + "\n")
                .write(to: staging.appendingPathComponent("system.txt"), atomically: false, encoding: .utf8)
        } catch {
            throw CLIFailure.unavailable("could not stage the archive: \(error.localizedDescription)")
        }

        let zip = outputDir.appendingPathComponent(name + ".zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // --norsrc --noextattr: otherwise ditto adds AppleDouble `._` entries.
        ditto.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent", staging.path, zip.path]
        let errPipe = Pipe()
        ditto.standardError = errPipe
        do {
            try ditto.run()
        } catch {
            throw CLIFailure.unavailable("could not run ditto: \(error.localizedDescription)")
        }
        let errText = String(bytes: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            let reason = errText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIFailure.unavailable("could not write \(zip.path): \(reason.isEmpty ? "ditto exit \(ditto.terminationStatus)" : reason)")
        }

        return json ? try cliJSON(["path": zip.path]) : zip.path
    }
}

struct Feedback: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "feedback",
        abstract: "Pack feedback notes, Vedivox logs and system info into a zip to send to whoever gave you Vedivox (no database, no audio)."
    )

    @Option(help: "Folder for the archive instead of the Desktop.")
    var output: String?

    @Flag(help: "Machine output: {\"path\"}.") var json = false

    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let outputDir = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? home.appendingPathComponent("Desktop", isDirectory: true)
        try executeCore {
            let path = try CLIFeedbackCore.bundle(
                notesDir: home.appendingPathComponent(".claude/vedivox/feedback", isDirectory: true),
                logsDir: VedivoxDataDirectory.root.appendingPathComponent("logs", isDirectory: true),
                appBundle: URL(fileURLWithPath: "/Applications/Vedivox.app"),
                outputDir: outputDir,
                json: json,
                db: { try DatabaseReader() }
            )
            FileHandle.standardError.write(Data(("vedivox: " + CLIFeedbackCore.warning + "\n").utf8))
            return path
        }
    }
}
