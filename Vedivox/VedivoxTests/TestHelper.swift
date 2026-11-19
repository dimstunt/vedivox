import Foundation
import GRDB
@testable import Vedivox

func makeTestDB() throws -> DatabaseManager {
    try DatabaseManager(inMemory: true)
}

func makeMeeting(
    id: String = UUID().uuidString,
    title: String = "Test Meeting",
    startTime: Date = Date(),
    status: MeetingStatus = .done,
    language: String = "ru",
    seriesId: String? = nil
) -> Meeting {
    Meeting(
        id: id,
        title: title,
        startTime: startTime,
        language: language,
        seriesId: seriesId,
        status: status
    )
}

func makeSpeaker(
    id: String = UUID().uuidString,
    name: String = "Speaker",
    isMe: Bool = false
) -> Speaker {
    Speaker(id: id, nameEn: name, isMe: isMe)
}

func makeSegment(
    meetingId: String,
    speakerId: String? = nil,
    speakerLabel: String? = nil,
    source: SegmentSource = .mic,
    startTime: Double = 0,
    endTime: Double = 5,
    text: String = "Hello world"
) -> TranscriptSegment {
    TranscriptSegment(
        meetingId: meetingId,
        speakerId: speakerId,
        speakerLabel: speakerLabel,
        source: source,
        startTime: startTime,
        endTime: endTime,
        text: text
    )
}

