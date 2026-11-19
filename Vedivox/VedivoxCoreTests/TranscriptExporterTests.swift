import XCTest

/// Export and Copy show the same turns as the transcript view, not raw ASR
/// fragments ("… publish" / "it." as two lines).
final class TranscriptExporterTests: XCTestCase {

    private static func segment(_ id: Int64, _ label: String, _ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        var seg = makeSegment(meetingId: "m", speakerLabel: label, startTime: start, endTime: end, text: text)
        seg.id = id
        return seg
    }

    private let segments = [
        TranscriptExporterTests.segment(1, "speaker_1", 5, 10, "we should publish"),
        TranscriptExporterTests.segment(2, "speaker_1", 10, 10.5, "it."),
        TranscriptExporterTests.segment(3, "Alice", 11, 14, "Agreed."),
    ]

    func testPlainTextGroupsFragmentsIntoTurns() {
        XCTAssertEqual(
            TranscriptExporter.plainText(segments: segments),
            "[00:05 → 00:10] speaker_1: we should publish it.\n[00:11 → 00:14] Alice: Agreed."
        )
    }

    func testMarkdownGroupsFragmentsIntoTurns() {
        let md = TranscriptExporter.markdown(meeting: makeMeeting(), segments: segments)
        XCTAssertTrue(md.contains("[00:05 → 00:10] **speaker_1:** we should publish it.\n\n"))
        XCTAssertTrue(md.contains("[00:11 → 00:14] **Alice:** Agreed."))
        XCTAssertFalse(md.contains("**speaker_1:** it."))
    }
}
