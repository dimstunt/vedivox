import XCTest

/// The deaf-tap rebuild second by second: a stretch of digital
/// zero while a call plays is rebuilt after a minute, real silence costs a
/// few rebuilds an hour, sound starts the wait over.
final class DeafTapWatchTests: XCTestCase {

    /// Seconds 0 ..< `seconds`; `sound(t)`: the tap delivers a non-zero
    /// sample in second t, `healed` — after the first rebuild it always does.
    private func rebuilds(
        seconds: Int, call: Bool = true, healsOnRebuild: Bool = false, sound: (Int) -> Bool
    ) -> [Int] {
        var watch = DeafTapWatch()
        var zeroRun = 0.0
        var heard = false
        var times: [Int] = []
        for t in 0 ..< seconds {
            if sound(t) || (healsOnRebuild && !times.isEmpty) {
                zeroRun = 0
                heard = true
            } else {
                zeroRun += 1
            }
            if watch.shouldRebuild(zeroRun: zeroRun, heardSinceRebuild: heard, callOutputting: call) {
                times.append(t)
                zeroRun = 0 // a fresh stream
                heard = false
            }
        }
        return times
    }

    func testRealSilenceDuringACallCostsEightRebuildsAnHour() {
        let times = rebuilds(seconds: 3600) { _ in false }
        XCTAssertEqual(times, [59, 179, 419, 899, 1499, 2099, 2699, 3299])
    }

    func testNoRebuildWhileNoCallPlays() {
        XCTAssertEqual(rebuilds(seconds: 3600, call: false) { _ in false }, [])
    }

    func testPausesInATalkDoNotRebuild() {
        // 40 s of talk, 20 s of digital zero, for an hour
        XCTAssertEqual(rebuilds(seconds: 3600) { $0 % 60 < 40 }, [])
    }

    func testTheNineteenthOfNovemberIsRebuiltWithinAMinuteAndTheWaitStartsOver() {
        // 19.11: deaf from 1698 s, one system sound at 1705 s, otherwise zero
        let deaf = rebuilds(seconds: 3000) { $0 < 1698 || $0 == 1705 }
        XCTAssertEqual(deaf.first, 1765)
        // if the rebuild brings the call back, nothing more happens
        XCTAssertEqual(rebuilds(seconds: 3000, healsOnRebuild: true) { $0 < 1698 || $0 == 1705 }, [1765])
    }

    func testSoundBetweenRebuildsBringsTheWaitBackToAMinute() {
        var watch = DeafTapWatch()
        XCTAssertTrue(watch.shouldRebuild(zeroRun: 60, heardSinceRebuild: false, callOutputting: true))
        XCTAssertEqual(watch.wait, 120)
        XCTAssertFalse(watch.shouldRebuild(zeroRun: 60, heardSinceRebuild: false, callOutputting: true))
        XCTAssertTrue(watch.shouldRebuild(zeroRun: 60, heardSinceRebuild: true, callOutputting: true))
    }
}
