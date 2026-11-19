import XCTest

/// speaker-row-per-mint (design § решение 5): отметка диаризатора — маркер
/// пространства эмбеддингов — переживает разрез встречи и его отмену. Без неё
/// оффлайн-векторы разрезанной встречи утекали в пул v1 (реальный случай
/// one meeting: 718 из 1000 реплик пересчёта v1 пришли из такой встречи).
final class MeetingDiarizerTests: XCTestCase {

    func testDiarizerSurvivesSplitAndUndo() async throws {
        let db = try makeTestDB()
        let meetingRepo = MeetingRepository(db: db)
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedivox-diarizer-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var meeting = makeMeeting()
        meeting.durationSeconds = 100
        try await meetingRepo.save(meeting)
        try await meetingRepo.saveSegments([
            makeSegment(meetingId: meeting.id, source: .system, startTime: 0, endTime: 40),
            makeSegment(meetingId: meeting.id, source: .system, startTime: 60, endTime: 100),
        ])
        try await meetingRepo.setDiarizer(meeting.id, kind: "offline")
        try await meetingRepo.updateForeignVoiceDecision(meeting.id, .kept)

        let (m1, m2) = try await meetingRepo.splitMeeting(meeting.id, atTime: 50, audioRoot: tempRoot)
        let d1 = try await meetingRepo.find(m1.id)?.diarizer
        let d2 = try await meetingRepo.find(m2.id)?.diarizer
        XCTAssertEqual(d1, "offline")
        XCTAssertEqual(d2, "offline", "новая встреча несёт ту же отметку")
        let fv2 = try await meetingRepo.find(m2.id)?.foreignVoiceDecision
        XCTAssertEqual(fv2, .kept, "решение по чужим голосам тоже переживает разрез (дыра f274729)")

        try await meetingRepo.undoSplit(meeting.id, audioRoot: tempRoot)
        let restored = try await meetingRepo.find(meeting.id)?.diarizer
        XCTAssertEqual(restored, "offline", "после отмены разреза отметка на месте")
    }
}
