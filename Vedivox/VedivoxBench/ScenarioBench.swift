import Foundation
import GRDB

// MARK: - Fixture models (scenario.json / *.gt.json)

private struct ScenarioFile: Decodable {
    let name: String
    /// md-eval collar around reference boundaries (AMI convention 0.25s);
    /// absent = 0, how scenario_basic has always been scored.
    let collarSeconds: Double?
    let steps: [Step]
}

private struct Step: Decodable {
    let action: String
    let meeting: String
    let audioMic: String
    let audioSystem: String
    /// Reference: either the hand-checked `*.gt.json`, or an RTTM plus the
    /// scored window length (AMI ships RTTM + UEM; the UEM end goes here).
    let groundTruthJson: String?
    let groundTruthRttm: String?
    let windowLengthSeconds: Double?
    let crossMeetingCheck: [CrossCheck]?
}

private struct CrossCheck: Decodable {
    let prevMeeting: String
    let realSpeaker: String
}

private struct GroundTruth: Decodable {
    let windowLengthSeconds: Double
    let segments: [GTSeg]
}

private struct GTSeg: Decodable {
    let start: Double
    let end: Double
    let realSpeaker: String
}

// MARK: - Results

struct CrossCheckResult: Sendable {
    let realSpeaker: String
    let prevMeeting: String
    let ok: Bool
}

struct MeetingBenchResult: Sendable {
    let meeting: String
    let derSeconds: Double
    let missedSeconds: Double
    let falseAlarmSeconds: Double
    let confusionSeconds: Double
    let refSpeechSeconds: Double
    let crossChecks: [CrossCheckResult]
    /// real_speaker → dominant predicted key (speakerId or label) in this meeting.
    let realToPred: [String: String]
    /// Boundary localization + short-utterance metrics (see DERScorer.Result).
    let boundaryMAESeconds: Double?
    let refSpeakerChangeCount: Int
    let shortUtteranceRecall: Double?
    let shortUtteranceCount: Int
    let purity: Double
    let coverage: Double
    let predSpeakers: Int
    let refSpeakers: Int
    /// Speech attached to records that existed before the meeting (stage2-out-of-pool).
    var naming: NameAssignment.Result?
    /// segment-own-voice § 5: seconds share of segments whose stored vector is
    /// closest to its own person's meeting voice. nil — no embedded segments.
    var vectorPurity: Double?
}

private struct PredSeg: Sendable {
    let start: Double
    let end: Double
    let key: String
}

// MARK: - Runner

/// Drives the real `TranscriptionPipeline` over a scenario fixture against an
/// isolated in-memory DB + temp audio root, scores each meeting's DER against the
/// gold ground truth, checks cross-meeting speaker consistency, and writes a CSV
/// history row per meeting + a rich JSON for the run.
///
/// Headless: no app host, no production DB, no production audio folder touched.
struct ScenarioBenchRunner {
    let fixtureName: String
    /// `true` (cross_meeting): accumulate the enrolled pool across meetings (Stage 2
    /// identity matching active) and run cross-meeting consistency checks.
    /// `false` (stage1): never confirm speakers, so every meeting runs against an
    /// empty pool — Stage 2 abstains and we measure pure within-meeting clustering
    /// (what a FluidAudio version bump actually changes). See review finding H3.
    var enrollAcrossMeetings = true
    let frameStep = 0.01

    /// VEDIVOX_BENCH_SEED_CANONICALS=1: pre-seed the in-memory pool with the migrated
    /// prod WeSpeaker canonicals (canonicals_v2.json) before processing.
    /// This is the production-shaped pool the Stage-2.5 rescue runs
    /// against: the M5 speakers exist only there, and the 56-strong pool is the
    /// realistic lookalike-pressure test for rescue false positives. Without it
    /// the accumulated bench pool can't exercise rescue at all.
    private var seedCanonicals: Bool {
        excludeReferenceSpeakersFromSeed || seedLiveSnapshot || seedOwnerAsMe
            || ProcessInfo.processInfo.environment["VEDIVOX_BENCH_SEED_CANONICALS"] == "1"
    }

