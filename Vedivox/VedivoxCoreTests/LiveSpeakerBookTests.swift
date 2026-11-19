import XCTest

/// Who is who from one precise pass to the next (an earlier change,
/// design D5): stable keys for the voices of the passes and the names the
/// passes give them, on synthetic 4-dimensional vectors.
final class LiveSpeakerBookTests: XCTestCase {

    private let alice: [Float] = [1, 0, 0, 0]
    private let bob: [Float] = [0, 1, 0, 0]
    private let carol: [Float] = [0, 0, 1, 0]

    // MARK: Keys

    func testTwoVoicesGetTwoStableLabels() {
        var book = LiveSpeakerBook()
        let first = book.assign(voice: alice, seconds: 3)
        let second = book.assign(voice: bob, seconds: 3)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(book.assign(voice: alice, seconds: 3), first)
        XCTAssertEqual(book.assign(voice: bob, seconds: 3), second)
        XCTAssertEqual(book.speakers.map(\.name), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(book.speakers.map(\.kind), [.unknown, .unknown])
    }

    func testAVoiceReturnsToItsClusterAfterOthersSpoke() {
        var book = LiveSpeakerBook()
        let first = book.assign(voice: alice, seconds: 4)
        _ = book.assign(voice: bob, seconds: 4)
        _ = book.assign(voice: carol, seconds: 4)
        // The same person on another day of the call: close, not identical.
        XCTAssertEqual(book.assign(voice: [0.9, 0.3, 0.3, 0], seconds: 4), first)
        XCTAssertEqual(book.speakers.count, 3)
    }

    func testTheCentroidFollowsTheVoicesThatJoin() {
        var book = LiveSpeakerBook()
        let key = book.assign(voice: alice, seconds: 3)
        XCTAssertEqual(book.assign(voice: [0.6, 0.8, 0, 0], seconds: 3), key)
        // 0.3 to where the cluster started — a stranger; 0.69 to where it is now.
        XCTAssertEqual(book.assign(voice: [0.3, 0.954, 0, 0], seconds: 3), key)
        XCTAssertEqual(book.speakers.count, 1)
    }

    func testAThinVoiceStartsNoClusterButJoinsOne() {
        var book = LiveSpeakerBook()
        XCTAssertNil(book.assign(voice: bob, seconds: 1.5), "under minNewVoiceSeconds nobody is created")
        XCTAssertEqual(book.speakers.count, 0)

        let key = book.assign(voice: bob, seconds: 3)
        XCTAssertEqual(book.assign(voice: bob, seconds: 1.5), key)
        XCTAssertNil(book.assign(voice: bob, seconds: 0.5), "under minVoiceSeconds the vector is not trusted at all")
        XCTAssertEqual(book.speakers.count, 1)
    }

    func testNoVectorIsNoVoice() {
        var book = LiveSpeakerBook()
        XCTAssertNil(book.assign(voice: [], seconds: 5))
        XCTAssertNil(book.assign(voice: [0, 0, 0, 0], seconds: 5))
        XCTAssertNil(book.assign(voice: [.nan, 1, 0, 0], seconds: 5))
        XCTAssertEqual(book.speakers.count, 0)
    }

    /// A precondition failure here would end the app mid-recording.
    func testVectorsOfAnotherSizeAreKeptApartNotCompared() {
        var book = LiveSpeakerBook()
        let first = book.assign(voice: alice, seconds: 12)
        let second = book.assign(voice: [1, 0, 0], seconds: 3)
        XCTAssertNotEqual(first, second)
    }

    // MARK: Names given by a precise pass (D5)

    private func identity(_ name: String, _ confidence: Float = 0.8) -> LiveSpeakerBook.Identity {
        .init(speakerId: name.lowercased(), name: name, confidence: confidence)
    }

    func testAVoiceThePassNamedIsNamedAtOnceAndKeepsTheName() {
        var book = LiveSpeakerBook()
        let key = book.assign(voice: alice, seconds: 4, identity: identity("Alice", 0.81))
        XCTAssertEqual(book.speakers, [LiveSpeaker(kind: .known, name: "Alice", confidence: 0.81)])

        // The next tail is too short for a name: the voice still finds its key.
        XCTAssertEqual(book.assign(voice: alice, seconds: 6), key)
        XCTAssertEqual(book.speakers.first?.name, "Alice")
    }

    func testANamedVoiceGoesToItsSpeakersKeyWhateverTheVectorsSay() {
        var book = LiveSpeakerBook()
        let key = book.assign(voice: alice, seconds: 20, identity: identity("Alice"))
        // Orthogonal to where her key started: the pass says it is her.
        XCTAssertEqual(book.assign(voice: carol, seconds: 20, identity: identity("Alice")), key)
        XCTAssertEqual(book.speakers.count, 1)
    }

    func testANamedVoiceNeverJoinsSomebodyElsesKey() {
        var book = LiveSpeakerBook()
        let first = book.assign(voice: alice, seconds: 20, identity: identity("Alice"))
        // As close to Alice's key as a voice gets — and the pass says Bob.
        let second = book.assign(voice: alice, seconds: 20, identity: identity("Bob"))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(book.speakers.map(\.name), ["Alice", "Bob"])
    }

    func testANameGivenLaterRenamesTheKeyTheVoiceAlreadyHad() {
        var book = LiveSpeakerBook()
        let key = book.assign(voice: alice, seconds: 8)
        XCTAssertEqual(book.speakers.first?.name, "Speaker 1")

        XCTAssertEqual(book.assign(voice: alice, seconds: 30, identity: identity("Alice")), key)
        XCTAssertEqual(book.speakers.map(\.name), ["Alice"], "what Speaker 1 said is hers now")
    }
}
