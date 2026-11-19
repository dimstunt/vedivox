import AVFoundation
import Foundation
import os

/// One-shot re-encode of the stored archive to the storage preset — `vedivox audio compact`
/// (compact-meeting-storage § 3).
///
/// Lossy and irreversible, so it runs only on an explicit command, one meeting at a time
/// from the oldest, and swaps a track only after the copy passed `verify` and the shift
/// check. The swap is `replaceItemAt` under the same name: the database, paths and
/// waveform peaks stay as they are, and an interrupted run leaves every meeting playable.
/// A track already at or near the preset is skipped, so a second run changes nothing.
struct AudioCompactor: Sendable {
    struct ChangedDuringEncode: LocalizedError {
        var errorDescription: String? { "the track changed while it was being re-encoded (trimmed?) — run again" }
    }

    struct Report: Sendable {
        var dryRun: Bool
        var meetingsSeen = 0
        var meetingsBusy = 0
        /// `<meetingId>/<file>` re-encoded, or to be re-encoded in a dry run.
        var compacted: [String] = []
        var alreadyCompact = 0
        /// `<meetingId>/<file>: <reason>` — the original stayed in place.
        var failed: [String] = []
        /// Files the run noticed but does not touch: zero-size tracks, WAVs, `.bak`, `.preshift`.
        var anomalies: [String] = []
        var bytesBefore: Int64 = 0
        /// Measured after a real run; nominal preset size in a dry run.
        var bytesAfter: Int64 = 0
        /// Meetings left unprocessed (the current one included) because a recording started.
        var stoppedWithRemaining: Int?
        /// Refused: another run was in progress. Nothing was looked at.
        var alreadyRunning = false

        var complete: Bool { failed.isEmpty && stoppedWithRemaining == nil && !alreadyRunning }
    }

    /// 64 kbps nominal (`compressToAAC`); 20 % headroom keeps an already compact
    /// track from being re-encoded again.
    static let presetBitsPerSecond = 64_000.0
    static let compactThreshold = 1.2 * presetBitsPerSecond
    static let maxShift = 0.01

    let audioRoot: URL
    let dryRun: Bool
    /// Asked before each meeting and before each track it re-encodes; true stops the run.
    var isRecording: @Sendable () async -> Bool
    /// Re-read before each meeting: one that started processing since is skipped.
    var status: @Sendable (String) async -> MeetingStatus?
    var compress: @Sendable (URL, URL) async throws -> Void = { try await AudioConverter.compressToAAC(input: $0, output: $1) }

    /// One run at a time: two would write the same `<name>.compact.m4a`.
    private static let running = OSAllocatedUnfairLock(initialState: false)

    /// `meetingIds` oldest first.
    func run(meetingIds: [String]) async -> Report {
        var report = Report(dryRun: dryRun)
        guard Self.running.withLock({ busy in defer { busy = true }; return !busy }) else {
            report.alreadyRunning = true
            Log.info("Compact: another run is in progress — refused")
            return report
        }
        defer { Self.running.withLock { $0 = false } }

        for (index, id) in meetingIds.enumerated() {
            var stopped = await isRecording()
            if !stopped {
                report.meetingsSeen += 1
                if let current = await status(id), current == .done || current == .needsAttention {
                    stopped = await !compactMeeting(id, into: &report)
                } else {
                    report.meetingsBusy += 1
                }
            }
            if stopped {
                report.stoppedWithRemaining = meetingIds.count - index
                Log.info("Compact: a recording started — stopping with \(meetingIds.count - index) meeting(s) left")
                break
            }
        }
        Log.info("Compact\(dryRun ? " (dry run)" : ""): \(report.compacted.count) track(s), \(report.alreadyCompact) already compact, \(report.failed.count) failed, \(report.bytesBefore - report.bytesAfter) bytes freed")
        return report
    }

