import Foundation
import XCTest

/// Dictation history against a real database and real files
///
/// `DictationRetentionTests` covers the policy in isolation; this covers the
/// part that touches the disk, where the interesting failure is a row and its
/// audio file going out of sync — a record pointing at a file that is no longer
/// there, or a file left behind after its record is gone.
final class DictationRepositoryTests: XCTestCase {

    private var db: DatabaseManager!
    private var audioRoot: URL!
    private var repo: DictationRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try makeTestDB()
        audioRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vox-dictation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        repo = DictationRepository(db: db, audioRoot: audioRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: audioRoot)
        repo = nil
        audioRoot = nil
        db = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makeClip(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).wav")
        try Data("fake audio".utf8).write(to: url)
        return url
    }

    @discardableResult
    private func store(_ id: String, text: String = "текст", daysAgo: Double = 0) async throws -> Dictation {
        let clip = try makeClip(id)
        let fileName = try repo.storeAudio(from: clip, id: id)
        let record = Dictation(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86400),
            text: text,
            durationSeconds: 4,
            targetApp: "Terminal",
            inserted: true,
            audioFileName: fileName
        )
        try await repo.save(record)
        return record
    }

    // MARK: - Tests

    func testSaveAndFetch() async throws {
        try await store("d1", text: "привет")

        let fetched = try await repo.find("d1")
        XCTAssertEqual(fetched?.text, "привет")
        XCTAssertEqual(fetched?.targetApp, "Terminal")
        XCTAssertTrue(fetched?.hasAudio == true)
        let total = try await repo.count()
        XCTAssertEqual(total, 1)
    }

    /// Storing must move the clip out of the temp directory, not copy it —
    /// otherwise every dictation leaves a second copy behind.
    func testStoringMovesTheClip() throws {
        let clip = try makeClip("move-me")
        let fileName = try repo.storeAudio(from: clip, id: "move-me")

        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: audioRoot.appendingPathComponent(fileName).path
            )
        )
    }

    func testRecentIsNewestFirst() async throws {
        try await store("old", daysAgo: 5)
        try await store("new", daysAgo: 0)
        try await store("middle", daysAgo: 2)

        let recent = try await repo.recent()
        XCTAssertEqual(recent.map(\.id), ["new", "middle", "old"])
    }

    /// The point of the whole feature: text survives, audio does not.
    func testRetentionDeletesAudioButKeepsText() async throws {
        for index in 0 ..< 4 {
            try await store("d\(index)", text: "фраза \(index)", daysAgo: Double(index))
        }

        let trimmed = try await repo.enforceRetention(limit: 2)
        XCTAssertEqual(trimmed, 2)

        let all = try await repo.recent()
        XCTAssertEqual(all.count, 4, "records must not be deleted, only their audio")

        let oldest = try XCTUnwrap(all.first { $0.id == "d3" })
        XCTAssertNil(oldest.audioFileName, "audio reference cleared")
        XCTAssertEqual(oldest.text, "фраза 3", "text kept")

        let newest = try XCTUnwrap(all.first { $0.id == "d0" })
        XCTAssertNotNil(newest.audioFileName)
    }

    /// A cleared reference must mean the file is gone too — a row pointing at
    /// nothing and a file nobody points at are both bugs.
    func testRetentionRemovesTheFilesThemselves() async throws {
        for index in 0 ..< 3 {
            try await store("f\(index)", daysAgo: Double(index))
        }
        try await repo.enforceRetention(limit: 1)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: audioRoot.path)
            .filter { $0.hasSuffix(".wav") }
        XCTAssertEqual(remaining, ["f0.wav"])
    }

    func testRetentionIsIdempotent() async throws {
        for index in 0 ..< 3 {
            try await store("i\(index)", daysAgo: Double(index))
        }

        let firstPass = try await repo.enforceRetention(limit: 1)
        XCTAssertEqual(firstPass, 2)
        let secondPass = try await repo.enforceRetention(limit: 1)
        XCTAssertEqual(secondPass, 0, "nothing left to trim")
    }

    func testDeleteRemovesRowAndAudio() async throws {
        let record = try await store("gone")
        let fileName = try XCTUnwrap(record.audioFileName)

        try await repo.delete("gone")

        let deleted = try await repo.find("gone")
        XCTAssertNil(deleted)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: audioRoot.appendingPathComponent(fileName).path)
        )
    }

    /// Re-transcription replaces the text of an existing record rather than
    /// adding a second one.
    func testUpdateTextReplacesInPlace() async throws {
        try await store("retry", text: "первый вариант")

        try await repo.updateText("retry", text: "второй вариант")

        let updated = try await repo.find("retry")
        XCTAssertEqual(updated?.text, "второй вариант")
        let total = try await repo.count()
        XCTAssertEqual(total, 1)
    }

    /// A dictation a quit saved stays owed until a recognition settles it,
    /// empty text included.
    func testRecognitionSettlesAnAwaitingDictation() async throws {
        var owed = try await store("owed", text: "", daysAgo: 1)
        owed.awaitingTranscription = true
        try await repo.save(owed)
        try await store("done", daysAgo: 0)

        var awaiting = try await repo.awaitingTranscription()
        XCTAssertEqual(awaiting.map(\.id), ["owed"])

        try await repo.updateText("owed", text: "")
        awaiting = try await repo.awaitingTranscription()
        XCTAssertTrue(awaiting.isEmpty)
    }

    /// What a killed run leaves in the temporary folder: its clips are found,
    /// its half-done conversions removed, anything else left alone.
    func testLeftoverClipsInTheTemporaryFolder() throws {
        let folder = audioRoot.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString
        for name in ["vox-dictation-\(id).wav", "vox-dictation-\(id).16k.wav", "vox-dictation-tests-x.wav", "other.wav"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }

        let clips = DictationController.leftoverClips(in: folder)

        XCTAssertEqual(clips.map(\.lastPathComponent), ["vox-dictation-\(id).wav"])
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(left, ["other.wav", "vox-dictation-\(id).wav", "vox-dictation-tests-x.wav"])
    }

    func testAudioURLIsNilOnceTrimmed() async throws {
        try await store("a0", daysAgo: 0)
        try await store("a1", daysAgo: 1)
        try await repo.enforceRetention(limit: 1)

        let fetched = try await repo.find("a1")
        let trimmed = try XCTUnwrap(fetched)
        XCTAssertNil(repo.audioURL(for: trimmed))
    }
}
