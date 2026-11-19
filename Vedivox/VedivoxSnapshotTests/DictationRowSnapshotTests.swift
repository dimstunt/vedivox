import AppKit
import SnapshotTesting
import SwiftUI
import XCTest

/// Renders history entries at the states that differ visually
///
/// The interesting cases are exactly the ones a real history takes days to
/// produce: an entry whose insertion failed, and an old entry whose audio
/// retention has already removed — the latter shows one fewer action, and
/// getting that wrong means offering re-transcription for audio that is gone.
///
/// Lives in the unhosted VedivoxSnapshotTests (moved from VedivoxTests): the
/// row prints its date through TimeZone.current and Locale.current, so zone,
/// locale, palette and theme are pinned here, the same way as ScreenSnapshotTests,
/// and `make test-snapshots` checks it without the app as a test host.
@MainActor
final class DictationRowSnapshotTests: XCTestCase {

    private static var rendered: [NSView] = []

    override func invokeTest() {
        let record = ProcessInfo.processInfo.environment["VEDIVOX_SNAPSHOT_RECORD"] == "1"
        withSnapshotTesting(record: record ? .all : .missing) { super.invokeTest() }
    }

    override func setUp() {
        super.setUp()
        // Same pin as ScreenSnapshotTests.state(): UTC−3 without DST, US English
        // with Portugal's formats (24 h). The argument domain is this process's
        // alone and outranks the xctest tool's shared defaults; palette and theme
        // too, since ScreenSnapshotTests leaves the last palette it drew there.
        setenv("TZ", "America/Montevideo", 1)
        tzset()
        NSTimeZone.resetSystemTimeZone()
        let defaults = UserDefaults.standard
        let domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain).merging([
            "AppleLocale": "en_US@rg=ptzzzz", "AppleLanguages": ["en"],
            VedivoxPalette.defaultsKey: VedivoxPalette.mono.rawValue, "voxTheme": VedivoxTheme.light.rawValue,
        ]) { $1 }
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    func testInsertedEntry() {
        snapshot(makeDictation(), named: "inserted")
    }

    /// Failed insertion is the case the badge exists for — the text is only in
    /// the clipboard and the history.
    func testNotInsertedEntry() {
        snapshot(makeDictation(targetApp: nil, inserted: false), named: "not-inserted")
    }

    /// No audio: the re-transcribe action must be absent rather than disabled.
    func testEntryWithoutAudio() {
        snapshot(makeDictation(audioFileName: nil), named: "no-audio")
    }

    /// Cut short by a quit: says why there is no text, and offers re-transcription.
    func testAwaitingTranscriptionEntry() {
        snapshot(makeDictation(text: "", targetApp: nil, inserted: false, awaitingTranscription: true), named: "awaiting")
    }

    func testLongText() {
        let long = String(repeating: "Проверяем, как выглядит длинная запись в истории. ", count: 6)
        snapshot(makeDictation(text: long), named: "long-text")
    }

    // MARK: - Helpers

    private func makeDictation(
        text: String = "Проверка истории диктовок",
        targetApp: String? = "Terminal",
        inserted: Bool = true,
        audioFileName: String? = "sample.wav",
        awaitingTranscription: Bool = false
    ) -> Dictation {
        Dictation(
            id: "sample",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            text: text,
            durationSeconds: 12,
            targetApp: targetApp,
            inserted: inserted,
            audioFileName: audioFileName,
            awaitingTranscription: awaitingTranscription
        )
    }

    private func snapshot(
        _ dictation: Dictation, named name: String,
        file: StaticString = #filePath, testName: String = #function, line: UInt = #line
    ) {
        let appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: DictationRow(dictation: dictation)
            .environment(\.colorScheme, .light)
            .frame(width: 520))
        hosting.appearance = appearance
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.layoutSubtreeIfNeeded()
        hosting.frame = NSRect(origin: .zero, size: hosting.intrinsicContentSize)
        // Never ordered in: a window only so the row lays out as in the app.
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.appearance = appearance
        window.contentView = hosting
        let directory = ProcessInfo.processInfo.environment["VEDIVOX_SNAPSHOT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        if let failure = verifySnapshot(
            of: hosting, as: .image(precision: 0.995), named: name,
            snapshotDirectory: directory, file: file, testName: testName, line: line
        ) {
            XCTFail(failure, file: file, line: line)
        }
        Self.rendered.append(hosting)
        window.contentView = nil
    }
}
