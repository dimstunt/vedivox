import AVFoundation
import XCTest

/// Diagnostic (not a gate): mix M1's mic+system into ONE track and run our diarizer
/// on it, to see whether single-merged-track diarization produces cleaner,
/// non-overlapping segments than the two-stream pipeline (mic="me" + system diarized).
/// Compare the printed 55–85s window against the coarse two-stream ground truth.
final class DiagnoseMergedTrackTests: XCTestCase {
    func testDiarizeMergedM1() async throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VedivoxBench
            .deletingLastPathComponent() // Vedivox
            .deletingLastPathComponent() // repo root
        let audioDir = repo.appendingPathComponent(".backlog/fixtures/scenario_basic/audio")
        let mic = audioDir.appendingPathComponent("M1.mic.m4a")
        let sys = audioDir.appendingPathComponent("M1.system.m4a")
        guard FileManager.default.fileExists(atPath: mic.path) else {
            throw XCTSkip("M1 fixture audio not present")
        }

        // Mix mic + system → mono 16k wav (same recipe as pyannote_baseline.py).
        let mixed = FileManager.default.temporaryDirectory
            .appendingPathComponent("M1.mixed.\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: mixed) }
        let ff = Process()
        ff.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        ff.arguments = [
            "-y", "-loglevel", "error", "-i", mic.path, "-i", sys.path,
            "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=longest[out]",
            "-map", "[out]", "-ac", "1", "-ar", "16000", mixed.path,
        ]
        try ff.run()
        ff.waitUntilExit()
        XCTAssertEqual(ff.terminationStatus, 0, "ffmpeg mix failed")

        let result = try await DiarizationService().diarize(audioURL: mixed, knownSpeakers: [])
        let segs = result.segments.sorted { $0.start < $1.start }

        var byCluster: [String: Double] = [:]
        for s in segs { byCluster[s.speaker, default: 0] += Double(s.end - s.start) }

        var overlap = 0.0
        for i in 1 ..< max(1, segs.count) where segs[i].start < segs[i - 1].end {
            overlap += Double(min(segs[i].end, segs[i - 1].end) - segs[i].start)
        }

        print("[diagnose] MERGED M1: \(segs.count) segments, \(byCluster.count) clusters, adjacent overlap \(String(format: "%.1f", overlap))s")
        for (c, d) in byCluster.sorted(by: { $0.value > $1.value }) {
            print("[diagnose]   cluster \(c): \(String(format: "%.0f", d))s")
        }
        print("[diagnose]   segments in 55–85s window (compare vs coarse two-stream GT):")
        for s in segs where s.end > 55 && s.start < 85 {
            print(String(format: "[diagnose]     [%6.2f - %6.2f]  cluster %@", s.start, s.end, s.speaker))
        }
    }
}
