import AVFoundation
import Foundation
import GRDB

struct MeetingRepository {
    private let db: DatabaseManager

    init(db: DatabaseManager = .shared) {
        self.db = db
    }

    // MARK: - Meetings

    func all() async throws -> [Meeting] {
        try await db.reader.read { db in
            try Meeting
                .order(Meeting.Columns.startTime.desc)
                .fetchAll(db)
        }
    }

    func find(_ id: String) async throws -> Meeting? {
        try await db.reader.read { db in
            try Meeting.fetchOne(db, key: id)
        }
    }

    func save(_ meeting: Meeting) async throws {
        try await db.writer.write { db in
            try meeting.save(db)
        }
    }

    /// Insert a new meeting and give it a series by auto-rule right away — a
    /// meeting nobody renames used to stay outside its series.
    func create(_ meeting: Meeting) async throws {
        try await save(meeting)
        try? await SeriesRepository(db: db).applyAutoRule(meetingId: meeting.id, title: meeting.title)
    }

    /// Sets the given track paths and nothing else. The pipeline holds its
    /// copy of the meeting for as long as compression takes; writing the whole
    /// row back undid a rename made meanwhile.
    func updateAudioPaths(_ id: String, mic: String? = nil, system: String? = nil) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE meetings SET micAudioPath = COALESCE(?, micAudioPath),
                        systemAudioPath = COALESCE(?, systemAudioPath)
                    WHERE id = ?
                    """,
                arguments: [mic, system, id]
            )
        }
    }

    /// The reason belongs to the status it came with: any other status clears it.
    func updateStatus(_ id: String, status: MeetingStatus, reason: String? = nil) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE meetings SET status = ?, statusReason = ? WHERE id = ?",
                arguments: [status.rawValue, reason, id]
            )
        }
    }

    /// Record which diarizer produced this meeting's segment embeddings
    /// ('online'/'offline') — the space marker the dual canonical pools key on
    /// Set on every (re)process, since reprocessing rewrites segments.
    func setDiarizer(_ id: String, kind: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE meetings SET diarizer = ? WHERE id = ?",
                arguments: [kind, id]
            )
        }
    }

    /// Records what was decided about foreign voices on this meeting's mic
    /// track. A display property: it takes effect immediately, without a
    /// reprocess, and outlives any later change of the default setting.
    func updateForeignVoiceDecision(_ id: String, _ decision: ForeignVoiceDecision) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE meetings SET foreignVoiceDecision = ? WHERE id = ?",
                arguments: [decision.rawValue, id]
            )
        }
    }

    func updateEndTime(_ id: String, endTime: Date, duration: Double) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE meetings SET endTime = ?, durationSeconds = ? WHERE id = ?",
                arguments: [endTime, duration, id]
            )
        }
    }

    /// A meeting a quit or a crash left without its end gets it from the
    /// track's length; a duration the stop did write is kept.
    func fillMissingDuration(_ id: String, from track: URL) async {
        guard let meeting = try? await find(id), meeting.durationSeconds == nil,
              let seconds = await Self.audioSeconds(track) else { return }
        try? await updateEndTime(id, endTime: meeting.startTime.addingTimeInterval(seconds), duration: seconds)
    }

    /// Measured the way `AudioConverter.mergeAudio` measures the parts it joins.
    private static func audioSeconds(_ url: URL) async -> Double? {
        guard FileManager.default.fileExists(atPath: url.path),
              let seconds = try? await AVURLAsset(url: url).load(.duration).seconds,
              seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    func delete(_ id: String) async throws {
        try await deleteBatch([id])
    }

    func deleteBatch(_ ids: Set<String>) async throws {
        guard !ids.isEmpty else { return }
        try await db.writer.write { db in
            for id in ids {
                // The meeting's unconfirmed speakers go with it; one in
                // a meeting still ahead in the batch goes on that meeting's turn.
                try Self.deleteSegmentsAndSpeakers(db, meetingId: id)
                try db.execute(sql: "DELETE FROM meeting_tags WHERE meetingId = ?", arguments: [id])
                _ = try Meeting.deleteOne(db, key: id)
            }
        }
    }

    func deleteSegments(for meetingId: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM transcript_segments WHERE meetingId = ?",
                arguments: [meetingId]
            )
        }
    }

    /// Delete segments, meeting_speakers links, and orphaned speakers for a meeting atomically.
    /// Speakers shared with other meetings are preserved, and so is anyone a
    /// person named (confirmed) or `isMe`: reprocess re-diarizes, it must not
    /// forget who someone is. Only unconfirmed per-meeting `speaker_N` rows go.
    func deleteSegmentsAndSpeakers(for meetingId: String) async throws {
        try await db.writer.write { db in
            try Self.deleteSegmentsAndSpeakers(db, meetingId: meetingId)
        }
    }

    private static func deleteSegmentsAndSpeakers(_ db: Database, meetingId: String) throws {
        try db.execute(
            sql: "DELETE FROM transcript_segments WHERE meetingId = ?",
            arguments: [meetingId]
        )

        let orphanSpeakerIds = try String.fetchAll(db, sql: """
            SELECT ms.speakerId FROM meeting_speakers ms
            WHERE ms.meetingId = ?
            AND ms.speakerId NOT IN (
                SELECT speakerId FROM meeting_speakers WHERE meetingId != ?
            )
            AND ms.speakerId NOT IN (
                SELECT speakerId FROM transcript_segments WHERE speakerId IS NOT NULL
            )
            AND ms.speakerId IN (
                SELECT id FROM speakers WHERE isConfirmed = 0 AND isMe = 0
            )
            """, arguments: [meetingId, meetingId])

        try db.execute(
            sql: "DELETE FROM meeting_speakers WHERE meetingId = ?",
            arguments: [meetingId]
        )

        if !orphanSpeakerIds.isEmpty {
            let placeholders = orphanSpeakerIds.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM speakers WHERE id IN (\(placeholders))",
                arguments: StatementArguments(orphanSpeakerIds)
            )
        }
    }

    // MARK: - Segments

    /// Distinct speaker labels present in a meeting's segments — the mic mint
    /// numbers after these (speaker-row-per-mint). Labels only, no row bodies.
    func distinctSpeakerLabels(meetingId: String) async throws -> Set<String> {
        try await db.reader.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT DISTINCT speakerLabel FROM transcript_segments
                WHERE meetingId = ? AND speakerLabel IS NOT NULL
                """, arguments: [meetingId]))
        }
    }

    /// Label → speaker record already bound in this meeting (one record per
    /// label; MIN keeps it deterministic should a legacy meeting have two).
    func speakerLabelBindings(meetingId: String) async throws -> [String: String] {
        try await db.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT speakerLabel, MIN(speakerId) AS speakerId FROM transcript_segments
                WHERE meetingId = ? AND speakerLabel IS NOT NULL AND speakerId IS NOT NULL
                GROUP BY speakerLabel
                """, arguments: [meetingId])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["speakerLabel"] as String, $0["speakerId"] as String) })
        }
    }

    func segments(for meetingId: String) async throws -> [TranscriptSegment] {
        try await db.reader.read { db in
            try TranscriptSegment
                .filter(TranscriptSegment.Columns.meetingId == meetingId)
                .order(TranscriptSegment.Columns.startTime)
                .fetchAll(db)
        }
    }

    func saveSegments(_ segments: [TranscriptSegment]) async throws {
        try await db.writer.write { db in
            for var segment in segments {
                try segment.insert(db)
            }
        }
    }

    /// Brings a meeting's new transcript in and takes the previous one out —
    /// segments, speaker links, the anonymous speakers nobody else has — in
    /// one transaction. A reprocess used to delete first and transcribe after:
    /// any failure on the way left the meeting empty, text edits and speaker
    /// assignments gone. A first run has nothing to replace.
    func replaceSegments(for meetingId: String, with segments: [TranscriptSegment]) async throws {
        try await db.writer.write { db in
            try Self.deleteSegmentsAndSpeakers(db, meetingId: meetingId)
            for var segment in segments {
                try segment.insert(db)
            }
        }
    }

    func updateSegmentText(id: Int64, text: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE transcript_segments
                    SET text = ?,
                        originalText = CASE WHEN originalText IS NULL THEN text ELSE originalText END,
                        isEdited = 1
                    WHERE id = ?
                    """,
                arguments: [text, id]
            )
        }
    }

    func updateSegmentSpeaker(id: Int64, speakerId: String?, speakerLabel: String?) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE transcript_segments SET speakerId = ?, speakerLabel = ? WHERE id = ?",
                arguments: [speakerId, speakerLabel, id]
            )
            try Self.reconcileMeetingSpeakers(db, segmentId: id)
        }
    }

    /// Keeps `meeting_speakers` true to the segments after they change hands:
    /// a speaker with no segments left in the meeting is unlinked, one that
    /// just gained its first is linked. Every reassignment path ends here —
    /// before, links outlived their segments and the meeting kept listing
    /// people who no longer said anything in it (15 such links).
    private static func reconcileMeetingSpeakers(_ db: Database, meetingId: String) throws {
        try db.execute(sql: """
            DELETE FROM meeting_speakers
            WHERE meetingId = ?1 AND speakerId NOT IN (
                SELECT speakerId FROM transcript_segments
                WHERE meetingId = ?1 AND speakerId IS NOT NULL
            )
            """, arguments: [meetingId])
        try db.execute(sql: """
            INSERT OR IGNORE INTO meeting_speakers (meetingId, speakerId, diarizationLabel)
            SELECT DISTINCT meetingId, speakerId, speakerLabel FROM transcript_segments
            WHERE meetingId = ?1 AND speakerId IS NOT NULL
            """, arguments: [meetingId])
    }

    private static func reconcileMeetingSpeakers(_ db: Database, segmentId: Int64) throws {
        guard let meetingId = try String.fetchOne(
            db, sql: "SELECT meetingId FROM transcript_segments WHERE id = ?", arguments: [segmentId]
        ) else { return }
        try reconcileMeetingSpeakers(db, meetingId: meetingId)
    }

    func updateSegmentsSpeaker(ids: [Int64], meetingId: String, speakerId: String, speakerLabel: String) async throws {
        guard !ids.isEmpty else { return }
        try await db.writer.write { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            var arguments: [any DatabaseValueConvertible] = [speakerId, speakerLabel]
            arguments.append(contentsOf: ids)
            arguments.append(meetingId)
            try db.execute(
                sql: """
                    UPDATE transcript_segments
                    SET speakerId = ?, speakerLabel = ?
                    WHERE id IN (\(placeholders)) AND meetingId = ?
                    """,
                arguments: StatementArguments(arguments)
            )
            try Self.reconcileMeetingSpeakers(db, meetingId: meetingId)
        }
    }

    /// `fromSpeakerId` narrows the move to one record's lines: after a merge two
    /// records of a meeting can share a label.
    func renameSpeakerInMeeting(
        meetingId: String,
        oldLabel: String,
        newLabel: String,
        speakerId: String,
        fromSpeakerId: String? = nil
    ) async throws {
        try await db.writer.write { db in
            try Self.renameSpeakerInMeeting(
                db, meetingId: meetingId, oldLabel: oldLabel, newLabel: newLabel,
                speakerId: speakerId, fromSpeakerId: fromSpeakerId
            )
        }
    }

    /// Inside a caller's transaction (`SpeakerRepository.nameSpeakerInMeeting`).
    static func renameSpeakerInMeeting(
        _ db: Database, meetingId: String, oldLabel: String, newLabel: String, speakerId: String, fromSpeakerId: String?
    ) throws {
        try db.execute(
            sql: """
                UPDATE transcript_segments
                SET speakerLabel = ?, speakerId = ?
                WHERE meetingId = ? AND speakerLabel = ? AND (? IS NULL OR speakerId = ?)
                """,
            arguments: [newLabel, speakerId, meetingId, oldLabel, fromSpeakerId, fromSpeakerId]
        )
        try reconcileMeetingSpeakers(db, meetingId: meetingId)
    }

    /// Link all mic segments with speakerLabel "me" to a specific speaker.
    /// Only legitimate when diarization told exactly one voice apart on the
    /// track (`foreign-voices-on-mic`, решение 3).
    func linkMicSegmentsToSpeaker(meetingId: String, speakerId: String, speakerLabel: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE transcript_segments
                    SET speakerId = ?, speakerLabel = ?
                    WHERE meetingId = ? AND speakerLabel = 'me'
                    """,
                arguments: [speakerId, speakerLabel, meetingId]
            )
            try Self.reconcileMeetingSpeakers(db, meetingId: meetingId)
        }
    }

    /// Get segments for a meeting filtered by source.
    func segmentsWithSource(meetingId: String, source: SegmentSource) async throws -> [TranscriptSegment] {
        try await db.reader.read { db in
            try TranscriptSegment
                .filter(TranscriptSegment.Columns.meetingId == meetingId)
                .filter(TranscriptSegment.Columns.source == source)
                .order(TranscriptSegment.Columns.startTime)
                .fetchAll(db)
        }
    }

    /// Get segments for a meeting filtered by speaker label.
    func segmentsWithLabel(meetingId: String, speakerLabel: String) async throws -> [TranscriptSegment] {
        try await db.reader.read { db in
            try TranscriptSegment
                .filter(TranscriptSegment.Columns.meetingId == meetingId)
                .filter(TranscriptSegment.Columns.speakerLabel == speakerLabel)
                .order(TranscriptSegment.Columns.startTime)
                .fetchAll(db)
        }
    }

    /// Update speaker info on a single segment by its row ID.
    /// `speakerId: nil` clears the link (honest UNKNOWN — no persona).
    func updateSegmentSpeaker(
        segmentId: Int64,
        speakerId: String?,
        speakerLabel: String,
        embedding: Data?
    ) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE transcript_segments
                    SET speakerId = ?, speakerLabel = ?, embedding = ?
                    WHERE id = ?
                    """,
                arguments: [speakerId, speakerLabel, embedding, segmentId]
            )
            try Self.reconcileMeetingSpeakers(db, segmentId: segmentId)
        }
    }

    // MARK: - Full-Text Search

    /// Meetings in which every word of `query` occurs somewhere — in any line,
    /// in the title or in the description; the words may sit in different
    /// lines. No cap on lines, so a common word does not crowd meetings out.
    func meetingIds(matching query: String) async throws -> Set<String> {
        let words = query.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return [] }
        return try await db.reader.read { db in
            let meetings = try Row.fetchAll(db, sql: "SELECT id, title, description FROM meetings")
            var found: Set<String>?
            for word in words {
                var ids = Set<String>()
                if let pattern = FTS5Pattern(matchingAllPrefixesIn: word) {
                    // FTS indexes ALL segments, so the exclusion predicate lives on
                    // the join (design D4): excluded speech must not surface in ⌘F.
                    ids = try Set(String.fetchAll(db, sql: """
                        SELECT DISTINCT transcript_segments.meetingId
                        FROM transcript_segments
                        JOIN transcript_fts ON transcript_fts.rowid = transcript_segments.id
                        WHERE transcript_fts MATCH ? AND transcript_segments.isExcluded = 0
                        """, arguments: [pattern]))
                }
                for row in meetings {
                    let title: String = row["title"]
                    let description: String? = row["description"]
                    if title.localizedStandardContains(word) || description?.localizedStandardContains(word) == true {
                        ids.insert(row["id"])
                    }
                }
                found = found?.intersection(ids) ?? ids
                if found?.isEmpty == true { break }
            }
            return found ?? []
        }
    }

    // MARK: - Series & Rename

    func updateDescription(_ id: String, description: String?) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE meetings SET description = ? WHERE id = ?",
                arguments: [description, id]
            )
        }
    }

    func updateTitle(_ id: String, title: String) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE meetings SET title = ? WHERE id = ?",
                arguments: [title, id]
            )
        }
        // Series auto-rules match on real titles, which appear at rename time
        // (enrichment or manual) — apply here; no-op if already in a series.
        try? await SeriesRepository(db: db).applyAutoRule(meetingId: id, title: title)
    }

    func updateStartTime(_ meetingId: String, startTime: Date) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE meetings SET startTime = ? WHERE id = ?",
                arguments: [startTime, meetingId]
            )
        }
    }

    func updateSeriesId(_ id: String, seriesId: String?) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE meetings SET seriesId = ? WHERE id = ?",
                arguments: [seriesId, id]
            )
        }
    }

    func assignSeriesToBatch(_ ids: Set<String>, seriesId: String) async throws {
        let idArray = Array(ids)
        try await db.writer.write { db in
            for id in idArray {
                try db.execute(
                    sql: "UPDATE meetings SET seriesId = ? WHERE id = ?",
                    arguments: [seriesId, id]
                )
            }
        }
    }

    func updateCalendarInfo(_ id: String, calendarEventId: String?, seriesId: String?) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE meetings SET calendarEventId = ?, seriesId = ? WHERE id = ?",
                arguments: [calendarEventId, seriesId, id]
            )
        }
    }

    // MARK: - Split

    /// Split a meeting at a given time. Returns (meeting1, meeting2).
    /// Audio files are trimmed; originals saved as `*_presplit.m4a`.
    func splitMeeting(_ meetingId: String, atTime: Double, audioRoot: URL? = nil) async throws -> (Meeting, Meeting) {
        guard var meeting1 = try await find(meetingId) else {
            throw SplitError.meetingNotFound
        }
        let allSegments = try await segments(for: meetingId)
        let duration = meeting1.durationSeconds ?? allSegments.last?.endTime ?? atTime
        // For the undo: the end of the last line is not the length of the meeting.
        let (originalDuration, originalEnd) = (meeting1.durationSeconds, meeting1.endTime)

        let meeting2Id = UUID().uuidString
        let audioDir1 = try DatabaseManager.audioDirectory(for: meetingId, root: audioRoot)
        // Before meeting2's directory exists: a refusal must not leave it behind empty.
        try Self.refuseWhileMergePending(audioDir1)
        let audioDir2 = try DatabaseManager.audioDirectory(for: meeting2Id, root: audioRoot)
        Self.dropMergeUndo(in: audioDir1)

        // Cut every track first, next to the originals: the first halves as
        // .tmp, the second in meeting2's new directory. Nothing of meeting1 is
        // replaced until all cuts and the database write have succeeded — the
        // current track used to be deleted before its replacement was written.
        let fm = FileManager.default
        var cuts: [(name: String, source: URL, firstHalf: URL, secondHalf: URL)] = []
        func discardCuts() {
            for name in Self.trackNames {
                try? fm.removeItem(at: audioDir1.appendingPathComponent("\(name).m4a.tmp"))
            }
            try? fm.removeItem(at: audioDir2)
        }
        do {
            for (name, path) in [
                ("mic", meeting1.micAudioPath), ("system", meeting1.systemAudioPath),
                ("mic_suppressed", Self.suppressedMicPath(in: audioDir1)),
            ] {
                guard let path, fm.fileExists(atPath: path) else { continue }
                let source = URL(fileURLWithPath: path)
                let firstHalf = audioDir1.appendingPathComponent("\(name).m4a.tmp")
                let secondHalf = audioDir2.appendingPathComponent("\(name).m4a")
                try await AudioConverter.trimAudio(input: source, output: firstHalf, from: 0, to: atTime)
                try await AudioConverter.trimAudio(input: source, output: secondHalf, from: atTime, to: duration)
                cuts.append((name, source, firstHalf, secondHalf))
            }
        } catch {
            discardCuts()
            throw error
        }
        let micPath2 = cuts.first { $0.name == "mic" }?.secondHalf.path
        let sysPath2 = cuts.first { $0.name == "system" }?.secondHalf.path

        // Distribute segments
        let seg2 = allSegments.filter { $0.startTime >= atTime }.map { seg in
            var s = seg
            s.id = nil
            s.meetingId = meeting2Id
            s.startTime -= atTime
            s.endTime -= atTime
            return s
        }

        // Create meeting2
        let meeting2 = Meeting(
            id: meeting2Id,
            title: "\(meeting1.title) (2)",
            startTime: meeting1.startTime.addingTimeInterval(atTime),
            endTime: meeting1.endTime,
            durationSeconds: duration - atTime,
            language: meeting1.language,
            seriesId: meeting1.seriesId,
            source: meeting1.source,
            micAudioPath: micPath2,
            systemAudioPath: sysPath2,
            status: .done,
            diarizer: meeting1.diarizer,
            foreignVoiceDecision: meeting1.foreignVoiceDecision
        )

        // Update meeting1
        meeting1.endTime = meeting1.startTime.addingTimeInterval(atTime)
        meeting1.durationSeconds = atTime
        meeting1.micAudioPath = meeting1.micAudioPath.map { _ in audioDir1.appendingPathComponent("mic.m4a").path }
        meeting1.systemAudioPath = meeting1.systemAudioPath.map { _ in audioDir1.appendingPathComponent("system.m4a").path }

        // DB writes — one transaction: with the three it used to be, a failure
        // in between left meeting2 created without its segments.
        let m1 = meeting1
        do {
            try await db.writer.write { db in
                try m1.update(db)
                try meeting2.insert(db)

                // Remove segments that belong to meeting2 from meeting1
                for seg in allSegments where seg.startTime >= atTime {
                    if let id = seg.id {
                        try db.execute(sql: "DELETE FROM transcript_segments WHERE id = ?", arguments: [id])
                    }
                }
                // Insert shifted segments for meeting2
                for var seg in seg2 {
                    try seg.insert(db)
                }

                // Exclusion marks follow the same cut: a mark spanning the split
                // point exists in both halves (clamped left, shifted right) so
                // coverage is preserved. NULL endTime = open interval → reaches
                // the split point by definition.
                try db.execute(
                    sql: """
                        INSERT INTO meeting_marks (meetingId, startTime, endTime, track, kind, source, createdAt, text, speakerId)
                        SELECT ?, MAX(startTime - ?, 0),
                               CASE WHEN endTime IS NULL THEN NULL ELSE endTime - ? END,
                               track, kind, source, createdAt, text, speakerId
                        FROM meeting_marks
                        WHERE meetingId = ? AND COALESCE(endTime, 1e15) > ?
                        """,
                    arguments: [meeting2Id, atTime, atTime, meetingId, atTime]
                )
                try db.execute(
                    sql: "DELETE FROM meeting_marks WHERE meetingId = ? AND startTime >= ?",
                    arguments: [meetingId, atTime]
                )
                try db.execute(
                    sql: """
                        UPDATE meeting_marks SET endTime = ?
                        WHERE meetingId = ? AND (endTime IS NULL OR endTime > ?)
                        """,
                    arguments: [atTime, meetingId, atTime]
                )

                // Both halves list exactly the speakers of their segments: the first
                // half used to keep everyone, phantoms included.
                try Self.reconcileMeetingSpeakers(db, meetingId: meetingId)
                try Self.reconcileMeetingSpeakers(db, meetingId: meeting2Id)
            }
        } catch {
            discardCuts()
            throw error
        }

        // Only now the full tracks give way to their first halves and become
        // the undo copies (replacing those of an earlier split).
        for cut in cuts {
            let backup = audioDir1.appendingPathComponent("\(cut.name)_presplit.m4a")
            let current = audioDir1.appendingPathComponent("\(cut.name).m4a")
            try? fm.removeItem(at: backup)
            try fm.moveItem(at: cut.source, to: backup)
            try? fm.removeItem(at: current)
            try fm.moveItem(at: cut.firstHalf, to: current)
        }
        // Undo Trim would put the whole pre-trim audio back into part 1, the
        // stretch that is now part 2 included (cli-meeting-edit, finding 1) —
        // as a trim drops the split undo, a split drops the trim undo.
        Self.dropTrimUndo(in: audioDir1)

        // Save split_info.json for undo
        var splitInfo: [String: Any] = [
            "siblingId": meeting2Id,
            "splitTime": atTime,
        ]
        if let originalDuration { splitInfo["meeting1Duration"] = originalDuration }
        if let originalEnd { splitInfo["meeting1EndTime"] = originalEnd.timeIntervalSince1970 }
        let infoURL = audioDir1.appendingPathComponent("split_info.json")
        let jsonData = try JSONSerialization.data(withJSONObject: splitInfo, options: .prettyPrinted)
        try jsonData.write(to: infoURL)

        Log.info("Split \(meetingId) at \(String(format: "%.1f", atTime))s → \(meeting2Id)")
        return (meeting1, meeting2)
    }

    /// Undo a previous split. Merges sibling back into the original meeting.
    func undoSplit(_ meetingId: String, audioRoot: URL? = nil) async throws {
        let audioDir = try DatabaseManager.audioDirectory(for: meetingId, root: audioRoot)
        let infoURL = audioDir.appendingPathComponent("split_info.json")

        guard FileManager.default.fileExists(atPath: infoURL.path), !Self.isMerged(audioDir) else {
            throw SplitError.noSplitInfo
        }

        let data = try Data(contentsOf: infoURL)
        guard let info = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblingId = info["siblingId"] as? String,
              let splitTime = info["splitTime"] as? Double
        else {
            throw SplitError.noSplitInfo
        }

        guard try await find(siblingId) != nil else {
            throw SplitError.siblingNotFound
        }

        // Its lines and audio go back over the pre-split copy, which knows
        // nothing of what was done to the second part since: a trim shifted
        // its lines, a merge put another meeting's audio in it, a split moved
        // a part away. Undoing over that lost the merged meeting's only audio
        // (cli-meeting-edit, review 1).
        let siblingDir = DatabaseManager.audioDirectoryURL(for: siblingId, root: audioRoot)
        let edited = ["merge_info.json", "mic_pretrim.m4a", "split_info.json", Self.mergePendingFile]
        if edited.contains(where: { FileManager.default.fileExists(atPath: siblingDir.appendingPathComponent($0).path) }) {
            throw SplitError.partEditedSince
        }
        try Self.refuseWhileMergePending(audioDir)

        // Move sibling segments back (shift times by +splitTime)
        let siblingSegments = try await segments(for: siblingId)
        try await db.writer.write { db in
            for seg in siblingSegments {
                if let id = seg.id {
                    try db.execute(
                        sql: "UPDATE transcript_segments SET meetingId = ?, startTime = ?, endTime = ? WHERE id = ?",
                        arguments: [meetingId, seg.startTime + splitTime, seg.endTime + splitTime, id]
                    )
                }
            }
            // Exclusion marks travel back too — before deleteBatch(sibling)
            // would cascade them away. NULL + shift stays NULL (open interval).
            try db.execute(
                sql: """
                    UPDATE meeting_marks SET meetingId = ?, startTime = startTime + ?, endTime = endTime + ?
                    WHERE meetingId = ?
                    """,
                arguments: [meetingId, splitTime, splitTime, siblingId]
            )
            // The split dropped the sibling's speakers from this half; they come back with their segments.
            try Self.reconcileMeetingSpeakers(db, meetingId: meetingId)
        }

        // Restore presplit audio
        let fm = FileManager.default
        for name in Self.trackNames {
            let presplit = audioDir.appendingPathComponent("\(name)_presplit.m4a")
            let current = audioDir.appendingPathComponent("\(name).m4a")
            if fm.fileExists(atPath: presplit.path) {
                try? fm.removeItem(at: current)
                try fm.moveItem(at: presplit, to: current)
            }
        }

        // Update meeting1: restore duration, audio paths. The length used to
        // be the end of the last line, seconds short of the recording
        // (217.34 s came back as 214.72, live check 2026-11-19). A split
        // recorded before the length was kept takes it from the restored track.
        guard var meeting = try await find(meetingId) else { return }
        if let kept = info["meeting1Duration"] as? Double {
            meeting.durationSeconds = kept
            meeting.endTime = (info["meeting1EndTime"] as? Double).map(Date.init(timeIntervalSince1970:))
                ?? meeting.startTime.addingTimeInterval(kept)
        } else {
            let track = await Self.audioSeconds(audioDir.appendingPathComponent("mic.m4a"))
            let lastLineEnd = try await segments(for: meetingId).map(\.endTime).max()
            let length = track ?? lastLineEnd ?? (meeting.durationSeconds ?? 0)
            meeting.durationSeconds = length
            meeting.endTime = meeting.startTime.addingTimeInterval(length)
        }
        meeting.micAudioPath = audioDir.appendingPathComponent("mic.m4a").path
        if fm.fileExists(atPath: audioDir.appendingPathComponent("system.m4a").path) {
            meeting.systemAudioPath = audioDir.appendingPathComponent("system.m4a").path
        }
        try await save(meeting)

        // Delete sibling meeting and its audio directory
        try await deleteBatch([siblingId])
        try? fm.removeItem(at: siblingDir)

        // Remove split_info.json
        try? fm.removeItem(at: infoURL)

        Log.info("Undo split: merged \(siblingId) back into \(meetingId)")
    }

    // MARK: - Trim

    /// Trim a meeting to keep only [keepFrom, keepTo]. Originals saved as `*_pretrim.m4a`.
    func trimMeeting(_ meetingId: String, keepFrom: Double, keepTo: Double, audioRoot: URL? = nil) async throws {
        guard var meeting = try await find(meetingId) else {
            throw SplitError.meetingNotFound
        }

        let audioDir = try DatabaseManager.audioDirectory(for: meetingId, root: audioRoot)
        try Self.refuseWhileMergePending(audioDir)
        let fm = FileManager.default

        // Cut the CURRENT audio (not pretrim) so keepFrom/keepTo stay in the
        // visible timeline the user selected in the UI. Every track is cut
        // first, as .tmp next to the original; nothing is replaced until all
        // cuts and the database write have succeeded. The tracks used to be
        // replaced one by one, and the rows after: a failure on the second
        // track left the first one cut under a transcript that was not.
        var cuts: [(name: String, source: URL, tmp: URL)] = []
        func discardCuts() {
            for cut in cuts { try? fm.removeItem(at: cut.tmp) }
        }
        do {
            for (name, pathOpt) in [
                ("mic", meeting.micAudioPath), ("system", meeting.systemAudioPath),
                ("mic_suppressed", Self.suppressedMicPath(in: audioDir)),
            ] {
                guard let path = pathOpt, fm.fileExists(atPath: path) else { continue }
                let tmp = audioDir.appendingPathComponent("\(name).m4a.tmp")
                try? fm.removeItem(at: tmp) // left by a run that was killed
                cuts.append((name, URL(fileURLWithPath: path), tmp))
                try await AudioConverter.trimAudio(input: cuts[cuts.count - 1].source, output: tmp, from: keepFrom, to: keepTo)
            }
        } catch {
            discardCuts()
            throw error
        }

        let untrimmed = TrimInfo(startTime: meeting.startTime, endTime: meeting.endTime, durationSeconds: meeting.durationSeconds)
        meeting.startTime = meeting.startTime.addingTimeInterval(keepFrom)
        meeting.durationSeconds = keepTo - keepFrom
        meeting.endTime = meeting.startTime.addingTimeInterval(keepTo - keepFrom)
        meeting.micAudioPath = audioDir.appendingPathComponent("mic.m4a").path
        if meeting.systemAudioPath != nil {
            meeting.systemAudioPath = audioDir.appendingPathComponent("system.m4a").path
        }
        let updated = meeting

        // Segments, exclusion marks and the meeting row in ONE transaction — a
        // mark that drifts against its audio would silently hide the wrong
        // speech (transcript-exclusion-marks, group 2), and segments shifted
        // under an unchanged duration are no better.
        do {
            try await db.writer.write { db in
                try db.execute(
                    sql: "DELETE FROM transcript_segments WHERE meetingId = ? AND (endTime <= ? OR startTime >= ?)",
                    arguments: [meetingId, keepFrom, keepTo]
                )
                // As split does: a speaker whose lines were all cut off leaves the meeting.
                try Self.reconcileMeetingSpeakers(db, meetingId: meetingId)
                // Clamped like the marks below: a segment across a cut used to
                // keep its length — a negative start, an end past the meeting's.
                try db.execute(
                    sql: """
                        UPDATE transcript_segments SET
                            startTime = MAX(startTime, ?) - ?,
                            endTime = MIN(endTime, ?) - ?
                        WHERE meetingId = ?
                        """,
                    arguments: [keepFrom, keepFrom, keepTo, keepFrom, meetingId]
                )
                // NULL endTime = still-open interval, which reaches keepTo by definition.
                try db.execute(
                    sql: "DELETE FROM meeting_marks WHERE meetingId = ? AND (COALESCE(endTime, 1e15) <= ? OR startTime >= ?)",
                    arguments: [meetingId, keepFrom, keepTo]
                )
                try db.execute(
                    sql: """
                        UPDATE meeting_marks SET
                            startTime = MAX(startTime, ?) - ?,
                            endTime = CASE WHEN endTime IS NULL THEN NULL ELSE MIN(endTime, ?) - ? END
                        WHERE meetingId = ?
                        """,
                    arguments: [keepFrom, keepFrom, keepTo, keepFrom, meetingId]
                )
                try updated.update(db)
            }
        } catch {
            discardCuts()
            throw error
        }

        // Only now the tracks give way to their cuts. pretrim stays the
        // full-length original of the FIRST trim: undo restores to before any
        // trim, however many were made — and so does trim_info.json.
        if !fm.fileExists(atPath: audioDir.appendingPathComponent("mic_pretrim.m4a").path) {
            try JSONEncoder().encode(untrimmed).write(to: audioDir.appendingPathComponent(Self.trimInfoFile))
        }
        for cut in cuts {
            let backup = audioDir.appendingPathComponent("\(cut.name)_pretrim.m4a")
            let trimmed = audioDir.appendingPathComponent("\(cut.name).m4a")
            if fm.fileExists(atPath: backup.path) {
                try fm.removeItem(at: cut.source)
            } else {
                try fm.moveItem(at: cut.source, to: backup)
            }
            try fm.moveItem(at: cut.tmp, to: trimmed)
        }

        // The audio changed: undo copies of a split or a merge no longer fit it.
        let splitInfoURL = audioDir.appendingPathComponent("split_info.json")
        if fm.fileExists(atPath: splitInfoURL.path) {
            try? fm.removeItem(at: splitInfoURL)
            for name in Self.trackNames {
                try? fm.removeItem(at: audioDir.appendingPathComponent("\(name)_presplit.m4a"))
            }
        }
        Self.dropMergeUndo(in: audioDir)

        Log.info("Trimmed \(meetingId): keep [\(String(format: "%.1f", keepFrom))–\(String(format: "%.1f", keepTo))]s")
    }

    /// Undo trim: the pre-trim tracks come back, and the start and length of
    /// the meeting with them. The caller reprocesses: the trimmed
    /// transcript is off against the restored audio by the trimmed start.
    func undoTrim(_ meetingId: String, audioRoot: URL? = nil) async throws {
        guard var meeting = try await find(meetingId) else { throw SplitError.meetingNotFound }
        let audioDir = try DatabaseManager.audioDirectory(for: meetingId, root: audioRoot)
        try Self.refuseWhileMergePending(audioDir)
        let fm = FileManager.default
        for name in Self.trackNames {
            let pretrim = audioDir.appendingPathComponent("\(name)_pretrim.m4a")
            let current = audioDir.appendingPathComponent("\(name).m4a")
            guard fm.fileExists(atPath: pretrim.path) else { continue }
            try? fm.removeItem(at: current)
            try fm.moveItem(at: pretrim, to: current)
        }

        let infoURL = audioDir.appendingPathComponent(Self.trimInfoFile)
        if let data = try? Data(contentsOf: infoURL), let info = try? JSONDecoder().decode(TrimInfo.self, from: data) {
            meeting.startTime = info.startTime
            meeting.endTime = info.endTime
            meeting.durationSeconds = info.durationSeconds
        } else if let seconds = await Self.audioSeconds(audioDir.appendingPathComponent("mic.m4a")) {
            // A trim of a build that kept no record: the start is lost, the length is in the track.
            meeting.durationSeconds = seconds
            meeting.endTime = meeting.startTime.addingTimeInterval(seconds)
        }
        try await save(meeting)
        try? fm.removeItem(at: infoURL)
        Log.info("Undo trim \(meetingId): duration \(String(format: "%.1f", meeting.durationSeconds ?? 0))s")
    }

    /// The meeting's times before its first trim, next to the pretrim copies.
    private struct TrimInfo: Codable {
        let startTime: Date
        let endTime: Date?
        let durationSeconds: Double?
    }

    static let trimInfoFile = "trim_info.json"

    /// Every track that lines up with the transcript: the two recorded and the
    /// echo-suppressed mic, which the player prefers over `mic.m4a`. Trim,
    /// split, merge and their undos cut or join all of them.
    static let trackNames = ["mic", "system", "mic_suppressed"]

    private static func suppressedMicPath(in audioDir: URL) -> String {
        audioDir.appendingPathComponent("mic_suppressed.m4a").path
    }

    /// Returns true if pretrim files existed.
    func canUndoTrim(_ meetingId: String, audioRoot: URL? = nil) -> Bool {
        let audioDir = DatabaseManager.audioDirectoryURL(for: meetingId, root: audioRoot)
        return FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("mic_pretrim.m4a").path)
            && !Self.isMerged(audioDir) && !Self.hasPendingMerge(audioDir)
    }

    /// The copies an undo restores were taken before the merge: put back over
    /// a merged track they would erase the second meeting (its own directory
    /// is gone). Undo Trim and Undo Split wait until the merge is undone; an
    /// edit that changes the merged audio drops the merge undo instead.
    private static func isMerged(_ audioDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("merge_info.json").path)
    }

    /// A merge that committed but did not finish its files (cli-meeting-edit,
    /// review 5): its directory is left alone until the next launch finishes it.
    private static func hasPendingMerge(_ audioDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: audioDir.appendingPathComponent(mergePendingFile).path)
    }

    private static func refuseWhileMergePending(_ dirs: URL...) throws {
        if dirs.contains(where: hasPendingMerge) { throw SplitError.mergeUnfinished }
    }

    private static func dropTrimUndo(in audioDir: URL) {
        for file in [trimInfoFile] + trackNames.map({ "\($0)_pretrim.m4a" }) {
            try? FileManager.default.removeItem(at: audioDir.appendingPathComponent(file))
        }
    }

    private static func dropMergeUndo(in audioDir: URL) {
        for file in ["merge_info.json"] + trackNames.map({ "\($0)_premerge.m4a" }) {
            try? FileManager.default.removeItem(at: audioDir.appendingPathComponent(file))
        }
    }

    func canUndoSplit(_ meetingId: String, audioRoot: URL? = nil) async -> Bool {
        let audioDir = DatabaseManager.audioDirectoryURL(for: meetingId, root: audioRoot)
        let infoURL = audioDir.appendingPathComponent("split_info.json")
        guard !Self.isMerged(audioDir), !Self.hasPendingMerge(audioDir),
              FileManager.default.fileExists(atPath: infoURL.path),
              let data = try? Data(contentsOf: infoURL),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblingId = info["siblingId"] as? String else { return false }
        let siblingDir = DatabaseManager.audioDirectoryURL(for: siblingId, root: audioRoot)
        let edited = ["merge_info.json", "mic_pretrim.m4a", "split_info.json", Self.mergePendingFile]
        guard !edited.contains(where: { FileManager.default.fileExists(atPath: siblingDir.appendingPathComponent($0).path) }) else {
            return false
        }
        return (try? await find(siblingId)) != nil
    }

    // MARK: - Merge

    /// Merge two meetings into one. meeting1 = earlier, meeting2 = later (by startTime).
    /// meeting2 segments are moved into meeting1 with time shift, meeting2 is deleted.
    func mergeMeetings(_ id1: String, _ id2: String, audioRoot: URL? = nil) async throws -> Meeting {
        guard var meeting1 = try await find(id1), let meeting2 = try await find(id2) else { throw SplitError.meetingNotFound }

        // Ensure chronological order
        let (early, late) = meeting1.startTime <= meeting2.startTime
            ? (meeting1, meeting2)
            : (meeting2, meeting1)
        let earlyId = early.id
        let lateId = late.id

        // ponytail: the merged meeting keeps the early half's diarizer; merging
        // an online meeting with an offline one would mix embedding spaces.
        // Online processing stopped 2026-06-10, so this only warns.
        if early.diarizer != late.diarizer {
            Log.error("Merge \(lateId) into \(earlyId): diarizer mismatch ('\(early.diarizer ?? "nil")' vs '\(late.diarizer ?? "nil")') — merged meeting keeps '\(early.diarizer ?? "nil")'")
        }

        // Re-fetch if swapped
        if earlyId != id1 {
            meeting1 = early
        }

        let dir1 = try DatabaseManager.audioDirectory(for: earlyId, root: audioRoot)
        let dir2 = try DatabaseManager.audioDirectory(for: lateId, root: audioRoot)
        try Self.refuseWhileMergePending(dir1, dir2)
        // The join puts the later audio right after the earlier track, so the
        // shift is that track's length, not the field: a meeting a quit left
        // without durationSeconds shifted by 0, over the earlier lines.
        let duration1 = await Self.audioSeconds(dir1.appendingPathComponent("mic.m4a")) ?? meeting1.durationSeconds ?? 0
        let duration2 = await Self.audioSeconds(dir2.appendingPathComponent("mic.m4a")) ?? late.durationSeconds ?? 0
        let fm = FileManager.default

        // The later meeting's rows and directory are deleted at the end, so
        // nothing may still be writing to it, and every track it has must make
        // it into the join — a track left out is gone for good. Merging right
        // after a recording stopped (tracks still WAV), or into a meeting
        // without the system track, used to lose that audio silently.
        guard !early.status.isInProgress, !late.status.isInProgress else {
            throw SplitError.meetingBusy
        }
        for (name, latePath) in [("mic", late.micAudioPath), ("system", late.systemAudioPath)] {
            let joinable = ["\(dir1.path)/\(name).m4a", "\(dir2.path)/\(name).m4a"].allSatisfy(fm.fileExists)
            let lateFiles = ["\(dir2.path)/\(name).m4a", "\(dir2.path)/\(name).wav", latePath].compactMap { $0 }
            if !joinable, lateFiles.contains(where: fm.fileExists) {
                throw SplitError.trackWouldBeLost(name)
            }
        }
        // An import that never finished processing still has the imported
        // file — with no track extracted from it, the only copy of its audio.
        if let original = late.sourceFilePath, fm.fileExists(atPath: original) {
            throw SplitError.originalWouldBeLost
        }

        // Merge audio files: every track is joined and verified before any is replaced,
        // so a failed join leaves both meetings as they were.
        var joined: [(name: String, tmp: URL)] = []
        do {
            for name in Self.trackNames {
                let file1 = dir1.appendingPathComponent("\(name).m4a")
                let file2 = dir2.appendingPathComponent("\(name).m4a")
                guard fm.fileExists(atPath: file1.path), fm.fileExists(atPath: file2.path) else { continue }
                let tmp = dir1.appendingPathComponent("\(name)_merged.m4a")
                joined.append((name, tmp))
                try await AudioConverter.mergeAudio(file1: file1, file2: file2, output: tmp)
            }
        } catch {
            for (_, tmp) in joined { try? fm.removeItem(at: tmp) }
            throw error
        }
        // Crash-safe from here (cli-meeting-edit, finding 3): the journal names
        // the joined tracks, the database changes in one transaction — the
        // commit point — and only then the files are swapped. Whatever stops
        // the merge midway, the next launch reads the journal
        // (`recoverInterruptedMerges`): no commit, the joins are dropped and
        // both meetings are as they were; a commit, the swap is finished and
        // Undo Merge is there.
        let seg2 = try await segments(for: lateId)
        let (lateTagIds, earlyTagIds) = try await db.reader.read { db in
            let sql = "SELECT tagId FROM meeting_tags WHERE meetingId = ?"
            return (try String.fetchAll(db, sql: sql, arguments: [lateId]), try String.fetchAll(db, sql: sql, arguments: [earlyId]))
        }
        let mergedDescription = [meeting1.description, late.description]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: "\n\n")
        let mergeInfo: [String: Any] = [
            "meeting1Description": meeting1.description as Any,
            "meeting2Description": late.description as Any,
            "mergedDescription": mergedDescription,
            "meeting2TagIds": lateTagIds,
            // Undo takes back only the tags the merge brought (finding 6).
            "meeting1TagIds": earlyTagIds,
            "mergedId": lateId,
            "splitTime": duration1,
            "meeting2Title": late.title,
            "meeting2StartTime": late.startTime.timeIntervalSince1970,
            "meeting2EndTime": (late.endTime ?? late.startTime).timeIntervalSince1970,
            "meeting2Duration": duration2,
            "meeting2SeriesId": late.seriesId as Any,
            "meeting2Language": late.language,
            "meeting2Source": late.source.rawValue,
            "meeting2ForeignVoiceDecision": late.foreignVoiceDecision.rawValue,
            Self.joinedTracksKey: joined.map(\.name),
        ]
        let pendingURL = dir1.appendingPathComponent(Self.mergePendingFile)
        do {
            try JSONSerialization.data(withJSONObject: mergeInfo, options: .prettyPrinted).write(to: pendingURL)
        } catch {
            for (_, tmp) in joined { try? fm.removeItem(at: tmp) }
            throw error
        }
        try Self.simulateCrash(at: .journalWritten)

        meeting1.durationSeconds = duration1 + duration2
        meeting1.endTime = late.endTime ?? meeting1.endTime
        meeting1.description = mergedDescription.isEmpty ? nil : mergedDescription
        meeting1.micAudioPath = dir1.appendingPathComponent("mic.m4a").path
        if meeting1.systemAudioPath != nil {
            meeting1.systemAudioPath = dir1.appendingPathComponent("system.m4a").path
        }
        let merged = meeting1
        do {
            try await db.writer.write { db in
                for var seg in seg2 {
                    let oldId = seg.id
                    seg.id = nil
                    seg.meetingId = earlyId
                    seg.startTime += duration1
                    seg.endTime += duration1
                    try seg.insert(db)
                    if let oid = oldId {
                        try db.execute(sql: "DELETE FROM transcript_segments WHERE id = ?", arguments: [oid])
                    }
                }
                // Exclusion marks of the later meeting shift with its segments —
                // before the meeting2 row deletion below would cascade them away.
                try db.execute(
                    sql: """
                        UPDATE meeting_marks SET meetingId = ?, startTime = startTime + ?, endTime = endTime + ?
                        WHERE meetingId = ?
                        """,
                    arguments: [earlyId, duration1, duration1, lateId]
                )
                for speakerId in Set(seg2.compactMap(\.speakerId)) {
                    try db.execute(sql: """
                        INSERT INTO meeting_speakers (meetingId, speakerId, diarizationLabel)
                        SELECT ?, speakerId, diarizationLabel FROM meeting_speakers
                        WHERE meetingId = ? AND speakerId = ?
                          AND NOT EXISTS (SELECT 1 FROM meeting_speakers WHERE meetingId = ? AND speakerId = ?)
                        """, arguments: [earlyId, lateId, speakerId, earlyId, speakerId])
                }
                try merged.save(db)
                try db.execute(sql: "DELETE FROM meeting_speakers WHERE meetingId = ?", arguments: [lateId])
                try db.execute(
                    sql: "INSERT OR IGNORE INTO meeting_tags (meetingId, tagId) SELECT ?, tagId FROM meeting_tags WHERE meetingId = ?",
                    arguments: [earlyId, lateId]
                )
                try db.execute(sql: "DELETE FROM meeting_tags WHERE meetingId = ?", arguments: [lateId])
                _ = try Meeting.deleteOne(db, key: lateId)
            }
        } catch {
            // Rolled back: nothing of the merge is visible yet.
            for (_, tmp) in joined { try? fm.removeItem(at: tmp) }
            try? fm.removeItem(at: pendingURL)
            throw error
        }
        try Self.simulateCrash(at: .committed)

        // Committed: a failure from here on is finished by the next launch.
        try Self.finishMerge(in: dir1, lateDir: dir2)

        Log.info("Merged \(lateId) into \(earlyId), splitTime=\(String(format: "%.1f", duration1))s")
        return merged
    }

    private static func restorePremerge(_ tracks: [String], in dir1: URL) throws {
        let fm = FileManager.default
        for name in tracks {
            let current = dir1.appendingPathComponent("\(name).m4a")
            let premerge = dir1.appendingPathComponent("\(name)_premerge.m4a")
            guard fm.fileExists(atPath: premerge.path) else { continue }
            if fm.fileExists(atPath: current.path) {
                _ = try fm.replaceItemAt(current, withItemAt: premerge)
            } else {
                try fm.moveItem(at: premerge, to: current)
            }
        }
    }

    static let mergePendingFile = "merge_pending.json"
    private static let joinedTracksKey = "joinedTracks"

    /// Points where a test stops a merge as a crash would (cli-meeting-edit).
    enum MergeStep { case journalWritten, committed, undoCommitted }
    struct SimulatedCrash: Error {}
    nonisolated(unsafe) static var crashAt: MergeStep?
    private static func simulateCrash(at step: MergeStep) throws {
        if crashAt == step { throw SimulatedCrash() }
    }

    /// The file half of a committed merge, safe to run again after a crash at
    /// any point of it: each joined track replaces the current one (kept as
    /// the undo copy), the journal becomes `merge_info.json`, the later
    /// meeting's directory goes.
    static func finishMerge(in dir1: URL, lateDir: URL) throws {
        let fm = FileManager.default
        let pendingURL = dir1.appendingPathComponent(mergePendingFile)
        guard let data = try? Data(contentsOf: pendingURL),
              let info = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SplitError.mergeJournalMissing
        }
        let joinedTracks = Set(info[joinedTracksKey] as? [String] ?? [])
        for name in joinedTracks {
            let tmp = dir1.appendingPathComponent("\(name)_merged.m4a")
            let file1 = dir1.appendingPathComponent("\(name).m4a")
            let backup = dir1.appendingPathComponent("\(name)_premerge.m4a")
            guard fm.fileExists(atPath: tmp.path) else { continue } // already swapped
            // A copy kept from an earlier merge would undo two merges back; a
            // missing current track means a crash after the copy was taken.
            if fm.fileExists(atPath: file1.path) {
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: file1, to: backup)
                try fm.removeItem(at: file1)
            }
            try fm.moveItem(at: tmp, to: file1)
        }
        // Only the earlier meeting was echo-suppressed: its suppressed mic covers
        // the first half alone, and the player would prefer it over the joined
        // mic. It waits for the undo; the merged meeting plays the plain mic.
        let lonelySuppressed = dir1.appendingPathComponent("mic_suppressed.m4a")
        if !joinedTracks.contains("mic_suppressed"), fm.fileExists(atPath: lonelySuppressed.path) {
            let backup = dir1.appendingPathComponent("mic_suppressed_premerge.m4a")
            try? fm.removeItem(at: backup)
            try fm.moveItem(at: lonelySuppressed, to: backup)
        }
        let infoURL = dir1.appendingPathComponent("merge_info.json")
        try? fm.removeItem(at: infoURL)
        try fm.moveItem(at: pendingURL, to: infoURL)
        if fm.fileExists(atPath: lateDir.path) {
            try? fm.removeItem(at: lateDir)
        }
    }

    /// Run at launch, before anything merges: a merge stopped midway is
    /// rolled back (its transaction never committed: the later meeting is
    /// still there) or finished (it did).
    func recoverInterruptedMerges(audioRoot: URL? = nil) async {
        let fm = FileManager.default
        let root = audioRoot ?? DataDirectory.audio
        for earlyId in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let dir1 = root.appendingPathComponent(earlyId, isDirectory: true)
            let pendingURL = dir1.appendingPathComponent(Self.mergePendingFile)
            guard let data = try? Data(contentsOf: pendingURL),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lateId = info["mergedId"] as? String else { continue }
            let lateDir = DatabaseManager.audioDirectoryURL(for: lateId, root: audioRoot)
            let lateRowLeft: Bool
            do {
                lateRowLeft = try await find(lateId) != nil
            } catch {
                // An unreadable database says nothing about the commit; next launch.
                Log.error("Merge of \(lateId) into \(earlyId) was interrupted; database unreadable, left for the next launch: \(error)")
                continue
            }
            if lateRowLeft {
                for name in info[Self.joinedTracksKey] as? [String] ?? [] {
                    try? fm.removeItem(at: dir1.appendingPathComponent("\(name)_merged.m4a"))
                }
                try? fm.removeItem(at: pendingURL)
                Log.info("Merge of \(lateId) into \(earlyId) was interrupted before it was saved: rolled back")
            } else {
                do {
                    try Self.finishMerge(in: dir1, lateDir: lateDir)
                    Log.info("Merge of \(lateId) into \(earlyId) was interrupted after it was saved: finished")
                } catch {
                    Log.error("Merge of \(lateId) into \(earlyId): could not finish after an interruption: \(error)")
                }
            }
        }
    }

    /// Undo merge: split back into two meetings at the original splitTime.
    func undoMerge(_ meetingId: String, audioRoot: URL? = nil) async throws {
        guard var meeting1 = try await find(meetingId) else { throw SplitError.meetingNotFound }
        let dir1 = try DatabaseManager.audioDirectory(for: meetingId, root: audioRoot)
        let fm = FileManager.default

        // Read merge_info.json
        let infoURL = dir1.appendingPathComponent("merge_info.json")
        guard fm.fileExists(atPath: infoURL.path),
              let data = try? Data(contentsOf: infoURL),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meeting2Id = info["mergedId"] as? String,
              let splitTime = info["splitTime"] as? Double else {
            throw SplitError.noSplitInfo
        }

        try Self.refuseWhileMergePending(dir1)
        let dir2 = try DatabaseManager.audioDirectory(for: meeting2Id, root: audioRoot)
        let tracks = Self.trackNames.filter {
            fm.fileExists(atPath: dir1.appendingPathComponent("\($0)_premerge.m4a").path)
        }

        // An earlier undo saved both meetings and stopped before meeting1's
        // audio came back: only that is left. Cutting again would overwrite
        // meeting2's audio, and the failed insert then deleted its directory
        // (cli-meeting-edit, review 7).
        if try await find(meeting2Id) != nil {
            try Self.restorePremerge(tracks, in: dir1)
            try? fm.removeItem(at: infoURL)
            Log.info("Undo merge \(meetingId): finished an undo stopped before its audio")
            return
        }

        // The second half is cut out first, into its own directory: nothing of
        // meeting1 changes until the database has both meetings again. The
        // audio used to be swapped first, and the database step then always
        // failed — a full transcript over half the audio, with no way back.
        let totalDuration = meeting1.durationSeconds ?? splitTime
        do {
            // A suppressed mic the merge set aside has no joined track to cut.
            for name in tracks where fm.fileExists(atPath: dir1.appendingPathComponent("\(name).m4a").path) {
                try await AudioConverter.trimAudio(
                    input: dir1.appendingPathComponent("\(name).m4a"),
                    output: dir2.appendingPathComponent("\(name).m4a"),
                    from: splitTime, to: totalDuration
                )
            }
        } catch {
            try? fm.removeItem(at: dir2)
            throw error
        }

        let allSegments = try await segments(for: meetingId)
        let seg2 = allSegments.filter { $0.startTime >= splitTime }

        // Recreate meeting2 from saved info
        let meeting2 = Meeting(
            id: meeting2Id,
            title: info["meeting2Title"] as? String ?? "\(meeting1.title) (2)",
            startTime: Date(timeIntervalSince1970: info["meeting2StartTime"] as? Double ?? 0),
            endTime: Date(timeIntervalSince1970: info["meeting2EndTime"] as? Double ?? 0),
            durationSeconds: info["meeting2Duration"] as? Double,
            language: info["meeting2Language"] as? String ?? meeting1.language,
            seriesId: info["meeting2SeriesId"] as? String,
            source: MeetingSource(rawValue: info["meeting2Source"] as? String ?? "recording") ?? .recording,
            micAudioPath: dir2.appendingPathComponent("mic.m4a").path,
            systemAudioPath: fm.fileExists(atPath: dir2.appendingPathComponent("system.m4a").path)
                ? dir2.appendingPathComponent("system.m4a").path : nil,
            status: .done,
            description: info["meeting2Description"] as? String,
            diarizer: meeting1.diarizer,
            foreignVoiceDecision: ForeignVoiceDecision(
                rawValue: info["meeting2ForeignVoiceDecision"] as? String ?? ""
            ) ?? meeting1.foreignVoiceDecision
        )
        // The first meeting's own description comes back unless it was edited
        // since the merge.
        if meeting1.description ?? "" == info["mergedDescription"] as? String {
            meeting1.description = info["meeting1Description"] as? String
        }
        let meeting2TagIds = info["meeting2TagIds"] as? [String] ?? []
        // Absent in merges made before it was recorded: their tags stay put.
        let broughtTagIds = (info["meeting1TagIds"] as? [String]).map { Set(meeting2TagIds).subtracting($0) } ?? []
        meeting1.durationSeconds = splitTime
        meeting1.endTime = meeting1.startTime.addingTimeInterval(splitTime)
        let updated1 = meeting1

        do {
            // One transaction, meeting2 first: its segments reference its row.
            try await db.writer.write { db in
                try meeting2.insert(db)
                for tagId in meeting2TagIds {
                    // A tag deleted since the merge is not brought back.
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO meeting_tags (meetingId, tagId) SELECT ?, id FROM tags WHERE id = ?",
                        arguments: [meeting2Id, tagId]
                    )
                }
                for tagId in broughtTagIds {
                    try db.execute(
                        sql: "DELETE FROM meeting_tags WHERE meetingId = ? AND tagId = ?", arguments: [meetingId, tagId]
                    )
                }

                for var seg in seg2 {
                    if let oldId = seg.id {
                        try db.execute(sql: "DELETE FROM transcript_segments WHERE id = ?", arguments: [oldId])
                    }
                    seg.id = nil
                    seg.meetingId = meeting2Id
                    seg.startTime -= splitTime
                    seg.endTime -= splitTime
                    try seg.insert(db)
                }

                // Copy speakers for meeting2
                let speakerIds = Set(seg2.compactMap(\.speakerId))
                for speakerId in speakerIds {
                    try? db.execute(sql: """
                        INSERT INTO meeting_speakers (meetingId, speakerId, diarizationLabel)
                        SELECT ?, speakerId, diarizationLabel FROM meeting_speakers
                        WHERE meetingId = ? AND speakerId = ? LIMIT 1
                        """, arguments: [meeting2Id, meetingId, speakerId])
                }
                // The restored first half drops the speakers that left with meeting2.
                try Self.reconcileMeetingSpeakers(db, meetingId: meetingId)
                try Self.reconcileMeetingSpeakers(db, meetingId: meeting2Id)
                // Exclusion marks of the restored second half move back with their
                // segments; what stays in meeting1 is clamped at the split point.
                try db.execute(
                    sql: """
                        UPDATE meeting_marks SET meetingId = ?, startTime = startTime - ?, endTime = endTime - ?
                        WHERE meetingId = ? AND startTime >= ?
                        """,
                    arguments: [meeting2Id, splitTime, splitTime, meetingId, splitTime]
                )
                try db.execute(
                    sql: """
                        UPDATE meeting_marks SET endTime = ?
                        WHERE meetingId = ? AND (endTime IS NULL OR endTime > ?)
                        """,
                    arguments: [splitTime, meetingId, splitTime]
                )

                try updated1.update(db)
            }
        } catch {
            try? fm.removeItem(at: dir2)
            throw error
        }

        try Self.simulateCrash(at: .undoCommitted)
        // Only now meeting1 gets its pre-merge audio back.
        try Self.restorePremerge(tracks, in: dir1)
        try? fm.removeItem(at: infoURL)

        Log.info("Undo merge \(meetingId): restored \(meeting2Id)")
    }

    /// Both parts of the last split, from the id of either (cli-meeting-edit):
    /// the undo record sits with part 1, the window opens part 2.
    func splitParts(of meetingId: String, audioRoot: URL? = nil) -> (first: String, second: String)? {
        func sibling(of id: String) -> String? {
            let url = DatabaseManager.audioDirectoryURL(for: id, root: audioRoot).appendingPathComponent("split_info.json")
            guard let data = try? Data(contentsOf: url),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return info["siblingId"] as? String
        }
        if let second = sibling(of: meetingId) { return (meetingId, second) }
        let root = audioRoot ?? DataDirectory.audio
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.first { sibling(of: $0) == meetingId }.map { ($0, meetingId) }
    }

    /// The meeting an Undo Merge of `meetingId` brings back, nil when there is no merge to undo.
    func mergedMeetingId(of meetingId: String, audioRoot: URL? = nil) -> String? {
        let url = DatabaseManager.audioDirectoryURL(for: meetingId, root: audioRoot).appendingPathComponent("merge_info.json")
        guard let data = try? Data(contentsOf: url),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return info["mergedId"] as? String
    }

    func canUndoMerge(_ meetingId: String, audioRoot: URL? = nil) -> Bool {
        let audioDir = DatabaseManager.audioDirectoryURL(for: meetingId, root: audioRoot)
        return FileManager.default.fileExists(
            atPath: audioDir.appendingPathComponent("merge_info.json").path
        ) && !Self.hasPendingMerge(audioDir)
    }

    enum SplitError: Error, LocalizedError {
        case meetingNotFound
        case noSplitInfo
        case siblingNotFound
        case meetingBusy
        case trackWouldBeLost(String)
        case originalWouldBeLost
        case partEditedSince
        case mergeUnfinished
        case mergeJournalMissing

        var errorDescription: String? {
            switch self {
            case .originalWouldBeLost:
                "Cannot merge: the later meeting still has its imported file, which was never fully processed — reprocess it first"
            case .meetingBusy: "A meeting is still being recorded or processed — try again when it is done"
            case .trackWouldBeLost(let track):
                "Cannot merge: the later meeting's \(track) track has no counterpart to join with in the earlier one (missing, or not compressed yet)"
            case .partEditedSince:
                "The second part was trimmed, split or merged since — undo that first, or merge the parts instead"
            case .mergeUnfinished:
                "An interrupted merge of this meeting is finished on the next launch of Vedivox — relaunch it first"
            case .mergeJournalMissing: "The merge journal is missing — the merge cannot be finished"
            case .meetingNotFound: "Meeting not found"
            case .noSplitInfo: "No split/merge info found — cannot undo"
            case .siblingNotFound: "Split sibling meeting was deleted — cannot undo"
            }
        }
    }
}
