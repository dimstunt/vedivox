import XCTest

/// What the app's old name left on disk and in people's notes stays readable.
final class LegacyNamesTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vox-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: DatabaseSafety.backupsDirectory(in: root), withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func backups(_ names: [String]) throws -> Set<String> {
        let directory = DatabaseSafety.backupsDirectory(in: root)
        for name in names {
            try Data("copy".utf8).write(to: directory.appendingPathComponent(name))
        }
        DatabaseSafety.pruneBackups(in: root)
        return Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    // MARK: - Backups

    func testBackupsMadeUnderTheOldNameAreStillRecognised() {
        XCTAssertTrue(DatabaseSafety.isAutomaticBackupName("Vox-20260101-000000.sqlite"))
        XCTAssertTrue(DatabaseSafety.isAutomaticBackupName("Vox-20260101-000000-before-v26-speaker-verdicts.sqlite"))
        XCTAssertTrue(DatabaseSafety.isAutomaticBackupName("Vedivox-20260101-000000.sqlite"))
        XCTAssertFalse(DatabaseSafety.isAutomaticBackupName("Vox-2026-10-02-before-merge.sqlite"), "a hand-made copy")
        XCTAssertFalse(DatabaseSafety.isAutomaticBackupName("Vox.sqlite.backup-20260507-014915"))
    }

    /// Without this the old copies would stay forever: three more of them in
    /// every library that came over.
    func testOldBackupsRotateOutAsNewOnesAreMade() throws {
        let remaining = try backups([
            "Vox-20260101-000000.sqlite",
            "Vox-20260102-000000-before-v26-speaker-verdicts.sqlite",
            "Vedivox-20260103-000000-before-v27-library-under-the-new-name.sqlite",
            "Vedivox-20260104-000000.sqlite",
            "Vedivox-20260105-000000.sqlite",
            "Vox-2026-10-02-before-merge.sqlite",
        ])

        XCTAssertEqual(remaining, [
            "Vedivox-20260103-000000-before-v27-library-under-the-new-name.sqlite",
            "Vedivox-20260104-000000.sqlite",
            "Vedivox-20260105-000000.sqlite",
            "Vox-2026-10-02-before-merge.sqlite",
        ])
    }

    /// The copies are ordered by the stamp, not by the name: by name every
    /// copy under the old prefix sorts as newer than any under the new one,
    /// and rotation would throw the fresh copies away to keep the stale ones.
    func testTheNewestCopiesStayWhateverTheirPrefix() throws {
        let remaining = try backups([
            "Vox-20260110-000000.sqlite",
            "Vox-20260101-000000.sqlite",
            "Vedivox-20260120-000000.sqlite",
            "Vedivox-20260121-000000.sqlite",
        ])

        XCTAssertEqual(remaining, [
            "Vox-20260110-000000.sqlite",
            "Vedivox-20260120-000000.sqlite",
            "Vedivox-20260121-000000.sqlite",
        ])
    }

    // MARK: - Links

    func testMeetingLinksAreReadUnderBothSchemes() throws {
        for scheme in ["vedivox", "vox"] {
            let plain = try XCTUnwrap(URL(string: "\(scheme)://meeting/AAAAAAAA-0000-0000-0000-000000000001"))
            XCTAssertEqual(
                VedivoxLinks.meetingLink(plain),
                VedivoxLinks.MeetingLink(meetingId: "AAAAAAAA-0000-0000-0000-000000000001", seekTime: nil),
                scheme
            )
            let moment = try XCTUnwrap(URL(string: "\(scheme)://meeting/AAAAAAAA-0000-0000-0000-000000000001?t=125.5"))
            XCTAssertEqual(VedivoxLinks.meetingLink(moment)?.seekTime, 125.5, scheme)
        }
    }

    func testOtherLinksAreNotMeetingLinks() throws {
        for text in ["https://meeting/M1", "vedivox://import?path=/tmp/a.wav", "vox://reprocess/M1", "vedivox://meeting/"] {
            XCTAssertNil(VedivoxLinks.meetingLink(try XCTUnwrap(URL(string: text))), text)
        }
    }

    func testNewLinksAreWrittenUnderTheNewScheme() {
        XCTAssertEqual(VedivoxLinks.scheme, "vedivox")
    }
}