    /// stage2-dead-zone: seed with the read-only snapshot of the live pool
    /// (scripts/export_live_canonicals.py) instead of the June migration —
    /// today's pool, including its outlier profiles. Implies seeding.
    var seedLiveSnapshot = false

    /// stage2-mic-owner: mark the seeded owner record isMe, as in prod. Without
    /// an isMe record the pipeline never diarizes the mic, so mic-track Stage 2
    /// goes unmeasured in every other mode. Implies seeding.
    var seedOwnerAsMe = false

    private var seedFile: String {
        seedLiveSnapshot ? Self.liveSnapshotPath : ".backlog/audits/wespeaker_migration/canonicals_v2.json"
    }

    /// Local only (gitignored): voice embeddings of real people.
    static let liveSnapshotPath = ".backlog/audits/live_canonicals_20261101.json"

    /// Whether the local live snapshot exists — the `_live` scenarios skip without it.
    static func liveSnapshotPresent() -> Bool {
        FileManager.default.fileExists(atPath: repoRoot().appendingPathComponent(liveSnapshotPath).path)
    }

    /// stage2-out-of-pool: seed the pool WITHOUT the scenario's reference speakers
    /// (the owner stays, as in prod). Most clusters are then people outside a
    /// 40-odd-strong pool — the case where Stage 2 hands a newcomer someone
    /// else's name. Implies seeding.
    var excludeReferenceSpeakersFromSeed = false

    private var mode: String {
        (enrollAcrossMeetings ? "cross_meeting" : "stage1") + (seedCanonicals ? "_seeded" : "")
            + (excludeReferenceSpeakersFromSeed ? "_absent" : "") + (seedLiveSnapshot ? "_live" : "")
            + (seedOwnerAsMe ? "_me" : "")
    }

    /// Real names stay with the fixtures, not in the source:
    /// the private fixtures names the owner's record and maps a
    /// live-pool record name to the reference's name for the same person (a
    /// record labeled with the full name where the ground truth uses the short one).
    private struct Identities: Decodable {
        var owner = "me"
        var aliases: [String: String] = [:]
    }

    private static let identities = (try? decode(
        Identities.self, repoRoot().appendingPathComponent(".backlog/fixtures/identities.json")
    )) ?? Identities()
    private static var ownerName: String { identities.owner }
    private static var referenceAliases: [String: String] { identities.aliases }

