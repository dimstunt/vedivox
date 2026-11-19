import XCTest

/// The player's track choice must always name a track the loaded meeting has.
/// Reported live: pick «Sys» on a two-track meeting, switch to a mic-only one —
/// the waveform goes flat, playback is silent, and the switcher is hidden so
/// there is no way back.
final class AudioTrackClampTests: XCTestCase {

    func testSystemChoiceFallsBackWhenTheMeetingHasNoSystemTrack() {
        XCTAssertEqual(
            AudioTrack.system.clamped(hasMic: true, hasSystem: false), .mix,
            "иначе дорожка немая, волна плоская, а переключателя нет"
        )
    }

    func testMicChoiceFallsBackWhenTheMeetingHasNoMicTrack() {
        XCTAssertEqual(AudioTrack.mic.clamped(hasMic: false, hasSystem: true), .mix)
    }

    func testChoiceSurvivesWhenTheTrackIsThere() {
        XCTAssertEqual(AudioTrack.system.clamped(hasMic: true, hasSystem: true), .system)
        XCTAssertEqual(AudioTrack.mic.clamped(hasMic: true, hasSystem: true), .mic)
    }

    func testMixIsAlwaysValid() {
        for (mic, sys) in [(true, true), (true, false), (false, true), (false, false)] {
            XCTAssertEqual(AudioTrack.mix.clamped(hasMic: mic, hasSystem: sys), .mix)
        }
    }
}
