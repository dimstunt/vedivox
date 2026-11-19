import XCTest

/// Retention rules for dictation audio.
///
/// The failure modes here are silent in both directions: audio deleted while
/// the user still wanted it, or never deleted at all. Neither is visible in the
/// interface until it matters.
final class DictationRetentionTests: XCTestCase {

    // MARK: - Fixtures

    private func dictation(
        _ id: String,
        daysAgo: Double,
        hasAudio: Bool = true
    ) -> Dictation {
        Dictation(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86400),
            text: "текст \(id)",
            durationSeconds: 5,
            targetApp: "Terminal",
            inserted: true,
            audioFileName: hasAudio ? "\(id).wav" : nil
        )
    }

    // MARK: - Tests

    func testNothingToDeleteUnderTheLimit() {
        let records = (0 ..< 5).map { dictation("d\($0)", daysAgo: Double($0)) }
        XCTAssertTrue(DictationRetention.audioToDelete(from: records, limit: 20).isEmpty)
    }

    func testDeletesOldestBeyondTheLimit() {
        let records = (0 ..< 5).map { dictation("d\($0)", daysAgo: Double($0)) }
        let doomed = DictationRetention.audioToDelete(from: records, limit: 3)

        // d0 is newest (0 days ago), d4 oldest.
        XCTAssertEqual(doomed.map(\.id), ["d3", "d4"])
    }

    /// The invariant the whole feature rests on: the text of a trimmed dictation
    /// stays. Retention returns records to strip audio from, never rows to drop.
    func testTrimmedRecordsKeepTheirText() {
        let records = (0 ..< 4).map { dictation("d\($0)", daysAgo: Double($0)) }
        let doomed = DictationRetention.audioToDelete(from: records, limit: 1)

        for record in doomed {
            XCTAssertFalse(record.text.isEmpty)
            XCTAssertNotNil(record.audioFileName)
        }
    }

    /// Records already stripped of audio must not occupy a slot — otherwise a
    /// long history would push out recent audio for nothing.
    func testRecordsWithoutAudioDoNotConsumeSlots() {
        let records = [
            dictation("new1", daysAgo: 0),
            dictation("new2", daysAgo: 1),
            dictation("old-noaudio1", daysAgo: 10, hasAudio: false),
            dictation("old-noaudio2", daysAgo: 11, hasAudio: false),
        ]

        XCTAssertTrue(DictationRetention.audioToDelete(from: records, limit: 2).isEmpty)
    }

    /// Audio a quit left owed a recognition is the only copy of what was said:
    /// never trimmed, and it does not push others out.
    func testAwaitingAudioIsNeverDeletedAndTakesNoSlot() {
        var owed = dictation("owed", daysAgo: 30)
        owed.awaitingTranscription = true
        let records = [dictation("new", daysAgo: 0), owed, dictation("old", daysAgo: 1)]

        XCTAssertEqual(DictationRetention.audioToDelete(from: records, limit: 1).map(\.id), ["old"])
        XCTAssertTrue(DictationRetention.audioToDelete(from: records, limit: 0).allSatisfy { $0.id != "owed" })
    }

    func testLimitZeroDeletesEveryAudio() {
        let records = (0 ..< 3).map { dictation("d\($0)", daysAgo: Double($0)) }
        XCTAssertEqual(DictationRetention.audioToDelete(from: records, limit: 0).count, 3)
    }

    /// A negative limit is a programming error, not an instruction to wipe
    /// everything — the destructive reading would be unrecoverable.
    func testNegativeLimitDeletesNothing() {
        let records = (0 ..< 3).map { dictation("d\($0)", daysAgo: Double($0)) }
        XCTAssertTrue(DictationRetention.audioToDelete(from: records, limit: -1).isEmpty)
    }

    func testEmptyHistory() {
        XCTAssertTrue(DictationRetention.audioToDelete(from: [], limit: 5).isEmpty)
    }

    /// Input order must not matter: the caller fetches in whatever order the
    /// query returns.
    func testUnsortedInputIsHandled() {
        let records = [
            dictation("oldest", daysAgo: 9),
            dictation("newest", daysAgo: 0),
            dictation("middle", daysAgo: 4),
        ]
        XCTAssertEqual(DictationRetention.audioToDelete(from: records, limit: 1).map(\.id), ["middle", "oldest"])
    }
}
