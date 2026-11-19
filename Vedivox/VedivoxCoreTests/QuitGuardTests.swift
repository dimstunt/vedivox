import XCTest

/// What ⌘Q, a logout or a restart does to a meeting in progress.
@MainActor
final class QuitGuardTests: XCTestCase {
    func testDecision() {
        XCTAssertEqual(QuitGuard.decide(recording: false, processing: false, dictating: false, poweringOff: false), .quitNow)
        XCTAssertEqual(QuitGuard.decide(recording: true, processing: false, dictating: false, poweringOff: false), .stopFirst)
        XCTAssertEqual(QuitGuard.decide(recording: true, processing: true, dictating: false, poweringOff: true), .stopFirst)
        XCTAssertEqual(QuitGuard.decide(recording: false, processing: true, dictating: false, poweringOff: false), .askAboutProcessing)
        // Nobody is there to answer during a logout; the next launch resumes the processing.
        XCTAssertEqual(QuitGuard.decide(recording: false, processing: true, dictating: false, poweringOff: true), .quitNow)
    }

    /// A dictation asks, during a meeting recording too (item 10); a
    /// logout does not ask, but still saves the dictation before quitting.
    func testDecisionDuringDictation() {
        XCTAssertEqual(QuitGuard.decide(recording: false, processing: false, dictating: true, poweringOff: false), .askAboutDictation)
        XCTAssertEqual(QuitGuard.decide(recording: true, processing: false, dictating: true, poweringOff: false), .askAboutDictation)
        XCTAssertEqual(QuitGuard.decide(recording: true, processing: false, dictating: true, poweringOff: true), .stopFirst)
        XCTAssertEqual(QuitGuard.decide(recording: false, processing: true, dictating: true, poweringOff: false), .askAboutDictation)
        XCTAssertEqual(QuitGuard.decide(recording: false, processing: false, dictating: true, poweringOff: true), .stopFirst)
    }

    func testQuitsOnceTheStopFinishes() async {
        var replies: [Bool] = []
        let replied = expectation(description: "reply")
        QuitGuard.stopThenQuit(limit: .seconds(30), stop: {}, reply: {
            replies.append($0)
            replied.fulfill()
        })
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(replies, [true])
    }

    /// A stop that hangs must not hang a logout: the quit goes ahead at the limit, once.
    func testQuitsAtTheLimitWhenTheStopHangs() async {
        var replies: [Bool] = []
        let replied = expectation(description: "reply")
        let release = AsyncStream<Void>.makeStream()
        QuitGuard.stopThenQuit(limit: .milliseconds(100), stop: {
            for await _ in release.stream {}
        }, reply: {
            replies.append($0)
            replied.fulfill()
        })
        await fulfillment(of: [replied], timeout: 5)
        release.continuation.finish()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(replies, [true], "the stop finishing late does not answer a second time")
    }
}