    /// False when a recording started: the run stops after the track in hand.
    private func compactMeeting(_ id: String, into report: inout Report) async -> Bool {
        let fm = FileManager.default
        let dir = audioRoot.appendingPathComponent(id, isDirectory: true)
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        for name in names {
            let file = dir.appendingPathComponent(name)
            let label = "\(id)/\(name)"
            if name.hasSuffix(".compact.m4a") {
                // Left by an interrupted run; the original next to it is intact.
                if !dryRun { try? fm.removeItem(at: file) }
                continue
            }
            if name.hasSuffix(".bak") || name.hasSuffix(".preshift") || name.hasSuffix(".wav") {
                report.anomalies.append(label)
                continue
            }
            guard name.hasSuffix(".m4a") else { continue }

            let size = Int64((try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0)
            guard size > 0 else {
                report.anomalies.append("\(label): zero size")
                continue
            }
            guard let audio = try? AVAudioFile(forReading: file), audio.length > 0 else {
                report.anomalies.append("\(label): unreadable")
                continue
            }
            let seconds = Double(audio.length) / audio.fileFormat.sampleRate
            guard Double(size * 8) / seconds > Self.compactThreshold else {
                report.alreadyCompact += 1
                continue
            }

            if dryRun {
                report.compacted.append(label)
                report.bytesBefore += size
                report.bytesAfter += Int64(seconds * Self.presetBitsPerSecond / 8)
                continue
            }

            // Per track, not per meeting: an hour-long track takes minutes to re-encode.
            if await isRecording() { return false }
            let temp = dir.appendingPathComponent(name.replacingOccurrences(of: ".m4a", with: ".compact.m4a"))
            let stamp = { (try? fm.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date }
            let original = stamp()
            do {
                try await compress(file, temp)
                try AudioConverter.verify(source: file, result: temp)
                let shift = try await AudioConverter.shift(of: temp, against: file)
                guard abs(shift) <= Self.maxShift else { throw AudioConverter.AudioIntegrityError.shifted(seconds: shift) }
                // A trim that rewrote the track meanwhile wins; verify alone misses a cut under 5 %.
                guard stamp() == original else { throw ChangedDuringEncode() }
                let after = Int64((try fm.attributesOfItem(atPath: temp.path)[.size] as? Int) ?? 0)
                _ = try fm.replaceItemAt(file, withItemAt: temp)
                report.compacted.append(label)
                report.bytesBefore += size
                report.bytesAfter += after
                Log.info("Compact: \(label) \(size / 1024) → \(after / 1024) KB")
            } catch {
                try? fm.removeItem(at: temp)
                report.failed.append("\(label): \(error.localizedDescription)")
                Log.error("Compact: \(label) kept as is — \(error.localizedDescription)")
            }
        }
        return true
    }
}

extension AudioCompactor.Report {
    /// Exit code follows `complete`: a failed track or a stop for a recording is
    /// not "done", even though everything else went through.
    var response: AppCommandResponse {
        if alreadyRunning {
            return .failure("A compact run is already in progress — wait for it to finish", reason: .notReady)
        }
        let bytes = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let approx = dryRun ? "≈" : ""
        var lines = [
            compacted.isEmpty
                ? "Nothing to compact."
                : "\(dryRun ? "Would compact" : "Compacted") \(compacted.count) track(s): "
                + "\(bytes(bytesBefore)) → \(approx)\(bytes(bytesAfter)), \(approx)\(bytes(bytesBefore - bytesAfter)) \(dryRun ? "to free" : "freed").",
            "Already compact: \(alreadyCompact). Meetings busy, skipped: \(meetingsBusy).",
        ]
        if !failed.isEmpty {
            lines.append("Failed, originals kept:")
            lines += failed.map { "  " + $0 }
        }
        if let left = stoppedWithRemaining {
            lines.append("Stopped: a recording started, \(left) meeting(s) left — run again when it is over.")
        }
        if !anomalies.isEmpty {
            lines.append("Not touched (clean up by hand if unwanted):")
            lines += anomalies.map { "  " + $0 }
        }
        var data = [
            "dry_run": dryRun ? "1" : "0",
            "tracks_compacted": "\(compacted.count)",
            "tracks_already_compact": "\(alreadyCompact)",
            "tracks_failed": "\(failed.count)",
            "meetings_busy": "\(meetingsBusy)",
            "bytes_before": "\(bytesBefore)",
            "bytes_after": "\(bytesAfter)",
            "bytes_freed": "\(bytesBefore - bytesAfter)",
            "failed": failed.joined(separator: "\n"),
            "anomalies": anomalies.joined(separator: "\n"),
        ]
        if let left = stoppedWithRemaining { data["meetings_left"] = "\(left)" }
        let reason: AppCommandResponse.Reason? = !failed.isEmpty ? .failed : stoppedWithRemaining != nil ? .notReady : nil
        return AppCommandResponse(ok: complete, message: lines.joined(separator: "\n"), reason: reason?.rawValue, data: data)
    }
}
