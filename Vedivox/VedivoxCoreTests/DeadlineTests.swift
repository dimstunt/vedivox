import XCTest

/// A call that hangs in Core Audio must not hang its caller.
final class DeadlineTests: XCTestCase {
    func testReturnsTheValueWhenInTime() async throws {
        let value = try await Deadline.run(limit: .seconds(5)) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testPassesTheOperationsErrorThrough() async {
        struct Boom: Error {}
        do {
            _ = try await Deadline.run(limit: .seconds(5)) { () async throws -> Int in throw Boom() }
            XCTFail("expected Boom")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    /// The operation never returns: the caller gets `TimedOut` at the limit,
    /// and the operation is left running, not cancelled.
    func testThrowsAtTheLimitWhenTheOperationHangs() async {
        let release = AsyncStream<Void>.makeStream()
        let started = Date()
        do {
            _ = try await Deadline.run(limit: .milliseconds(100)) {
                for await _ in release.stream {}
                return 1
            }
            XCTFail("expected TimedOut")
        } catch {
            XCTAssertTrue(error is Deadline.TimedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        release.continuation.finish()
    }
}
