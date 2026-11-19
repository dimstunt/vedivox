import FluidAudio
import XCTest

/// «Дорожка звучала, транскрипта нет» (audio-integrity) — and the sound that is
/// not a loss because it was never speech.
final class LostTrackTests: XCTestCase {

    private let loud = AudioConverter.TrackStats(duration: 37, rmsDBFS: -32)
    private let quiet = AudioConverter.TrackStats(duration: 37, rmsDBFS: -55)

    /// Music during a recording (2026-09-28: −32 dBFS, the diarizer found no
    /// speech): the empty transcript is the honest result.
    func testSoundWithoutSpeech_isNotALostTrack() {
        XCTAssertNil(TranscriptionPipeline.lostTrack("system", stats: loud, texts: [], noSpeech: true))
    }

    /// Speech the recognizer returned nothing for is still a loss.
    func testSpeechWithoutTranscript_isALostTrack() {
        XCTAssertEqual(TranscriptionPipeline.lostTrack("system", stats: loud, texts: ["  "], noSpeech: false), "system")
        XCTAssertEqual(TranscriptionPipeline.lostTrack("mic", stats: loud, texts: []), "mic", "без вердикта — по энергии, как раньше")
    }

    func testTranscribedOrSilentTrack_isNotLost() {
        XCTAssertNil(TranscriptionPipeline.lostTrack("system", stats: loud, texts: ["hello"]))
        XCTAssertNil(TranscriptionPipeline.lostTrack("system", stats: quiet, texts: []))
    }

    /// Only the diarizer's own «no speech» is a verdict; any other failure of
    /// the diarizer says nothing about the track.
    func testOnlyNoSpeechDetectedIsAVerdict() {
        XCTAssertTrue(TranscriptionPipeline.isNoSpeech(OfflineDiarizationError.noSpeechDetected))
        XCTAssertFalse(TranscriptionPipeline.isNoSpeech(OfflineDiarizationError.processingFailed("model")))
        XCTAssertFalse(TranscriptionPipeline.isNoSpeech(CancellationError()))
    }

    /// Music on the call track (live check 2026-11-16: 5 s of Spotify, a 32 s
    /// Teams call): the diarizer's «no speech» is the verdict, not a failure,
    /// and the meeting must not need attention for it.
    func testDiarizerFindingNoSpeech_isNotADiarizationLoss() {
        XCTAssertNil(TranscriptionPipeline.diarizationLoss(OfflineDiarizationError.noSpeechDetected, stats: loud))
    }

    func testDiarizerFailingOnSoundedTrack_isALoss() {
        XCTAssertEqual(
            TranscriptionPipeline.diarizationLoss(OfflineDiarizationError.processingFailed("model"), stats: loud),
            "system diarization"
        )
        XCTAssertNil(TranscriptionPipeline.diarizationLoss(OfflineDiarizationError.processingFailed("model"), stats: quiet))
    }
}
