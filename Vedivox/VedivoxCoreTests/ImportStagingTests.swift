import XCTest

/// An import copies the file into a new meeting's directory and then creates
/// the meeting. What a failure in between leaves behind, and where a failed
/// import starts again.
final class ImportStagingTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedivox-import-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSource(_ name: String = "talk.mov") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("media".utf8).write(to: url)
        return url
    }

    private func directoryExists(_ meetingId: String) -> Bool {
        FileManager.default.fileExists(atPath: DatabaseManager.audioDirectoryURL(for: meetingId, root: root).path)
    }

    func testStagedFileIsCopiedIntoTheMeetingDirectory() async throws {
        let source = try makeSource()

        let staged = try await ImportRequest.stage(source, as: "original.mov", meetingId: "m1", audioRoot: root) { _ in }

        XCTAssertEqual(staged, DatabaseManager.audioDirectoryURL(for: "m1", root: root).appendingPathComponent("original.mov"))
        XCTAssertEqual(try Data(contentsOf: staged), Data("media".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the user's file is copied, not moved")
    }

    /// A directory no meeting row points at is disk space nobody can find —
    /// half a video, when it was the disk that filled up.
    func testAFailedCopyLeavesNoDirectoryBehind() async throws {
        let missing = root.appendingPathComponent("gone.mov")

        do {
            _ = try await ImportRequest.stage(missing, as: "original.mov", meetingId: "m2", audioRoot: root) { _ in }
            XCTFail("copying a file that is not there must fail")
        } catch {}

        XCTAssertFalse(directoryExists("m2"))
    }

    func testAMeetingThatCannotBeCreatedLeavesNoDirectoryBehind() async throws {
        let source = try makeSource()
        struct NoRow: Error {}

        do {
            _ = try await ImportRequest.stage(source, as: "original.mov", meetingId: "m3", audioRoot: root) { _ in
                throw NoRow()
            }
            XCTFail("the failure must reach the caller")
        } catch is NoRow {}

        XCTAssertFalse(directoryExists("m3"))
    }

    // MARK: Where a failed import starts again

    /// The mic.wav a failed extraction leaves is short. Reprocess used to
    /// take it for the meeting's audio, and on success deleted the full file.
    func testAnImportStartsAgainFromTheImportedFileWhileItExists() throws {
        let original = try makeSource("original.mov")
        var meeting = makeMeeting(status: .error)
        meeting.source = .import
        meeting.sourceFilePath = original.path
        XCTAssertEqual(meeting.importedOriginal, original)

        meeting.sourceFilePath = root.appendingPathComponent("deleted.mov").path
        XCTAssertNil(meeting.importedOriginal, "a file that is gone cannot be the source")

        meeting.sourceFilePath = original.path
        meeting.source = .recording
        XCTAssertNil(meeting.importedOriginal, "a recording has no imported file")
    }
}
