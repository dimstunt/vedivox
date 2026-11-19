import XCTest

/// Deleting a meeting must not destroy its audio.
///
/// A stray Cmd+⌫ once took out a 3-hour recording: the transcript survived only
/// because SQLite happened not to have checkpointed its WAL, and the audio —
/// deleted with `removeItem` — was gone for good. The Trash is what makes that
/// class of mistake recoverable, so the behaviour is pinned here.
final class AudioTrashTests: XCTestCase {

    private var audioRoot: URL!
    /// Items this test put in the real Trash, removed in tearDown.
    private var trashedItems: [URL] = []

    override func setUp() async throws {
        audioRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VedivoxAudioTrashTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for url in trashedItems {
            try? FileManager.default.removeItem(at: url)
        }
        trashedItems = []
        try? FileManager.default.removeItem(at: audioRoot)
    }

    func testTrashAudioDirectory_movesDirectoryToTrashInsteadOfDestroyingIt() throws {
        let meetingId = UUID().uuidString
        let audioDir = try DatabaseManager.audioDirectory(for: meetingId, root: audioRoot)
        let payload = audioDir.appendingPathComponent("mic.wav")
        try Data("not really audio".utf8).write(to: payload)

        let trashed = try DatabaseManager.trashAudioDirectory(for: meetingId, root: audioRoot)

        let trashedURL = try XCTUnwrap(trashed, "trashItem should report where the directory landed")
        trashedItems.append(trashedURL)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: audioDir.path),
            "audio directory must be gone from the audio root"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: trashedURL.appendingPathComponent("mic.wav").path),
            "the audio file must still be readable from the Trash — that is the whole point"
        )
    }

    /// Guards the trap that made the old code create-then-delete: resolving the
    /// path must have no side effects, or deleting a meeting with no audio would
    /// leave a fresh empty directory behind (and trash it).
    func testTrashAudioDirectory_withoutAudioReturnsNilAndCreatesNothing() throws {
        let meetingId = UUID().uuidString

        let trashed = try DatabaseManager.trashAudioDirectory(for: meetingId, root: audioRoot)

        XCTAssertNil(trashed, "nothing existed, so nothing should have been trashed")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: DatabaseManager.audioDirectoryURL(for: meetingId, root: audioRoot).path
            ),
            "resolving the audio path must not create the directory"
        )
    }
}
