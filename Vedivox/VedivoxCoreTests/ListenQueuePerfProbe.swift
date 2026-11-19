import XCTest

/// Times the listen queue on a copy of a real database. Not a gate:
/// skipped unless a copy is named. The copy is opened read-only and is not
/// migrated, so take it from a database that already has v27.
///
///     sqlite3 -readonly ~/Library/Application\ Support/Vedivox/Vedivox.sqlite "VACUUM INTO '/tmp/vedivox-copy.sqlite'"
///     cd Vedivox && TEST_RUNNER_VEDIVOX_LISTEN_PERF_DB=/tmp/vedivox-copy.sqlite xcodebuild test \
///       -project Vedivox.xcodeproj -scheme VedivoxCoreTests -destination 'platform=macOS' \
///       -only-testing:VedivoxCoreTests/ListenQueuePerfProbe -derivedDataPath <derived>
///
/// Phases are in the log as `[Perf] ListenQueueBuilder.build …` (debug level).
final class ListenQueuePerfProbe: XCTestCase {
    func testBuildTimings() async throws {
        guard let path = ProcessInfo.processInfo.environment["VEDIVOX_LISTEN_PERF_DB"] else {
            throw XCTSkip("set TEST_RUNNER_VEDIVOX_LISTEN_PERF_DB to a database copy")
        }
        let db = try DatabaseManager(readOnlySnapshot: path)
        for run in 1 ... 6 {
            let start = CFAbsoluteTimeGetCurrent()
            let count = try await ListenQueueBuilder(db: db).count()
            let counted = CFAbsoluteTimeGetCurrent()
            let items = try await ListenQueueBuilder(db: db).build()
            let built = CFAbsoluteTimeGetCurrent()
            print(String(format: "[Perf][Listen] run=%d count=%d %.0fms build=%d %.0fms",
                         run, count, (counted - start) * 1000, items.count, (built - counted) * 1000))
        }
    }
}
