import XCTest

/// Undo copies expire after `UndoCopyRetention.days`, and the undo goes with them
/// (compact-meeting-storage § 4).
final class UndoCopyRetentionTests: XCTestCase {
    private var meetings: MeetingRepository!
    private var root: URL!
    private let day: TimeInterval = 86400

    override func setUp() async throws {
        meetings = MeetingRepository(db: try makeTestDB())
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedivox-undo-retention-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testOldTrimCopyGoesAndTakesTheUndoWithIt() async throws {
        let id = UUID().uuidString
        try write(["mic.m4a", "system.m4a", "mic_pretrim.m4a", "system_pretrim.m4a"], in: id, age: 31)

        UndoCopyRetention.pruneExpired(audioRoot: root)

        XCTAssertFalse(meetings.canUndoTrim(id, audioRoot: root))
        XCTAssertEqual(files(in: id), ["mic.m4a", "system.m4a"])
    }

    /// The copy keeps the recording's mtime (moveItem); a fresh trim of an old
    /// recording must not look expired.
    func testRecentTrimOfAnOldRecordingKeepsItsUndo() async throws {
        let id = UUID().uuidString
        try write(["mic_pretrim.m4a"], in: id, age: 90)
        try write(["mic.m4a"], in: id, age: 1)

        UndoCopyRetention.pruneExpired(audioRoot: root)

        XCTAssertTrue(meetings.canUndoTrim(id, audioRoot: root))
    }

    func testRecentSplitKeepsItsCopiesAndUndo() async throws {
        let (id, sibling) = try await splitMeetings()
        try write(["mic_presplit.m4a", "system_presplit.m4a"], in: id, age: 200)
        try writeSplitInfo(in: id, sibling: sibling, age: 1)

        UndoCopyRetention.pruneExpired(audioRoot: root)

        let canUndo = await meetings.canUndoSplit(id, audioRoot: root)
        XCTAssertTrue(canUndo)
        XCTAssertTrue(files(in: id).isSuperset(of: ["mic_presplit.m4a", "system_presplit.m4a", "split_info.json"]))
    }

    /// A crash between the two deletions leaves audio without its info file: no
    /// undo is offered for it, and once old it is collected.
    func testSplitCopyWithoutInfoIsNotOfferedAndIsCollected() async throws {
        let (id, _) = try await splitMeetings()
        try write(["mic.m4a", "mic_presplit.m4a"], in: id, age: 31)

        let canUndo = await meetings.canUndoSplit(id, audioRoot: root)
        XCTAssertFalse(canUndo)

        UndoCopyRetention.pruneExpired(audioRoot: root)

        XCTAssertEqual(files(in: id), ["mic.m4a"])
    }

    func testOldMergeCopyGoesWithItsInfo() throws {
        let id = UUID().uuidString
        try write(["mic.m4a", "mic_premerge.m4a", "merge_info.json"], in: id, age: 45)

        UndoCopyRetention.pruneExpired(audioRoot: root)

        XCTAssertEqual(files(in: id), ["mic.m4a"])
    }

    // MARK: - Helpers

    private func splitMeetings() async throws -> (String, String) {
        let first = makeMeeting()
        let second = makeMeeting()
        try await meetings.save(first)
        try await meetings.save(second)
        return (first.id, second.id)
    }

    private func write(_ names: [String], in meetingId: String, age days: Double) throws {
        let dir = DatabaseManager.audioDirectoryURL(for: meetingId, root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            let url = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try setAge(url, days: days)
        }
    }

    private func writeSplitInfo(in meetingId: String, sibling: String, age days: Double) throws {
        let url = DatabaseManager.audioDirectoryURL(for: meetingId, root: root).appendingPathComponent("split_info.json")
        try JSONSerialization.data(withJSONObject: ["siblingId": sibling, "splitTime": 10.0]).write(to: url)
        try setAge(url, days: days)
    }

    private func setAge(_ url: URL, days: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-days * day)], ofItemAtPath: url.path
        )
    }

    private func files(in meetingId: String) -> Set<String> {
        let dir = DatabaseManager.audioDirectoryURL(for: meetingId, root: root)
        return Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }
}
