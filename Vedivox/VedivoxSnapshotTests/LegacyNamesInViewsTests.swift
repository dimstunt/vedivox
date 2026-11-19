import SwiftUI
import XCTest

/// The view layer's share of what the old name left behind: a palette choice
/// stored under its old name, and the links the app wrote into descriptions.
final class LegacyNamesInViewsTests: XCTestCase {

    func testAStoredPaletteChoiceIsReadUnderItsNewName() {
        XCTAssertEqual(VedivoxPalette(rawValue: "vox"), .mono)
        XCTAssertEqual(VedivoxPalette(rawValue: "dimstunt"), .ink)
        XCTAssertEqual(VedivoxPalette(rawValue: "mono"), .mono)
        XCTAssertEqual(VedivoxPalette(rawValue: "ink"), .ink)
        XCTAssertNil(VedivoxPalette(rawValue: "sepia"))
    }

    func testAPaletteChoiceIsWrittenUnderItsNewName() {
        XCTAssertEqual(VedivoxPalette.allCases.map(\.rawValue), ["mono", "ink"])
        XCTAssertEqual(VedivoxPalette.allCases.map(\.label), ["Mono", "Ink & Yellow"])
    }

    /// Descriptions written before the rename are in every library that came
    /// over; their timecodes and speaker mentions have to stay live.
    func testDescriptionsFromBeforeTheRenameKeepTheirLinks() {
        for (seek, speaker) in [("vediseek", "vedispeaker"), ("voxseek", "voxspeaker")] {
            let line = "Start [0:05](\(seek)://seek?t=5) with [the host](\(speaker)://S1)"

            let rendered = renderInline(line, hooks: .init(scheme: .light))

            XCTAssertEqual(String(rendered.characters), "Start 0:05 with the host", seek)
            XCTAssertEqual(
                rendered.runs.compactMap(\.link).map(\.absoluteString),
                ["vediseek://seek?t=5.0", "vedispeaker://S1"],
                "whatever the stored link says, the rendered one is in today's form"
            )
        }
    }
}
