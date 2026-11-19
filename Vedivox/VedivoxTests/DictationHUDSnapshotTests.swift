import AppKit
import SnapshotTesting
import SwiftUI
import XCTest
@testable import Vedivox

/// Renders the dictation HUD at fixed states and diffs it against recorded
/// images.
///
/// Every layout bug in this panel so far was found by a human squinting at a
/// screenshot: a label truncated to «Зап…», a second line clipped mid-glyph,
/// the panel drifting sideways as text arrived. All three are visible in a
/// rendered image and invisible to every other kind of test — the panel is
/// non-activating and ignores the mouse, so XCUITest cannot reach it either.
///
/// Lives in VedivoxTests because it is the only target that compiles `Views`.
///
/// Recording new references: set `isRecording = false` below, run once, set it
/// back. References live next to this file in `__Snapshots__`.
@MainActor
final class DictationHUDSnapshotTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Flip to true to re-record every reference in this file.
        isRecording = false
    }

    /// The state the HUD spends most of its life in — before the model has
    /// produced anything, which at 2240 ms chunks is the first few seconds of
    /// every dictation.
    func testRecordingWithoutDraft() {
        assertSnapshot(of: panel(elapsed: 5, level: 0.6), as: .image, named: "recording-no-draft")
    }

    func testSilenceFlattensTheBars() {
        assertSnapshot(of: panel(elapsed: 12, level: 0), as: .image, named: "silence")
    }

    /// One line of draft: the panel has to grow downwards without clipping.
    func testShortDraft() {
        assertSnapshot(
            of: panel(elapsed: 8, level: 0.5, draft: "Так, ну вот я запустил"),
            as: .image,
            named: "draft-one-line"
        )
    }

    /// Two lines were clipped mid-glyph once because the panel followed content
    /// width but not height. This is that bug, frozen.
    func testTwoLineDraftIsNotClipped() {
        assertSnapshot(
            of: panel(
                elapsed: 18,
                level: 0.7,
                draft: "Так, ну вот я запустил, во-первых пошло работать, и выглядит это вполне прилично"
            ),
            as: .image,
            named: "draft-two-lines"
        )
    }

    /// Long drafts show the tail — the words being said right now — with the
    /// head truncated.
    func testLongDraftShowsTheTail() {
        let long = String(repeating: "распознанный текст ", count: 40)
        assertSnapshot(of: panel(elapsed: 95, level: 0.4, draft: long), as: .image, named: "draft-long")
    }

    /// Model still loading: the HUD is the only surface that reaches a user
    /// whose Vedivox window is closed, so this message has to be legible.
    func testModelLoadingStatus() {
        assertSnapshot(
            of: panel(elapsed: 3, level: 0.5, status: "Loading live-text model… 42%"),
            as: .image,
            named: "status-loading"
        )
    }

    /// No Accessibility permission: Escape is not captured, and the user hears
    /// about it here because the Vedivox window is closed.
    func testEscapeWarning() {
        assertSnapshot(
            of: panel(
                elapsed: 2,
                level: 0.5,
                warning: "Escape also reaches the app — allow Vedivox in Accessibility"
            ),
            as: .image,
            named: "warning-escape"
        )
    }

    /// Past the hour the clock gains a component and the row gets wider — the
    /// panel must accommodate it rather than truncate.
    func testClockPastAnHour() {
        assertSnapshot(of: panel(elapsed: 3675, level: 0.5), as: .image, named: "clock-hour")
    }

    // MARK: - Helper

    /// Renders the panel exactly as `DictationHUDController` does: content-driven
    /// size via `intrinsicContentSize`, no imposed frame.
    private func panel(
        elapsed: TimeInterval,
        level: Float,
        draft: String = "",
        status: String? = nil,
        warning: String? = nil
    ) -> NSView {
        let model = DictationHUDModel()
        model.elapsed = elapsed
        model.level = level
        model.draft = draft
        model.status = status
        model.warning = warning

        let hosting = NSHostingView(rootView: DictationHUDView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.layoutSubtreeIfNeeded()
        hosting.frame = NSRect(origin: .zero, size: hosting.intrinsicContentSize)
        return hosting
    }
}
