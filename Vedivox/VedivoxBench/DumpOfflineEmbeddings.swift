import FluidAudio
import Foundation
import XCTest

/// stage 0: dump the offline diarizer's chunk-level WeSpeaker embeddings
/// and final segments for one fixture track, so the per-segment-rescue
/// separability analysis can run in Python against the GT and the migrated
/// canonical pool — BEFORE any production rescue code is written.
///
/// Uses FluidAudio's built-in `embeddingExportPath` (chunk × local-speaker
/// vectors with timings + final cluster id) and adds a segments/centroids dump.
/// Prod-config diarization (clustering.threshold 0.75).
///
///     TEST_RUNNER_VEDIVOX_DUMP_OFFLINE_EMBEDDINGS=1 xcodebuild test \
///       -project Vedivox/Vedivox.xcodeproj -scheme VedivoxBench \
///       -only-testing:VedivoxBench/DumpOfflineEmbeddingsTool -destination 'platform=macOS' \
///       -derivedDataPath build
///
/// Optional env: VEDIVOX_DUMP_AUDIO (default M5.system.m4a fixture track).
final class DumpOfflineEmbeddingsTool: XCTestCase {

    func testDumpOfflineEmbeddings() async throws {
        guard ProcessInfo.processInfo.environment["VEDIVOX_DUMP_OFFLINE_EMBEDDINGS"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_VEDIVOX_DUMP_OFFLINE_EMBEDDINGS=1 to dump offline chunk embeddings")
        }

        let repoRoot = Self.repoRoot()
        let audioPath = ProcessInfo.processInfo.environment["VEDIVOX_DUMP_AUDIO"]
            ?? repoRoot.appendingPathComponent(".backlog/fixtures/scenario_basic/audio/M5.system.m4a").path
        let outDir = repoRoot.appendingPathComponent(".backlog/audits/task043")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let stem = URL(fileURLWithPath: audioPath).deletingPathExtension().lastPathComponent

        var config = DiarizationService.makeOfflineConfig() // exactly what the pipeline diarizes with
        config.embeddingExportPath = outDir.appendingPathComponent("\(stem).chunks.json").path

        let offline = OfflineDiarizerManager(config: config)
        try await offline.prepareModels()

        log("processing \(audioPath)…")
        let result = try await offline.process(URL(fileURLWithPath: audioPath))

        let segments: [[String: Any]] = result.segments.map { seg in
            [
                "start": Double(seg.startTimeSeconds),
                "end": Double(seg.endTimeSeconds),
                "cluster": seg.speakerId,
            ]
        }
        let centroids: [String: [Double]] = (result.speakerDatabase ?? [:])
            .mapValues { $0.map { Double($0) } }
        let out: [String: Any] = [
            "generated_by": "DumpOfflineEmbeddings.swift (stage 0)",
            "audio": audioPath,
            "clustering_threshold": 0.75,
            "segments": segments,
            "cluster_centroids": centroids,
        ]
        let url = outDir.appendingPathComponent("\(stem).segments.json")
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        log("segments → \(url.path)")
        log("chunk embeddings → \(config.embeddingExportPath!)")
        log("clusters: \(Set(result.segments.map(\.speakerId)).sorted().joined(separator: ", "))")
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func log(_ msg: String) { print("[dump-offline-embeddings] \(msg)") }
}
