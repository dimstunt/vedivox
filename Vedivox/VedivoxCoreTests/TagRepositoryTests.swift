import XCTest
import GRDB

final class TagRepositoryTests: XCTestCase {

    private var db: DatabaseManager!
    private var repo: TagRepository!
    private var meetingRepo: MeetingRepository!

    override func setUp() async throws {
        db = try makeTestDB()
        repo = TagRepository(db: db)
        meetingRepo = MeetingRepository(db: db)
    }

    func testSaveTag() async throws {
        let tag = Tag(name: "important")
        try await repo.save(tag)

        let all = try await repo.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].name, "important")
    }

    func testAddTagToMeeting() async throws {
        let meeting = makeMeeting()
        let tag = Tag(name: "weekly")
        try await meetingRepo.save(meeting)
        try await repo.save(tag)

        try await repo.addTagToMeeting(tagId: tag.id, meetingId: meeting.id)

        let tags = try await repo.tagsForMeeting(meeting.id)
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags[0].id, tag.id)
    }

    func testRemoveTagFromMeeting() async throws {
        let meeting = makeMeeting()
        let tag = Tag(name: "weekly")
        try await meetingRepo.save(meeting)
        try await repo.save(tag)
        try await repo.addTagToMeeting(tagId: tag.id, meetingId: meeting.id)

        try await repo.removeTagFromMeeting(tagId: tag.id, meetingId: meeting.id)

        let tags = try await repo.tagsForMeeting(meeting.id)
        XCTAssertTrue(tags.isEmpty)
    }

    func testTagsForMeeting() async throws {
        let meeting = makeMeeting()
        let tag1 = Tag(name: "alpha")
        let tag2 = Tag(name: "beta")
        let tag3 = Tag(name: "gamma")

        try await meetingRepo.save(meeting)
        try await repo.save(tag1)
        try await repo.save(tag2)
        try await repo.save(tag3)

        try await repo.addTagToMeeting(tagId: tag1.id, meetingId: meeting.id)
        try await repo.addTagToMeeting(tagId: tag3.id, meetingId: meeting.id)

        let tags = try await repo.tagsForMeeting(meeting.id)
        XCTAssertEqual(tags.count, 2)
        XCTAssertEqual(tags[0].name, "alpha", "Should be ordered by name")
        XCTAssertEqual(tags[1].name, "gamma")
    }

    func testDeleteMeeting_cascadesTagLinks() async throws {
        let meeting = makeMeeting()
        let tag = Tag(name: "weekly")
        try await meetingRepo.save(meeting)
        try await repo.save(tag)
        try await repo.addTagToMeeting(tagId: tag.id, meetingId: meeting.id)

        try await meetingRepo.deleteBatch([meeting.id])

        // Tag itself still exists
        let allTags = try await repo.all()
        XCTAssertEqual(allTags.count, 1)

        // But the link is gone
        let tags = try await repo.tagsForMeeting(meeting.id)
        XCTAssertTrue(tags.isEmpty)
    }
}
