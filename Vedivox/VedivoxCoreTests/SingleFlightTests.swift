import XCTest

private struct FlightTestError: Error {}

/// Counts how many times the underlying operation actually executed.
private actor FlightCounter {
    private(set) var count = 0
    func incAndReturn(delayMs: UInt64) async -> Int {
        count += 1
        let mine = count
        try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
        return mine
    }
}

/// Throws on the first call, succeeds afterwards.
private actor FailFirst {
    private(set) var callCount = 0
    func run() async throws -> Int {
        callCount += 1
        if callCount == 1 { throw FlightTestError() }
        return 42
    }
}

/// Verifies the in-flight deduplication that keeps first-run model downloads
/// from firing twice. We can't exercise the real HuggingFace
/// download in a headless run, so the dedup property is proven here in
/// isolation and reused by TranscriptionService/DiarizationService.
final class SingleFlightTests: XCTestCase {

    func testConcurrentCallersRunOperationOnce() async throws {
        let flight = SingleFlight<Int>()
        let counter = FlightCounter()

        async let a = flight.run { await counter.incAndReturn(delayMs: 60) }
        async let b = flight.run { await counter.incAndReturn(delayMs: 60) }
        async let c = flight.run { await counter.incAndReturn(delayMs: 60) }

        let results = try await [a, b, c]

        // The operation ran exactly once…
        let count = await counter.count
        XCTAssertEqual(count, 1, "underlying operation should run once for concurrent callers")
        // …and every caller observed the same value.
        XCTAssertEqual(Set(results).count, 1, "all callers should share the single result")
        let runCount = await flight.runCount
        XCTAssertEqual(runCount, 1)
    }

    func testCachedResultSkipsSecondRun() async throws {
        let flight = SingleFlight<Int>()
        let counter = FlightCounter()

        _ = try await flight.run { await counter.incAndReturn(delayMs: 0) }
        _ = try await flight.run { await counter.incAndReturn(delayMs: 0) }

        let count = await counter.count
        XCTAssertEqual(count, 1, "second call should return the cached value without re-running")
    }

    func testErrorIsNotCachedAndRetries() async throws {
        let flight = SingleFlight<Int>()
        let box = FailFirst()

        do {
            _ = try await flight.run { try await box.run() }
            XCTFail("first call should throw")
        } catch {
            // expected
        }

        // Error was not cached → the retry actually re-runs and succeeds.
        let value = try await flight.run { try await box.run() }
        XCTAssertEqual(value, 42)
        let calls = await box.callCount
        XCTAssertEqual(calls, 2, "failure must not be cached; retry re-runs the operation")
    }
}
