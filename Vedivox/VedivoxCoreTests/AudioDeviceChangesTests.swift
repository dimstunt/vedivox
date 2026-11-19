import XCTest

/// The plug itself needs hardware; this covers the part that can break
/// without it — a Settings section that closes must take its listener along.
final class AudioDeviceChangesTests: XCTestCase {
    func testCancelledConsumerEndsTheStream() async {
        let consumer = Task {
            for await _ in AudioDeviceChanges.stream() {}
            return true
        }
        try? await Task.sleep(for: .milliseconds(100))
        consumer.cancel()
        let ended = await consumer.value
        XCTAssertTrue(ended)
    }
}
