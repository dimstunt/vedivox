import XCTest

/// Pins the single-instance guarantee at the level the app depends on: one
/// claim per data directory, independent claims for independent directories,
/// and no cleanup needed after a crash.
///
/// `flock` conflicts across descriptors even within one process, so two claims
/// here behave exactly like two processes — which is what makes this testable
/// without launching a second app.
final class DataDirectoryLockTests: XCTestCase {

    private var directories: [URL] = []
    private var locks: [DataDirectoryLock] = []

    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vedivox-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private func acquire(
        _ directory: URL,
        holder: DataDirectoryHolder = .current(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> DataDirectoryLock {
        switch DataDirectoryLock.acquire(in: directory, holder: holder) {
        case .acquired(let lock):
            locks.append(lock)
            return lock
        case .busy(let existing):
            XCTFail("expected to acquire \(directory.path), busy with \(String(describing: existing))", file: file, line: line)
            throw XCTSkip("not acquired")
        case .unavailable(let reason):
            XCTFail("expected to acquire \(directory.path): \(reason)", file: file, line: line)
            throw XCTSkip("not acquired")
        }
    }

    override func tearDown() {
        for lock in locks { lock.release() }
        locks = []
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    // MARK: - One Claim Per Directory

    func testSecondClaimOnTheSameDirectoryIsRefused() throws {
        let directory = try makeDirectory()
        _ = try acquire(directory)

        switch DataDirectoryLock.acquire(in: directory) {
        case .acquired(let second):
            locks.append(second)
            XCTFail("a second instance claimed a directory that was already held")
        case .busy:
            break
        case .unavailable(let reason):
            XCTFail("a held directory is busy, not unusable: \(reason)")
        }
    }

    /// A directory that cannot be locked at all — not writable, on a full disk
    /// at first launch — was reported as "another instance holds it", and the
    /// app exits quietly for that: the icon bounced and nothing else happened.
    func testADirectoryThatCannotBeLockedIsUnavailableNotBusy() throws {
        let directory = try makeDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        switch DataDirectoryLock.acquire(in: directory) {
        case .acquired(let lock):
            locks.append(lock)
            XCTFail("a read-only directory cannot be claimed")
        case .busy:
            XCTFail("nobody holds this directory")
        case .unavailable(let reason):
            XCTAssertTrue(reason.contains(directory.lastPathComponent), "the reason names the path: \(reason)")
        }
    }

    /// Two directories must work at once — this is the mechanism that lets a
    /// debug build run on a copy of the data while the real app is running.
    func testClaimsOnDifferentDirectoriesCoexist() throws {
        let first = try makeDirectory()
        let second = try makeDirectory()

        _ = try acquire(first)
        _ = try acquire(second)
    }

    /// A released claim leaves nothing behind that would block the next one.
    /// The kernel drops a `flock` when the holding process dies, so this is the
    /// same path a crash takes — there is no stale-lock state to clean up.
    func testDirectoryIsClaimableAgainAfterRelease() throws {
        let directory = try makeDirectory()
        let first = try acquire(directory)
        first.release()

        _ = try acquire(directory)
    }

    // MARK: - Holder Record

    func testHolderRecordNamesThePidAndBundle() throws {
        let directory = try makeDirectory()
        let holder = DataDirectoryHolder(pid: 4242, bundlePath: "/Applications/Vedivox.app", startedAt: Date())
        _ = try acquire(directory, holder: holder)

        let stored = DataDirectoryLock.readHolder(in: directory)
        XCTAssertEqual(stored?.pid, 4242)
        XCTAssertEqual(stored?.bundlePath, "/Applications/Vedivox.app")
    }

    /// The losing instance has to be able to say who won, so the record must be
    /// readable while the lock is held by someone else.
    func testRefusedClaimReportsTheHolder() throws {
        let directory = try makeDirectory()
        let holder = DataDirectoryHolder(pid: 777, bundlePath: "/Applications/Vedivox.app", startedAt: Date())
        _ = try acquire(directory, holder: holder)

        switch DataDirectoryLock.acquire(in: directory) {
        case .acquired(let second):
            locks.append(second)
            XCTFail("expected the claim to be refused")
        case .busy(let reported):
            XCTAssertEqual(reported?.pid, 777)
            XCTAssertEqual(reported?.bundlePath, "/Applications/Vedivox.app")
        case .unavailable(let reason):
            XCTFail("expected the claim to be refused as busy: \(reason)")
        }
    }

    /// Writing the record must not be able to destroy the holder's own record:
    /// it happens only after the lock is held.
    func testHolderRecordIsReplacedNotAppended() throws {
        let directory = try makeDirectory()
        let first = try acquire(directory, holder: DataDirectoryHolder(pid: 1, bundlePath: "/first", startedAt: Date()))
        first.release()
        _ = try acquire(directory, holder: DataDirectoryHolder(pid: 2, bundlePath: "/second", startedAt: Date()))

        let stored = DataDirectoryLock.readHolder(in: directory)
        XCTAssertEqual(stored?.pid, 2)
        XCTAssertEqual(stored?.bundlePath, "/second")
    }

    func testLockFileLivesInsideTheDataDirectory() throws {
        let directory = try makeDirectory()
        let lock = try acquire(directory)

        XCTAssertEqual(lock.url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.url.path))
    }

    /// A directory that does not exist yet is the first-run case; claiming it
    /// must create it rather than fail.
    func testClaimCreatesAMissingDirectory() throws {
        let parent = try makeDirectory()
        let directory = parent.appendingPathComponent("nested", isDirectory: true)

        _ = try acquire(directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }
}
