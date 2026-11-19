import XCTest

/// Teams mute from the AX tree, on synthetic trees.
final class TeamsMuteTests: XCTestCase {
    private final class Node {
        let info: AXNodeInfo
        let children: [Node]
        /// A dead element: the read fails, its subtree is unreachable.
        let dead: Bool

        init(_ role: String, id: String? = nil, title: String? = nil, desc: String? = nil, dead: Bool = false, _ children: [Node] = []) {
            info = AXNodeInfo(role: role, domId: id, title: title, description: desc)
            self.children = children
            self.dead = dead
        }
    }

    private func find(_ roots: [Node], limit: Int = 1000) -> (state: MuteState, path: [AXNodeInfo])? {
        TeamsMuteRules.find(in: roots, limit: limit) { $0.dead ? nil : ($0.info, $0.children) }
            .map { ($0.state, $0.path.map(\.info)) }
    }

    /// A meeting window: roster with per-person mute buttons first, then the toolbar.
    private func meeting(mic: Node) -> Node {
        Node("AXWindow", title: "Meeting | Microsoft Teams", [
            Node("AXGroup", [
                Node("AXWebArea", [
                    Node("AXGroup", desc: "Participants", [
                        Node("AXButton", desc: "Mute all"),
                        Node("AXButton", desc: "Mute Alex"),
                        Node("AXStaticText", desc: "Unmute mic"),
                    ]),
                    Node("AXToolbar", desc: "Meeting controls", [
                        Node("AXButton", id: "video-button", desc: "Turn camera on"),
                        mic,
                        Node("AXButton", id: "hangup-button", desc: "Leave"),
                    ]),
                ]),
            ]),
        ])
    }

    func testMicButtonByIdNamesTheAction() {
        let muted = find([meeting(mic: Node("AXButton", id: "microphone-button", desc: "Unmute mic"))])
        XCTAssertEqual(muted?.state, .muted)
        XCTAssertEqual(muted?.path.map(\.role), ["AXWindow", "AXGroup", "AXWebArea", "AXToolbar", "AXButton"])
        XCTAssertEqual(find([meeting(mic: Node("AXCheckBox", id: "microphone-button", desc: "Mute mic"))])?.state, .unmuted)
    }

    func testMicButtonByLabelWithoutId() {
        XCTAssertEqual(find([meeting(mic: Node("AXButton", desc: "Unmute (⌘+Shift+M)"))])?.state, .muted)
        XCTAssertEqual(find([meeting(mic: Node("AXButton", title: "Mute mic"))])?.state, .unmuted)
    }

    func testRosterAndTextAreNotTheMicButton() {
        XCTAssertNil(find([meeting(mic: Node("AXButton", desc: "Mic"))]), "«Mute all», «Mute Alex» и текст «Unmute mic» не кнопка микрофона")
    }

    func testIdWithUnknownLabelIsUnknown() {
        XCTAssertEqual(find([meeting(mic: Node("AXButton", id: "microphone-button", desc: "Mic"))])?.state, .unknown)
        XCTAssertEqual(find([meeting(mic: Node("AXButton", id: "microphone-button", desc: "Muted"))])?.state, .unknown,
                       "«Muted» — не действие «Mute»")
    }

    func testFirstWindowInOrderWins() {
        let chat = Node("AXWindow", title: "Chat | Microsoft Teams", [Node("AXButton", desc: "Send")])
        let compact = Node("AXWindow", [Node("AXButton", id: "microphone-button", desc: "Mute mic")])
        let full = meeting(mic: Node("AXButton", id: "microphone-button", desc: "Unmute mic"))
        XCTAssertEqual(find([chat, compact, full])?.state, .unmuted)
    }

    func testDeadSubtreeIsSkipped() {
        let dead = Node("AXGroup", dead: true, [Node("AXButton", id: "microphone-button", desc: "Mute mic")])
        XCTAssertNil(find([Node("AXWindow", [dead])]))
    }

    func testLimitBoundsTheWalk() {
        let window = meeting(mic: Node("AXButton", id: "microphone-button", desc: "Mute mic"))
        // Window, group, web area, roster + 3, toolbar, video, mic = 10th element.
        XCTAssertNil(find([window], limit: 9))
        XCTAssertNotNil(find([window], limit: 10))
    }

    // MARK: Readers

    private final class FakeReader: MuteReader {
        let appName: String
        let markSource: MarkSource
        let state: MuteState
        let unknownLabel: String? = nil

        init(_ source: MarkSource, _ state: MuteState) {
            appName = source.rawValue
            markSource = source
            self.state = state
        }

        func read() -> MuteState { state }
    }

    func testFirstKnownReaderWins() {
        let zoomIdle = FakeReader(.zoomMute, .unknown)
        let teamsMuted = FakeReader(.teamsMute, .muted)
        XCTAssertTrue(MuteMonitor.read([zoomIdle, teamsMuted]) == (.muted, .teamsMute))
        XCTAssertTrue(MuteMonitor.read([FakeReader(.zoomMute, .unmuted), teamsMuted]) == (.unmuted, .zoomMute))
        XCTAssertTrue(MuteMonitor.read([zoomIdle, FakeReader(.teamsMute, .unknown)]) == (.unknown, nil))
    }
}
