import XCTest
import GRDB

final class SpeakerChipFilterTests: XCTestCase {

    private let ann = makeSpeaker(id: "ann", name: "Ann")
    private let bob = makeSpeaker(id: "bob", name: "Bob")
    private let cid = makeSpeaker(id: "cid", name: "Cid")
    private let meetings = ["m1", "m2", "m3"].map { makeMeeting(id: $0) }

    private func link(_ meeting: String, _ speaker: String) -> SpeakerChipFilter.Link {
        SpeakerChipFilter.Link(meetingId: meeting, speakerId: speaker)
    }

    private var filter: SpeakerChipFilter {
        SpeakerChipFilter(
            speakers: [cid, bob, ann],
            links: [link("m1", "ann"), link("m2", "ann"), link("m3", "ann"), link("m1", "bob"), link("m2", "cid"), link("m3", "bob")]
        )
    }

    func testChipsCountMeetingsMostFirstThenByName() {
        XCTAssertEqual(filter.chips.map(\.label), ["Ann", "Bob", "Cid"])
        XCTAssertEqual(filter.chips.map(\.meetingCount), [3, 2, 1])
    }

    func testFilterKeepsMeetingsWithEverySelectedSpeaker() {
        XCTAssertEqual(filter.filter(meetings, selection: []).map(\.id), ["m1", "m2", "m3"])
        XCTAssertEqual(filter.filter(meetings, selection: [.speaker("bob")]).map(\.id), ["m1", "m3"])
        XCTAssertEqual(filter.filter(meetings, selection: [.speaker("bob"), .speaker("ann")]).map(\.id), ["m1", "m3"])
        XCTAssertEqual(filter.filter(meetings, selection: [.speaker("bob"), .speaker("cid")]).map(\.id), [])
    }

    func testUnnamedSpeakersFoldIntoOneChipLast() {
        let one = makeSpeaker(id: "u1", name: "speaker_1")
        let two = makeSpeaker(id: "u2", name: "speaker_1")
        let named = Speaker(id: "u3", nameEn: "speaker_2", nameRu: "Dee")
        let filter = SpeakerChipFilter(
            speakers: [one, two, named, ann],
            links: [link("m1", "u1"), link("m3", "u2"), link("m2", "u3"), link("m2", "ann")]
        )

        XCTAssertEqual(filter.chips.map(\.label), ["Ann", "Dee", "2 unnamed"])
        XCTAssertEqual(filter.chips.last?.meetingCount, 2)
        XCTAssertEqual(filter.speakerCount, 4)
        XCTAssertEqual(filter.filter(meetings, selection: [.unnamed]).map(\.id), ["m1", "m3"])
        XCTAssertEqual(filter.filter(meetings, selection: [.unnamed, .speaker("ann")]).map(\.id), [])
    }

    func testSpokenLinksSkipSpeakersWithoutKeptLines() async throws {
        let db = try makeTestDB()
        let meetingRepo = MeetingRepository(db: db)
        let repo = SpeakerRepository(db: db)
        let m = makeMeeting()
        try await meetingRepo.save(m)
        for s in [ann, bob, cid] { try await repo.save(s) }
        var hidden = makeSegment(meetingId: m.id, speakerId: cid.id, startTime: 10, endTime: 12)
        hidden.isExcluded = true
        try await meetingRepo.saveSegments([makeSegment(meetingId: m.id, speakerId: ann.id), hidden])
        // Bob is linked but every line went to someone else; Cid's only line is excluded.
        for s in [ann, bob, cid] {
            try await repo.assignSpeakerToMeeting(meetingId: m.id, speakerId: s.id, diarizationLabel: nil)
        }

        let spoken = try await repo.spokenLinks(meetingIds: [m.id])

        XCTAssertEqual(spoken.links, [link(m.id, ann.id)])
        XCTAssertEqual(spoken.speakers.map(\.id), [ann.id])
    }
}
