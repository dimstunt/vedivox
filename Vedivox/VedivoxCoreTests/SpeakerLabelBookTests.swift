import XCTest

/// stage2-out-of-pool: one label names exactly one record within a meeting.
final class SpeakerLabelBookTests: XCTestCase {
    func testFreeNameIsUsedAsIs() {
        var book = SpeakerLabelBook()
        XCTAssertEqual(book.label(for: "Катя", speakerId: "a"), "Катя")
        XCTAssertEqual(book.bindings, ["Катя": "a"])
    }

    func testSameRecordKeepsItsLabel() {
        var book = SpeakerLabelBook()
        _ = book.label(for: "speaker_1", speakerId: "a")
        _ = book.label(for: "speaker_1", speakerId: "b") // → speaker_2
        XCTAssertEqual(book.label(for: "speaker_1", speakerId: "b"), "speaker_2")
        XCTAssertEqual(book.bindings.count, 2)
    }

    func testGivenNameCollisionTakesNextFreeSuffix() {
        var book = SpeakerLabelBook(bindings: ["Катя": "a", "Катя (2)": "b"])
        XCTAssertEqual(book.label(for: "Катя", speakerId: "c"), "Катя (3)")
    }

    func testAutoLabelCollisionSkipsReservedNumbers() {
        // speaker_4 is a fresh mint on the other track — not bound, still taken.
        var book = SpeakerLabelBook(bindings: ["speaker_1": "a"], reserved: ["speaker_4"])
        XCTAssertEqual(book.label(for: "speaker_1", speakerId: "b"), "speaker_5")
        XCTAssertEqual(book.highestAutoNumber(), 5)
    }
}
