import AppKit
import SwiftUI

enum VedivoxTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The one place the theme is applied: windows, popovers and AppKit
    /// menus all inherit NSApp.appearance, and `nil` (System) follows macOS.
    /// SwiftUI's .preferredColorScheme is not used — it forced only the window,
    /// so context menus resolved against the system appearance (white on
    /// white), and set back to nil it never released the window.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Apply to the whole app; call at launch and on theme change.
    func applyToApp() {
        NSApp.appearance = nsAppearance
    }
}

/// Which palette `Color.Vedivox` resolves against: Settings → General → Palette
/// The tokens' dynamic providers read the stored setting on
/// every resolve; `UserDefaults` is thread-safe, and the write lands before
/// the window rebuilds on it.
enum VedivoxPalette: RawRepresentable, CaseIterable, Identifiable, Sendable {
    /// `ink` is the stored key of Ink & Yellow.
    case mono, ink

    static let defaultsKey = "voxPalette"

    var rawValue: String {
        switch self {
        case .mono: "mono"
        case .ink: "ink"
        }
    }

    /// A choice stored before the palettes got these names reads as the same
    /// palette; the next change writes it under the new one.
    init?(rawValue: String) {
        switch LegacyNames.paletteRawValues[rawValue] ?? rawValue {
        case "mono": self = .mono
        case "ink": self = .ink
        default: return nil
        }
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mono: "Mono"
        case .ink: "Ink & Yellow"
        }
    }

    static var current: VedivoxPalette {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(VedivoxPalette.init(rawValue:)) ?? .mono
    }
}
