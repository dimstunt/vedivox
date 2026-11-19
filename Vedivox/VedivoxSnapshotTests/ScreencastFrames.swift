import AppKit
import SnapshotTesting
import SwiftUI
import XCTest

/// Frames for the screencast. Not a check: the offscreen screens of
/// `ScreenSnapshotTests`, drawn as sequences — live text arriving turn by turn,
/// the transcript with the playhead moving over a waveform, the dictation HUD
/// with its draft growing — and written as PNGs for `scripts/screencast`.
///
/// Runs only under `make screencast-frames`, which sets VEDIVOX_SCREENCAST_DIR;
/// `make test-snapshots` skips it. Same isolation as the references: no app
/// process, no window on screen, a throwaway data directory.
extension ScreenSnapshotTests {

    /// How many playhead positions the transcript is drawn at, start to end.
    private static let transcriptFrames = 120

    func testScreencastFrames() async throws {
        guard let out = ProcessInfo.processInfo.environment["VEDIVOX_SCREENCAST_DIR"], !out.isEmpty else {
            throw XCTSkip("VEDIVOX_SCREENCAST_DIR is not set — run via make screencast-frames")
        }
        _ = try await Self.state()
        for dark in [true, false] {
            try await liveFrames(to: out, dark: dark)
            try await transcriptFrames(to: out, dark: dark)
        }
        try hudFrames(to: out)
    }

    /// Quick text comes labelled by track ("Others"); the precise pass then
    /// names the voices it knows. Step 5 is the `live-transcript` reference.
    private func liveFrames(to out: String, dark: Bool) async throws {
        func turn(_ start: Double, _ speaker: LiveSpeaker, _ text: String, mic: Bool = false) -> LiveTranscriptLog.Turn {
            .init(track: mic ? .mic : .system, speaker: speaker, start: start, end: start + 6, text: text)
        }
        let question = "Can we still ship on Thursday if the review slips a day?"
        let doubt = "Depends on the migration. It has to finish first, and nobody has looked at the row counts since Monday."
        let answer = turn(78, .me, "The migration is done, I compared the counts this morning.", mic: true)
        let clara = LiveSpeaker(kind: .known, name: "Clara Meyer", confidence: 0.84)
        let second = LiveSpeaker(kind: .unknown, name: "Speaker 2")
        let steps: [[LiveTranscriptLog.Turn]] = [
            [],
            [turn(61, .others, question)],
            [turn(61, .others, question), turn(69, .others, doubt)],
            [turn(61, .others, question), turn(69, .others, doubt), answer],
            [turn(61, clara, question), turn(69, second, doubt), answer],
            [turn(61, clara, question), turn(69, second, doubt), answer, turn(84, .others, "Okay.")],
        ]
        let model = LiveTranscriptScreenModel()
        model.show([])
        try await render(size: CGSize(width: 760, height: 320), palette: .ink, dark: dark, {
            (LiveTranscriptContent(model: model), { () async in })
        }, use: { view in
            for (index, turns) in steps.enumerated() {
                model.show(turns)
                try await settle(400)
                save(view, to: out, "live_\(dark ? "dark" : "light")_\(index)")
            }
        })
    }

    /// The meeting screen with every line and the playhead walking through
    /// it, then one frame with a search. The fixture has no audio, so the
    /// waveform is synthetic.
    private func transcriptFrames(to out: String, dark: Bool) async throws {
        let theme = dark ? "dark" : "light"
        let viewModel = MeetingDetailViewModel()
        try await render(size: CGSize(width: 1180, height: 640), palette: .ink, dark: dark, {
            (TranscriptHarness(viewModel: viewModel, editMode: false), { () async in
                let length = viewModel.segments.map(\.endTime).max() ?? 0
                viewModel.meeting?.durationSeconds = length
                viewModel.waveformPeaks = Self.speechLikePeaks(viewModel.segments, length: length)
            })
        }, use: { view in
            let length = viewModel.segments.map(\.endTime).max() ?? 0
            for index in 0 ..< Self.transcriptFrames {
                viewModel.playback.currentTime = length * Double(index) / Double(Self.transcriptFrames)
                try await settle(120)
                save(view, to: out, "hero_\(theme)_\(String(format: "%03d", index))")
            }
            viewModel.playback.currentTime = viewModel.segments.dropFirst().first?.startTime ?? 0
            viewModel.searchText = "Thursday"
            try await settle(400)
            save(view, to: out, "hero_\(theme)_search")
        })
    }

    /// Speech-like bars tinted by speaker: a syllable ripple plus a fixed
    /// pseudo-random jitter, quiet around each change of speaker; the
    /// speaker's own track is loud, the other one quiet.
    static func speechLikePeaks(_ segments: [TranscriptSegment], length: Double) -> WaveformPeaks {
        let bins = WaveformPeaksService.defaultBinCount
        func level(_ bin: Int, mic: Bool) -> Float {
            let time = (Double(bin) + 0.5) / Double(bins) * length
            guard let line = segments.first(where: { $0.startTime <= time && time < $0.endTime }) else { return 0.05 }
            let edge = min(time - line.startTime, line.endTime - time)
            let jitter = abs(sin(Double(bin) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
            let speech = edge < 0.5 ? 0.08 : 0.3 + 0.45 * abs(sin(time * 2.3)) + 0.25 * jitter
            return Float((line.source == .mic) == mic ? speech : speech * 0.15)
        }
        return WaveformPeaks(
            binCount: bins, duration: length, micLength: 0, systemLength: 0,
            mic: (0 ..< bins).map { level($0, mic: true) }, system: (0 ..< bins).map { level($0, mic: false) }
        )
    }

    /// The HUD sized by its content, as `DictationHUDController` shows it,
    /// one frame per word of an English draft.
    private func hudFrames(to out: String) throws {
        Self.setForThisProcess([VedivoxPalette.defaultsKey: VedivoxPalette.ink.rawValue, "voxTheme": VedivoxTheme.dark.rawValue])
        let words = "Thursday works for us. The migration is done, I checked the row counts this morning."
            .split(separator: " ")
        for count in 0 ... words.count {
            let model = DictationHUDModel()
            model.elapsed = 1 + Double(count) * 0.3
            model.level = Float(0.35 + 0.45 * abs(sin(Double(count) * 1.7)))
            model.draft = words.prefix(count).joined(separator: " ")
            let hosting = NSHostingView(rootView: DictationHUDView(model: model))
            hosting.appearance = NSAppearance(named: .darkAqua)
            hosting.sizingOptions = [.intrinsicContentSize]
            hosting.layoutSubtreeIfNeeded()
            hosting.frame = NSRect(origin: .zero, size: hosting.intrinsicContentSize)
            save(hosting, to: out, "hud_\(String(format: "%02d", count))")
            Self.rendered.append(hosting)
        }
    }

    /// Written through the library, so a frame is the same bitmap a reference is.
    private func save(_ view: NSView, to directory: String, _ name: String) {
        withSnapshotTesting(record: .all) {
            _ = verifySnapshot(of: view, as: .image, named: name, snapshotDirectory: directory, testName: "frame")
        }
    }
}
