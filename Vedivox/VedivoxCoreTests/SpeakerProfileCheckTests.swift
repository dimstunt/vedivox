import XCTest

final class SpeakerProfileCheckTests: XCTestCase {
    private let bob = Speaker(nameEn: "Bob", nickname: "bobby")

    private func check(_ en: String, _ nick: String = "", _ ru: String = "", id: String = "self") -> SpeakerProfileCheck {
        SpeakerProfileCheck.check(nameEn: en, nickname: nick, nameRu: ru, speakerId: id, others: [bob])
    }

    func testBlankNameIsRefused() {
        XCTAssertEqual(check("   "), .empty)
    }

    func testAutoLabelInAnyFieldIsRefused() {
        XCTAssertEqual(check("speaker_3"), .autoLabel)
        XCTAssertEqual(check("Alice", "speaker_1"), .autoLabel)
    }

    func testNameOfAnotherRecordOffersMerge() {
        XCTAssertEqual(check("bob "), .taken(speakerId: bob.id, name: "bobby"))
        XCTAssertEqual(check("Alice", "", "BOBBY"), .taken(speakerId: bob.id, name: "bobby"))
    }

    func testOwnNameAndBlankOptionalFieldsAreFine() {
        XCTAssertEqual(check("Bob", id: bob.id), .ok)
        XCTAssertEqual(check("Alice", " ", " "), .ok)
    }
}