    func run() async throws {
        // [Perf] lines (PerfTrace) are debug-level; the bench log wants them.
        Log.level = .debug
        let repoRoot = Self.repoRoot()
        let fixtureDir = repoRoot
            .appendingPathComponent(".backlog/fixtures")
            .appendingPathComponent(fixtureName)

        let scenario = try Self.decode(ScenarioFile.self, fixtureDir.appendingPathComponent("scenario.json"))

        // Isolated state: fresh in-memory DB + throwaway audio root.
        let dbm = try DatabaseManager(inMemory: true)
        let audioRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedivox-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: audioRoot) }

        let pipeline = TranscriptionPipeline(db: dbm, audioRoot: audioRoot, compressAudio: false)
        let meetingRepo = MeetingRepository(db: dbm)

        // Speaker record → reference speaker it stands for: seeded records by
        // name, bench-minted ones by their dominant voice in the birth meeting.
        var identities: [String: String] = [:]
        if seedCanonicals {
            let exclude: Set<String> = excludeReferenceSpeakersFromSeed
                ? try Set(scenario.steps.filter { $0.action == "process" }
                    .flatMap { try Self.groundTruth($0, fixtureDir).segments.map(\.realSpeaker) })
                : []
            let seeded = try await Self.seedCanonicalPool(
                dbm: dbm, repoRoot: repoRoot, file: seedFile, excluding: exclude
            )
            for (id, name) in seeded {
                identities[id] = name == Self.ownerName ? "me" : Self.referenceAliases[name, default: name]
            }
            if seedOwnerAsMe {
                try await dbm.writer.write { db in
                    try db.execute(sql: "UPDATE speakers SET isMe = 1 WHERE nameEn = ?", arguments: [Self.ownerName])
                }
            }
            log("seeded \(seeded.count) prod canonicals (\((seedFile as NSString).lastPathComponent)) into the pool"
                + (exclude.isEmpty ? "" : ", reference speakers left out"))
        }

        let stage2Dump = Stage2Dump.fromEnvironment()
        stage2Dump?.install()
        defer { stage2Dump?.uninstall() }

        var results: [MeetingBenchResult] = []
        var realToPredByMeeting: [String: [String: String]] = [:]

        for step in scenario.steps where step.action == "process" {
            let mic = fixtureDir.appendingPathComponent(step.audioMic)
            let sys = fixtureDir.appendingPathComponent(step.audioSystem)
            for url in [mic, sys] where !FileManager.default.fileExists(atPath: url.path) {
                throw BenchError.missingAudio(url.path)
            }

            // Register the meeting so the pipeline's FK-bound writes succeed.
            try await meetingRepo.save(Meeting(
                id: step.meeting,
                title: "[bench] \(step.meeting)",
                startTime: Date(),
                source: .recording,
                micAudioPath: mic.path,
                systemAudioPath: sys.path,
                status: .recording
            ))

            let existingRecords = Set(identities.keys)
            log("processing \(step.meeting)…")
            try await pipeline.processMeeting(
                meetingId: step.meeting,
                micAudioURL: mic,
                systemAudioURL: sys
            )

            // Emulate the UI "confirm speaker" action so the next meeting can match
            // these speakers cross-meeting (Stage 2 only considers isConfirmed=1).
            // Skipped in stage1 mode: the pool stays empty → pure within-meeting
            // clustering, isolating what a FluidAudio bump changes (review H3).
            if enrollAcrossMeetings {
                try await dbm.writer.write { db in
                    try db.execute(
                        sql: """
                        UPDATE speakers SET isConfirmed = 1
                        WHERE id IN (
                            SELECT DISTINCT speakerId FROM transcript_segments
                            WHERE meetingId = ? AND speakerId IS NOT NULL
                        )
                        """,
                        arguments: [step.meeting]
                    )
                }
            }

            try await stage2Dump?.finishMeeting(step.meeting, dbm: dbm)
            let predicted = try await Self.predictedSegments(dbm: dbm, meetingId: step.meeting)
            let gt = try Self.groundTruth(step, fixtureDir)

            // Diagnostic: how many distinct predicted speakers vs ground truth.
            // A multi-speaker meeting collapsing to ~1 pred speaker = FluidAudio
            // under-clustering (or Stage-2 over-matching to a small enrolled pool).
            let predDur = Dictionary(grouping: predicted, by: \.key)
                .mapValues { $0.reduce(0.0) { $0 + ($1.end - $1.start) } }
            let gtSpeakers = Set(gt.segments.map(\.realSpeaker)).count
            log("  pred speakers (\(predDur.count) vs gt \(gtSpeakers)): "
                + predDur.sorted { $0.value > $1.value }
                    .map { "\($0.key.prefix(8))=\(Int($0.value))s" }.joined(separator: ", "))

            var scored = score(
                predicted: predicted,
                gt: gt,
                step: step,
                collar: scenario.collarSeconds ?? 0,
                realToPredByMeeting: realToPredByMeeting
            )
            let predSegs = predicted.map { DERScorer.Segment(start: $0.start, end: $0.end, key: $0.key) }
            let refSegs = gt.segments.map { DERScorer.Segment(start: $0.start, end: $0.end, key: $0.realSpeaker) }
            scored.naming = NameAssignment.score(
                predicted: predSegs, reference: refSegs, identities: identities, existing: existingRecords
            )
            for (key, speaker) in NameAssignment.dominantSpeakers(predicted: predSegs, reference: refSegs)
                where identities[key] == nil && UUID(uuidString: key) != nil {
                identities[key] = speaker
            }
            realToPredByMeeting[step.meeting] = scored.realToPred
            var withVectors = scored
            withVectors.vectorPurity = DERScorer.vectorPurity(
                segments: try await Self.vectorSegments(dbm: dbm, meetingId: step.meeting),
                reference: gt.segments.map { DERScorer.Segment(start: $0.start, end: $0.end, key: $0.realSpeaker) }
            )
            results.append(withVectors)

            let checkStr = scored.crossChecks.map { "\($0.realSpeaker)=\($0.ok ? "ok" : "FAIL")" }.joined(separator: "; ")
            let maeStr = scored.boundaryMAESeconds.map {
                String(format: "  bMAE %.2fs/%d", $0, scored.refSpeakerChangeCount)
            } ?? ""
            let shortStr = scored.shortUtteranceRecall.map {
                String(format: "  shortR %.0f%%/%d", $0 * 100, scored.shortUtteranceCount)
            } ?? ""
            log(String(
                format: "  %@: DER %.1fs (miss %.1f / FA %.1f / conf %.1f of %.0fs speech)  purity %.3f coverage %.3f  spk %d/%d  vpurity %@%@%@%@",
                step.meeting, scored.derSeconds, scored.missedSeconds, scored.falseAlarmSeconds,
                scored.confusionSeconds, scored.refSpeechSeconds,
                scored.purity, scored.coverage, scored.predSpeakers, scored.refSpeakers,
                withVectors.vectorPurity.map { String(format: "%.3f", $0) } ?? "-",
                maeStr, shortStr,
                checkStr.isEmpty ? "" : "  cross[\(checkStr)]"
            ))
            if let n = scored.naming {
                log(String(format: "  %@: names on existing records — right %.1fs / wrong %.1fs, false assignments %d of %d",
                           step.meeting, n.rightSeconds, n.wrongSeconds, n.falseAssignments, n.assignedRecords))
            }
        }

        try writeOutputs(repoRoot: repoRoot, results: results)
        try await stage2Dump?.write(repoRoot: repoRoot, mode: mode, fixture: fixtureName, dbm: dbm)
        reportFindings(results)
    }

    // MARK: - Scoring (DER + cross-meeting)

    private func score(
        predicted: [PredSeg],
        gt: GroundTruth,
        step: Step,
        collar: Double,
        realToPredByMeeting: [String: [String: String]]
    ) -> MeetingBenchResult {
        // Overlap-aware multi-label scoring — overlapping pred
        // segments (mic + system tracks) score as concurrent speakers instead of
        // collapsing to an arbitrary last-writer label. See DERScorer for the math.
        let scored = DERScorer(frameStep: frameStep).score(
            predicted: predicted.map { DERScorer.Segment(start: $0.start, end: $0.end, key: $0.key) },
            reference: gt.segments.map { DERScorer.Segment(start: $0.start, end: $0.end, key: $0.realSpeaker) },
            windowLengthSeconds: gt.windowLengthSeconds,
            collarSeconds: collar
        )
        let realToPred = scored.realToPred

        var checks: [CrossCheckResult] = []
        for c in enrollAcrossMeetings ? (step.crossMeetingCheck ?? []) : [] {
            let here = realToPred[c.realSpeaker]
            let there = realToPredByMeeting[c.prevMeeting]?[c.realSpeaker]
            // Injective: the speaker's pred id must be hers alone in this meeting.
            // Otherwise a degenerate collapse (everyone → one id) trivially "passes".
            let sharedWith = realToPred.values.filter { $0 == here }.count
            let ok = here != nil && there != nil && here == there && sharedWith == 1
            checks.append(CrossCheckResult(realSpeaker: c.realSpeaker, prevMeeting: c.prevMeeting, ok: ok))
        }

        return MeetingBenchResult(
            meeting: step.meeting,
            derSeconds: scored.derSeconds,
            missedSeconds: scored.missedSeconds,
            falseAlarmSeconds: scored.falseAlarmSeconds,
            confusionSeconds: scored.confusionSeconds,
            refSpeechSeconds: scored.refSpeechSeconds,
            crossChecks: checks,
            realToPred: realToPred,
            boundaryMAESeconds: scored.boundaryMAESeconds,
            refSpeakerChangeCount: scored.refSpeakerChangeCount,
            shortUtteranceRecall: scored.shortUtteranceRecall,
            shortUtteranceCount: scored.shortUtteranceCount,
            purity: scored.purity,
            coverage: scored.coverage,
            predSpeakers: Set(predicted.map(\.key)).count,
            refSpeakers: Set(gt.segments.map(\.realSpeaker)).count
        )
    }

    // MARK: - Canonical pool seeding

    /// Insert the migrated prod canonicals as confirmed enrolled speakers with
    /// `embeddingV2` (WeSpeaker space — what the offline path's Stage 2/2.5
    /// matches against). Each gets 5 placeholder segments in a dummy [SEED]
    /// meeting so the `minSegmentsForCanonical` pool filters don't drop them;
    /// the placeholders carry no embeddings and the meeting is never scored.
    private static func seedCanonicalPool(
        dbm: DatabaseManager,
        repoRoot: URL,
        file: String,
        excluding excluded: Set<String>
    ) async throws -> [(id: String, name: String)] {
        struct Report: Decodable {
            struct Entry: Decodable {
                let speakerId: String
                let name: String
                let status: String
                let embeddingV2: [Float]?
            }

            let speakers: [Entry]
        }
        let url = repoRoot.appendingPathComponent(file)
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let entries = try dec.decode(Report.self, from: Data(contentsOf: url)).speakers
            .filter { $0.status == "ok" && !excluded.contains($0.name) }
        let seeded = entries.compactMap { e in e.embeddingV2.map { (e.speakerId, e.name, Speaker.encodeEmbedding($0)) } }

        try await dbm.writer.write { db in
            try db.execute(sql: """
                INSERT INTO meetings (id, title, startTime, status)
                VALUES ('SEED', '[SEED] canonical pool', '2000-01-01 00:00:00', 'done')
                """)
            for (id, name, blob) in seeded {
                try db.execute(
                    sql: "INSERT INTO speakers (id, nameEn, isConfirmed, embeddingV2) VALUES (?, ?, 1, ?)",
                    arguments: [id, name, blob]
                )
                for i in 0 ..< 5 {
                    try db.execute(sql: """
                        INSERT INTO transcript_segments (meetingId, speakerId, source, startTime, endTime, text)
                        VALUES ('SEED', ?, 'system', ?, ?, 'seed')
                        """, arguments: [id, Double(i), Double(i) + 0.1])
                }
            }
        }
        return seeded.map { (id: $0.0, name: $0.1) }
    }

    // MARK: - DB read

    private static func predictedSegments(dbm: DatabaseManager, meetingId: String) async throws -> [PredSeg] {
        try await dbm.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT startTime, endTime, speakerId, speakerLabel
                FROM transcript_segments
                WHERE meetingId = ? AND endTime > startTime
                ORDER BY startTime
                """, arguments: [meetingId])
                .map { row in
                    let id: String? = row["speakerId"]
                    let label: String? = row["speakerLabel"]
                    return PredSeg(
                        start: row["startTime"],
                        end: row["endTime"],
                        key: id ?? label ?? "UNKNOWN"
                    )
                }
        }
    }

    private static func vectorSegments(dbm: DatabaseManager, meetingId: String) async throws -> [DERScorer.VectorSegment] {
        try await dbm.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT startTime, endTime, embedding FROM transcript_segments
                WHERE meetingId = ? AND endTime > startTime AND embedding IS NOT NULL
                """, arguments: [meetingId])
                .compactMap { row in
                    let vector = Speaker.decodeEmbedding(row["embedding"] as Data)
                    guard vector.count == 256 else { return nil }
                    return DERScorer.VectorSegment(start: row["startTime"], end: row["endTime"], vector: vector)
                }
        }
    }

    // MARK: - Output

    private func writeOutputs(repoRoot: URL, results: [MeetingBenchResult]) throws {
        let benchDir = repoRoot.appendingPathComponent(".backlog/benchmarks")
        let runsDir = benchDir.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)

        let env = ProcessInfo.processInfo.environment
        let commit = env["BENCH_COMMIT"] ?? Self.git(repoRoot, ["rev-parse", "--short", "HEAD"]) ?? "unknown"
        let branch = env["BENCH_BRANCH"] ?? Self.git(repoRoot, ["rev-parse", "--abbrev-ref", "HEAD"]) ?? "unknown"
        let iso = ISO8601DateFormatter()
        let timestamp = iso.string(from: Date())

        // CSV (append; write header if new)
        let csv = benchDir.appendingPathComponent("scenario_history.csv")
        // Columns boundary_mae / short_recall appended 2026-06-12 (Tier-1
        // metrics) — older rows simply have fewer fields.
        let header = "timestamp,commit,branch,scenario,mode,meeting,der_seconds,missed,false_alarm,confusion,cross_meeting_ok,boundary_mae,short_recall,purity,coverage,pred_speakers,ref_speakers,right_name,wrong_name,false_assign,vector_purity\n"
        if !FileManager.default.fileExists(atPath: csv.path) {
            try header.write(to: csv, atomically: true, encoding: .utf8)
        }
        let handle = try FileHandle(forWritingTo: csv)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for r in results {
            let checks = r.crossChecks.map { "\($0.realSpeaker):\($0.ok ? "ok" : "FAIL")" }.joined(separator: " ")
            let mae = r.boundaryMAESeconds.map { String(format: "%.3f", $0) } ?? ""
            let short = r.shortUtteranceRecall.map { String(format: "%.3f", $0) } ?? ""
            let naming = r.naming.map {
                String(format: "%.2f,%.2f,%d", $0.rightSeconds, $0.wrongSeconds, $0.falseAssignments)
            } ?? ",,"
            let vpurity = r.vectorPurity.map { String(format: "%.3f", $0) } ?? ""
            let line = String(format: "%@,%@,%@,%@,%@,%@,%.2f,%.2f,%.2f,%.2f,%@,%@,%@,%.3f,%.3f,%d,%d,%@,%@\n",
                              timestamp, commit, branch, fixtureName, mode, r.meeting,
                              r.derSeconds, r.missedSeconds, r.falseAlarmSeconds, r.confusionSeconds, checks,
                              mae, short, r.purity, r.coverage, r.predSpeakers, r.refSpeakers, naming, vpurity)
            try handle.write(contentsOf: Data(line.utf8))
        }

        // Rich JSON for this run
        var run: [String: Any] = [
            "timestamp": timestamp, "commit": commit, "branch": branch, "scenario": fixtureName, "mode": mode,
        ]
        run["meetings"] = results.map { r -> [String: Any] in
            var entry: [String: Any] = [
                "meeting": r.meeting,
                "der_seconds": r.derSeconds,
                "missed_seconds": r.missedSeconds,
                "false_alarm_seconds": r.falseAlarmSeconds,
                "confusion_seconds": r.confusionSeconds,
                "ref_speech_seconds": r.refSpeechSeconds,
                "der_pct": r.refSpeechSeconds > 0 ? r.derSeconds / r.refSpeechSeconds * 100 : 0,
                "real_to_pred": r.realToPred,
                "cross_checks": r.crossChecks.map { ["real_speaker": $0.realSpeaker, "prev_meeting": $0.prevMeeting, "ok": $0.ok] },
                "ref_speaker_changes": r.refSpeakerChangeCount,
                "short_utterances": r.shortUtteranceCount,
                "purity": r.purity,
                "coverage": r.coverage,
                "pred_speakers": r.predSpeakers,
                "ref_speakers": r.refSpeakers,
            ]
            if let mae = r.boundaryMAESeconds { entry["boundary_mae_seconds"] = mae }
            if let recall = r.shortUtteranceRecall { entry["short_utterance_recall"] = recall }
            if let n = r.naming {
                entry["right_name_seconds"] = n.rightSeconds
                entry["wrong_name_seconds"] = n.wrongSeconds
                entry["false_assignments"] = n.falseAssignments
                entry["assigned_records"] = n.assignedRecords
            }
            if let vpurity = r.vectorPurity { entry["vector_purity"] = vpurity }
            return entry
        }
        let safeTs = timestamp.replacingOccurrences(of: ":", with: "-")
        let jsonURL = runsDir.appendingPathComponent("\(commit)-\(mode)-\(safeTs).json")
        let data = try JSONSerialization.data(withJSONObject: run, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: jsonURL)
        log("wrote \(csv.lastPathComponent) (+\(results.count) rows) and runs/\(jsonURL.lastPathComponent)")
    }

    /// Report-only (NOT a pass/fail gate). DER and cross-meeting results are logged
    /// and written to CSV/JSON for trend comparison against the committed baseline;
    /// the test does not XCTFail on them because multi-speaker DER is nondeterministic
    /// run-to-run (FluidAudio clustering; the bench notes noise floor /).
    /// Turning a deterministic subset into a real assertion is deferred to 038.07.
    private func reportFindings(_ results: [MeetingBenchResult]) {
        for r in results {
            for c in r.crossChecks where !c.ok {
                log("⚠️ cross-meeting FAIL: \(c.realSpeaker) not consistent with \(c.prevMeeting) in \(r.meeting)")
            }
        }
    }

    // MARK: - Helpers

    private static func groundTruth(_ step: Step, _ fixtureDir: URL) throws -> GroundTruth {
        if let json = step.groundTruthJson {
            return try decode(GroundTruth.self, fixtureDir.appendingPathComponent(json))
        }
        guard let rttm = step.groundTruthRttm, let window = step.windowLengthSeconds else {
            throw BenchError.noGroundTruth(step.meeting)
        }
        let text = try String(contentsOf: fixtureDir.appendingPathComponent(rttm), encoding: .utf8)
        return GroundTruth(windowLengthSeconds: window, segments: parseRTTM(text))
    }

    /// `SPEAKER <file> <chan> <start> <dur> <NA> <NA> <speaker> <NA> <NA>`
    private static func parseRTTM(_ text: String) -> [GTSeg] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(whereSeparator: \.isWhitespace)
            guard f.count >= 8, f[0] == "SPEAKER", let start = Double(f[3]), let dur = Double(f[4]) else { return nil }
            return GTSeg(start: start, end: start + dur, realSpeaker: String(f[7]))
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(T.self, from: data)
    }

    private static func git(_ repoRoot: URL, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repoRoot.path] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }

    /// Whether the (gitignored) fixture audio is present. Lets the test skip
    /// gracefully on a fresh clone that hasn't cut the audio yet.
    static func fixtureAudioPresent(_ fixtureName: String) -> Bool {
        let dir = repoRoot().appendingPathComponent(".backlog/fixtures").appendingPathComponent(fixtureName)
        guard let scenario = try? decode(ScenarioFile.self, dir.appendingPathComponent("scenario.json")) else {
            return false
        }
        return scenario.steps.allSatisfy { step in
            [step.audioMic, step.audioSystem].allSatisfy {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
        }
    }

    /// Repo root from this source file's path: .../vedivox/Vedivox/VedivoxBench/ScenarioBench.swift
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VedivoxBench
            .deletingLastPathComponent() // Vedivox
            .deletingLastPathComponent() // repo root
    }

    private func log(_ msg: String) { print("[scenario-bench] \(msg)") }

    enum BenchError: Error, LocalizedError {
        case missingAudio(String)
        case noGroundTruth(String)
        var errorDescription: String? {
            switch self {
            case .missingAudio(let p): "fixture audio not found: \(p) — cut audio first (see RUNBOOK)"
            case .noGroundTruth(let m): "\(m): set ground_truth_json, or ground_truth_rttm + window_length_seconds"
            }
        }
    }
}
