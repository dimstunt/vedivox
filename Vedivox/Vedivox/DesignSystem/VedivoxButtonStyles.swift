import SwiftUI

/// Ghost button from the design bundle (`.vedivox-btn--ghost`): card background,
/// thin border, foreground text; hover lightens the card.
struct VedivoxGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostBody(configuration: configuration)
    }

    private struct GhostBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .vedivoxFont(.label)
                .foregroundStyle(Color.Vedivox.fg)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    hovering || configuration.isPressed ? Color.Vedivox.bgCardHover : Color.Vedivox.bgCard,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.Vedivox.line))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .opacity(configuration.isPressed ? 0.85 : 1)
        }
    }
}

extension ButtonStyle where Self == VedivoxGhostButtonStyle {
    static var vedivoxGhost: VedivoxGhostButtonStyle { VedivoxGhostButtonStyle() }
}

/// Primary button from the design bundle (`.vedivox-btn--primary`): monochrome
/// accent background with inverted label. Replaces `.borderedProminent`,
/// which paints the macOS system accent.
struct VedivoxProminentButtonStyle: ButtonStyle {
    var fill = Color.Vedivox.accent
    var label = Color.Vedivox.accentFg

    func makeBody(configuration: Configuration) -> some View {
        ProminentBody(configuration: configuration, fill: fill, labelColor: label)
    }

    private struct ProminentBody: View {
        let configuration: Configuration
        let fill: Color
        let labelColor: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .vedivoxFont(.label)
                .foregroundStyle(labelColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(fill, in: RoundedRectangle(cornerRadius: VedivoxRadius.s))
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.8 : (isEnabled ? 1 : 0.4))
        }
    }
}

extension ButtonStyle where Self == VedivoxProminentButtonStyle {
    static var vedivoxProminent: VedivoxProminentButtonStyle { VedivoxProminentButtonStyle() }
    /// Stop in the sidebar recording block only: solid red means a recording
    /// is live. Start is `.vedivoxProminent` with a red mark.
    static var vedivoxRecord: VedivoxProminentButtonStyle {
        VedivoxProminentButtonStyle(fill: Color.Vedivox.recording, label: Color.Vedivox.onRecording)
    }
}

/// Icon-only button: SF Symbol in `fgSecondary` inside a 20×20 hit box.
/// Replaces `.borderless`.
struct VedivoxIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.Vedivox.fgSecondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == VedivoxIconButtonStyle {
    static var vedivoxIcon: VedivoxIconButtonStyle { VedivoxIconButtonStyle() }
}

/// One capsule floating over content: the transcript's Follow pill.
struct VedivoxFloatingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .vedivoxFont(.label)
            .foregroundStyle(Color.Vedivox.accentFg)
            .padding(.horizontal, VedivoxSpace.l)
            .padding(.vertical, VedivoxSpace.m)
            .background(
                Capsule()
                    .fill(Color.Vedivox.accent)
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 2) // shadow-float
            )
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

extension ButtonStyle where Self == VedivoxFloatingButtonStyle {
    static var vedivoxFloating: VedivoxFloatingButtonStyle { VedivoxFloatingButtonStyle() }
}

/// A round icon button floating over a list: the sidebar's Reveal in Sidebar.
/// Quiet next to `vedivoxFloating` — it is always there while a meeting is open.
struct VedivoxFloatingIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.Vedivox.fgSecondary)
            .frame(width: 28, height: 28)
            .background(
                Circle()
                    .fill(Color.Vedivox.bgCard)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 1) // shadow-float, softer
            )
            .overlay(Circle().strokeBorder(Color.Vedivox.lineSoft))
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == VedivoxFloatingIconButtonStyle {
    static var vedivoxFloatingIcon: VedivoxFloatingIconButtonStyle { VedivoxFloatingIconButtonStyle() }
}

/// Link button from the design bundle (`background: none; color: var(--accent)`).
/// Exists because macOS's `.buttonStyle(.link)` paints `NSColor.linkColor`
/// (system blue) and ignores the environment tint.
struct VedivoxLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkBody(configuration: configuration)
    }

    private struct LinkBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? Color.Vedivox.fg : Color.Vedivox.accentText)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}

extension ButtonStyle where Self == VedivoxLinkButtonStyle {
    static var vedivoxLink: VedivoxLinkButtonStyle { VedivoxLinkButtonStyle() }
}
