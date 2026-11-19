import Foundation
import XCTest

/// Views take colour only from the design system's tokens (`Color.Vedivox.*`,
///). A system grey or a literal colour in a view ignores the palette
/// and the theme: it looks right in the one combination it was written in and
/// wrong in the other three. Scans the sources, so it runs in the headless
/// `make test` gate without compiling a single view.
final class DesignSystemLiteralTests: XCTestCase {

    private static let named = "red|green|blue|yellow|orange|purple|pink|gray|grey|black|white|brown|cyan|mint|teal|indigo"

    /// What a view may not contain, with why, matched per line outside comments.
    private static let forbidden: [(pattern: String, reason: String)] = [
        (#"\.(primary|secondary|tertiary|quaternary)\b"#, "system grey — use Color.Vedivox.fg / fgSecondary"),
        (#"\b(Color|NSColor)\.(\#(named))\b"#, "named colour — use a Color.Vedivox token"),
        (#"[ (:?,\[]\.(\#(named))\b"#, "named colour shorthand — use a Color.Vedivox token"),
        (#"\bColor\((red|white|hue|hex):"#, "colour literal — add a token to Color+Vedivox.swift"),
        (#"\bNSColor\((red|white|calibratedRed|srgbRed|deviceRed|calibratedWhite):"#, "colour literal — add a token to Color+Vedivox.swift"),
        (#"\bNSColor\.(system[A-Z]\w*|controlAccentColor|labelColor|secondaryLabelColor)"#, "AppKit system colour — use a Color.Vedivox token"),
    ]

    func testViewsUseOnlyDesignSystemColours() throws {
        // Bundled as a folder resource (project.yml): the sources themselves sit
        // in ~/Documents, which the test process cannot read under `git commit`.
        let views = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Views", withExtension: nil))
        let files = try XCTUnwrap(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no sources under \(views.path)")

        let rules = try Self.forbidden.map { (try NSRegularExpression(pattern: $0.pattern), $0.reason) }
        var hits: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (number, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                let range = NSRange(code.startIndex..., in: code)
                for (rule, reason) in rules where rule.firstMatch(in: code, range: range) != nil {
                    hits.append("\(file.lastPathComponent):\(number + 1): \(reason): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(hits.isEmpty, "Views must take colour from Color.Vedivox tokens:\n" + hits.joined(separator: "\n"))
    }

    /// The theme is applied only through NSApp.appearance (`VedivoxTheme.applyToApp`).
    /// `.preferredColorScheme` forces its window and, set back to nil for
    /// System, never releases it: Light → System stayed light. VedivoxApp.swift is
    /// not scanned (a lone .swift file is not copied as a test resource);
    /// there the removed `VedivoxTheme.preferredColorScheme` guards it.
    func testThemeNotForcedThroughPreferredColorScheme() throws {
        let views = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Views", withExtension: nil))
        let files = try XCTUnwrap(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        let hits = try files.filter { file in
            try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                .contains { ($0.components(separatedBy: "//").first ?? $0).contains(".preferredColorScheme(") }
        }
        XCTAssertTrue(hits.isEmpty, ".preferredColorScheme in: \(hits.map(\.lastPathComponent))")
    }
}
