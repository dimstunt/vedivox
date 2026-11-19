import AppKit
import SwiftUI

extension Color {
    /// A token with a value per palette (Settings → General → Palette) and per
    /// appearance. The palette is read on every resolve, so a palette switch
    /// needs only a redraw.
    init(mono: (light: Color, dark: Color), ink: (light: Color, dark: Color)) {
        self.init(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            NSColor(shade(VedivoxPalette.current == .mono ? mono : ink, for: appearance))
        }))
    }

    /// One palette's shades, dynamic over appearance only. A new value per
    /// call, so SwiftUI sees a palette switch as a change.
    init(pinned shades: (light: Color, dark: Color)) {
        self.init(nsColor: NSColor(name: nil, dynamicProvider: { NSColor(shade(shades, for: $0)) }))
    }
}

private func shade(_ shades: (light: Color, dark: Color), for appearance: NSAppearance) -> Color {
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? shades.dark : shades.light
}

private func hex(_ value: UInt32) -> Color {
    Color(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
}

/// An OKLCH colour, converted with the same tested math as speaker colours.
private func oklch(_ l: Double, _ c: Double, _ h: Double) -> Color {
    let rgb = SpeakerHueMath.srgb(l: l, c: c, h: h)
    return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
}

// Names mirror the design system's tokens.json one to one (`bg-sidebar` ↔
// `bgSidebar`).
// Two palettes, both with a muted light and a dark theme:
// Mono — the original monochrome — and Ink — the ink and yellow of dimstunt.de.
extension Color {
    enum Vedivox {
        // dimstunt.de, in OKLCH as the site's CSS writes them, toned down for an app you read in for an hour:
        // the dark ground is a step lighter than the site's ink (0.19, not 0.16), the yellow calmer than its 0.92 / 0.19.
        private static let ink = oklch(0.16, 0.012, 265)
        private static let paper = oklch(0.96, 0.025, 103)
        private static let yellowLight = oklch(0.83, 0.16, 95)
        private static let yellowDark = oklch(0.84, 0.15, 100)
        private static let cyan = oklch(0.8, 0.11, 200)

        private static let bgShades: (mono: (light: Color, dark: Color), ink: (light: Color, dark: Color)) =
            (mono: (hex(0xe9e8e3), hex(0x0e0e10)), ink: (oklch(0.92, 0.02, 103), oklch(0.19, 0.012, 265)))
        static let bg = Color(mono: bgShades.mono, ink: bgShades.ink)
        /// `bg` fixed to one palette, for the window ground: SwiftUI keeps the
        /// `.window` container background it resolved and never re-reads the
        /// stored palette, so the meeting, Listen and Dictation screens — which
        /// show the window ground — stayed in the old palette.
        static func bg(_ palette: VedivoxPalette) -> Color { Color(pinned: palette == .mono ? bgShades.mono : bgShades.ink) }
        static let bgSidebar = Color(mono: (hex(0xdad9d2), hex(0x171719)), ink: (oklch(0.87, 0.024, 103), oklch(0.215, 0.014, 265)))
        static let bgCard = Color(mono: (hex(0xf1f0ec), hex(0x1c1c20)), ink: (oklch(0.945, 0.015, 103), oklch(0.235, 0.016, 265)))
        static let bgCardHover = Color(mono: (hex(0xe6e5e0), hex(0x222227)), ink: (oklch(0.93, 0.018, 103), oklch(0.26, 0.016, 265)))
        static let bgHover = Color(mono: (hex(0xd2d1ca), hex(0x1a1a1d)), ink: (oklch(0.85, 0.026, 103), oklch(0.255, 0.016, 265)))
        /// Darker than `bgHover` by a step you can see: at 1.07–1.15:1 a hovered row next to the
        /// active one read as a second active row.
        static let bgActive = Color(mono: (hex(0xc0bfb8), hex(0x303036)), ink: (oklch(0.79, 0.032, 103), oklch(0.33, 0.02, 265)))
        static let bgInput = bgCard

        static let line = Color(mono: (hex(0xbdbcb5), hex(0x2a2a30)), ink: (oklch(0.74, 0.025, 103), oklch(0.38, 0.02, 250)))
        static let lineSoft = Color(mono: (hex(0xd4d3cc), hex(0x222227)), ink: (oklch(0.84, 0.025, 103), oklch(0.28, 0.016, 265)))

        /// Two text greys only: a third, lighter one failed 4.5:1 and a
        /// passing one equals `fgSecondary`. Rank metadata by size instead.
        static let fg = Color(mono: (hex(0x262624), hex(0xecece8)), ink: (oklch(0.22, 0.012, 265), oklch(0.88, 0.02, 103)))
        static let fgSecondary = Color(mono: (hex(0x4f4e48), hex(0x9b9b96)), ink: (oklch(0.4, 0.02, 265), oklch(0.7, 0.025, 103)))
        /// Never readable text: disabled glyphs, placeholders, inactive marks.
        static let fgQuaternary = Color(mono: (hex(0xa3a29b), hex(0x46464a)), ink: (oklch(0.66, 0.02, 103), oklch(0.42, 0.02, 265)))

        /// The action fill: buttons, play, the active track segment, capsules.
        static let accent = Color(mono: (hex(0x2a2a2c), hex(0xf5f5f0)), ink: (yellowLight, yellowDark))
        /// Label and glyph on an `accent` fill.
        static let accentFg = Color(mono: (hex(0xefeee9), hex(0x1a1a1c)), ink: (ink, ink))
        /// The action colour as text or a mark on a ground — links, checked
        /// boxes, the active chunk. Not `accent`: the yellow fill is unreadable
        /// as text on the light ground.
        static let accentText = Color(mono: (hex(0x2a2a2c), hex(0xf5f5f0)), ink: (oklch(0.42, 0.09, 85), yellowDark))
        /// Fill of multi-selected segments and selected text.
        static let selection = Color(mono: (hex(0x1a1a1c).opacity(0.12), hex(0xf5f5f0).opacity(0.14)),
                                     ink: (yellowLight.opacity(0.4), yellowDark.opacity(0.16)))
        /// Ring around a selected segment. Solid: `selection` alone is too close
        /// to `bgActive` to tell selected from the segment under the playhead.
        static let selectionLine = Color(mono: (hex(0x2a2a2c), hex(0xf5f5f0)), ink: (ink, cyan))
        /// Keyboard focus ring on fields.
        static let focus = Color(mono: (hex(0x2a2a2c), hex(0xf5f5f0)), ink: (oklch(0.5, 0.14, 220), cyan))

        static let danger = Color(mono: (hex(0xa82a2a), hex(0xef5b5b)), ink: (oklch(0.48, 0.21, 25), oklch(0.66, 0.21, 25)))
        static let dangerSoft = danger.opacity(0.18)
        static let warning = Color(mono: (hex(0xa84c1e), hex(0xe2a64f)), ink: (oklch(0.53, 0.15, 60), oklch(0.8, 0.13, 75)))
        static let warningSoft = warning.opacity(0.12)
        /// Search-match background behind `fg` text. dimstunt.de dark is 32%: at
        /// 38% `fg` fell to 3.9:1 on the segment under the playhead (`bgActive`).
        static let highlight = Color(mono: (hex(0xc05621).opacity(0.32), hex(0xe2a64f).opacity(0.35)),
                                     ink: (yellowLight.opacity(0.6), yellowDark.opacity(0.32)))
        static let success = Color(mono: (hex(0x2b7550), hex(0x6ec28f)), ink: (oklch(0.5, 0.15, 140), oklch(0.82, 0.18, 135)))
        /// Live capture only. Same value as `danger`, different meaning.
        static let recording = danger
        /// Label on a `recording` fill.
        static let onRecording = Color(mono: (hex(0xffffff), hex(0x1a1a1c)), ink: (paper, ink))
        /// The red record mark on an `accent` fill (Start Recording), 3:1 or more
        /// on that fill in every theme; `recording` itself is not on the yellow.
        static let recordingMark = Color(mono: (hex(0xe06060), hex(0xd64545)), ink: (oklch(0.48, 0.21, 25), oklch(0.52, 0.2, 25)))
        static let scrim = Color.black.opacity(0.45)
    }

    // Per-speaker color from the persistent hue (0..<360), in OKLCH so every
    // hue reads at the same lightness: oklch(0.37 0.14 h) light — darker than
    // the bundle's 0.50, which fell under 4.5:1 on the muted grounds, and than
    // 0.40, which fell under it on the darker `bgActive` — and
    // oklch(0.80 0.11 h) dark. The same in both palettes.
    static func speaker(hue: Double, scheme: ColorScheme) -> Color {
        scheme == .dark ? oklch(0.80, 0.11, hue) : oklch(0.37, 0.14, hue)
    }

    // Avatar / chip tint: oklch(0.95 0.04 h) light, oklch(0.30 0.06 h / 0.35) dark.
    static func speakerBg(hue: Double, scheme: ColorScheme) -> Color {
        scheme == .dark ? oklch(0.30, 0.06, hue).opacity(0.35) : oklch(0.95, 0.04, hue)
    }

    /// Transcript speaker-name color. UNKNOWN is not a persona — it renders
    /// muted instead of a stable hue (the djb2 fallback lands "UNKNOWN" on
    /// red, which reads as an alarm).
    static func speakerLabel(_ label: String?, key: String, scheme: ColorScheme) -> Color {
        if label == "UNKNOWN" { return Color.Vedivox.fgSecondary }
        return speaker(hue: SpeakerHue.for(key), scheme: scheme)
    }
}
