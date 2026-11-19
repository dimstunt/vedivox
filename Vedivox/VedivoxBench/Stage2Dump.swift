import Foundation
import GRDB

/// VEDIVOX_BENCH_STAGE2_DUMP=1: record every Stage-2 input of a scenario run — each
/// cluster's segments and centroid, the candidate pool as matched, the chunk
/// windows — plus the predicted segments, into
/// the private fixtures for offline analysis
/// (`scripts/stage2_diagnostics.py`). Read-only taps: the pipeline's decisions
/// are unchanged.
final class Stage2Dump {
    private var meetings: [[String: Any]] = []
    private var calls: [[String: Any]] = []
    private var chunks: [[String: Any]] = []

    static func fromEnvironment() -> Stage2Dump? {
        ProcessInfo.processInfo.environment["VEDIVOX_BENCH_STAGE2_DUMP"] == "1" ? Stage2Dump() : nil
    }

    func install() {
        SpeakerMatcher.inputProbe = { [self] clusters, pool in
            // Calls arrive in pipeline order: system (or import) track first, mic second.
            calls.append([
                "clusters": clusters.mapValues { segs -> [String: Any] in
                    [
                        "segments": segs.map { [Double($0.start), Double($0.end)] },
                        "centroid": Self.centroid(segs.compactMap(\.embedding)).map(Double.init),
                    ]
                },
                "pool": pool.map {
                    [
                        "id": $0.speakerId, "name": $0.displayName,
                        "segment_count": $0.segmentCount, "canonical": $0.canonical.map(Double.init),
                    ] as [String: Any]
                },
            ])
        }
        SegmentRescue.chunkProbe = { [self] windows in
            chunks = windows.map {
                [
                    "cluster": $0.speakerId, "start": Double($0.startTimeSeconds), "end": Double($0.endTimeSeconds),
                    "embedding": $0.embedding256.map(Double.init),
                ] as [String: Any]
            }
        }
    }

    func uninstall() {
        SpeakerMatcher.inputProbe = nil
        SegmentRescue.chunkProbe = nil
    }

    /// Close one meeting: attach what the probes saw and what the pipeline wrote.
    func finishMeeting(_ meetingId: String, dbm: DatabaseManager) async throws {
        let rows = try await dbm.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT startTime, endTime, speakerId, speakerLabel, source
                FROM transcript_segments WHERE meetingId = ? AND endTime > startTime
                ORDER BY startTime
                """, arguments: [meetingId]).map { row -> (Double, Double, String, String) in
                let id: String? = row["speakerId"]
                let label: String? = row["speakerLabel"]
                return (row["startTime"], row["endTime"], id ?? label ?? "UNKNOWN", row["source"] as String? ?? "")
            }
        }
        let predicted: [[String: Any]] = rows.map { ["start": $0.0, "end": $0.1, "key": $0.2, "source": $0.3] }
        meetings.append(["meeting": meetingId, "stage2_calls": calls, "chunks": chunks, "predicted": predicted])
        calls = []
        chunks = []
    }

    func write(repoRoot: URL, mode: String, fixture: String, dbm: DatabaseManager) async throws {
        let rows = try await dbm.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT id, nameEn, isMe, isConfirmed FROM speakers").map {
                ($0["id"] as String, $0["nameEn"] as String, $0["isMe"] as Bool, $0["isConfirmed"] as Bool)
            }
        }
        let speakers: [[String: Any]] = rows.map { ["id": $0.0, "name": $0.1, "is_me": $0.2, "confirmed": $0.3] }
        let dir = repoRoot.appendingPathComponent(".backlog/benchmarks/stage2")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(fixture)-\(mode).json")
        let body: [String: Any] = ["fixture": fixture, "mode": mode, "meetings": meetings, "speakers": speakers]
        try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]).write(to: url)
        print("[scenario-bench] stage-2 dump → \(url.path)")
    }

    /// Same vector the matcher's centroid fallback compares: L2-normalized mean.
    private static func centroid(_ embeddings: [[Float]]) -> [Float] {
        guard let dim = embeddings.first?.count else { return [] }
        var sum = [Float](repeating: 0, count: dim)
        for e in embeddings where e.count == dim {
            for i in 0 ..< dim { sum[i] += e[i] }
        }
        let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? sum.map { $0 / norm } : sum
    }
}
