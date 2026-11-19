import SwiftUI

// Text roles, one per type style in the design system (SF Pro / SF Mono).
// Every text takes one of these; SwiftUI text styles and `.system(size:)` are
// not used. `overline` is the font only — SectionHeader adds uppercase and
// tracking, since a `.textCase` set here would override an outer one.
enum VedivoxFont {
    case header
    case title
    case transcript
    case body
    case bodyStrong
    case row
    case label
    case caption
    case overline
    case timecode
    case tabular

    var swiftUIFont: Font {
        switch self {
        case .header: .system(size: 22, weight: .semibold)
        case .title: .system(size: 17, weight: .semibold)
        case .transcript: .system(size: 14, weight: .regular)
        case .body: .system(size: 13, weight: .regular)
        case .bodyStrong: .system(size: 13, weight: .semibold)
        case .row: .system(size: 12, weight: .regular)
        case .label: .system(size: 12, weight: .medium)
        case .caption: .system(size: 11, weight: .regular)
        case .overline: .system(size: 11, weight: .semibold)
        case .timecode: .system(size: 11, design: .monospaced).monospacedDigit()
        case .tabular: .system(size: 13, design: .monospaced).monospacedDigit()
        }
    }
}

extension View {
    func vedivoxFont(_ role: VedivoxFont) -> some View {
        self.font(role.swiftUIFont)
    }
}
