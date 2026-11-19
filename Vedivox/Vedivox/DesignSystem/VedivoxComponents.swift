import SwiftUI

/// The one inline banner (design system: Banner). Warning tone for something
/// the user must fix, neutral for progress and information. `detail` sits
/// under the header row (the drift pair list); with `collapsed` the header
/// becomes a toggle for it and shows a chevron.
struct VedivoxBanner<Leading: View, Trailing: View, Detail: View>: View {
    enum Tone { case warning, neutral }

    let tone: Tone
    let title: String
    var message: String?
    var collapsed: Binding<Bool>?
    let leading: Leading
    let trailing: Trailing
    let detail: Detail

    init(
        _ tone: Tone,
        title: String,
        message: String? = nil,
        collapsed: Binding<Bool>? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder detail: () -> Detail = { EmptyView() }
    ) {
        self.tone = tone
        self.title = title
        self.message = message
        self.collapsed = collapsed
        self.leading = leading()
        self.trailing = trailing()
        self.detail = detail()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VedivoxSpace.m) {
            header
            if collapsed?.wrappedValue != true {
                detail
            }
        }
        .padding(VedivoxSpace.l)
        .background(tone == .warning ? Color.Vedivox.warningSoft : Color.Vedivox.bgCard, in: RoundedRectangle(cornerRadius: VedivoxRadius.m))
        .overlay(RoundedRectangle(cornerRadius: VedivoxRadius.m).strokeBorder(Color.Vedivox.line))
    }

    @ViewBuilder private var header: some View {
        let row = HStack(spacing: VedivoxSpace.l) {
            leading
                .foregroundStyle(tone == .warning ? Color.Vedivox.warning : Color.Vedivox.fgSecondary)
            VStack(alignment: .leading, spacing: VedivoxSpace.xxs) {
                Text(title)
                    .vedivoxFont(.bodyStrong)
                    .foregroundStyle(Color.Vedivox.fg)
                if let message {
                    Text(message)
                        .vedivoxFont(.caption)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            trailing
            if let collapsed {
                Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
            }
        }
        if let collapsed {
            row.contentShape(Rectangle()).onTapGesture { collapsed.wrappedValue.toggle() }
        } else {
            row
        }
    }
}

/// A capsule with a number (design system: CountBadge). Hidden at zero.
struct VedivoxCountBadge: View {
    let count: Int
    var warning = false

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .vedivoxFont(.timecode)
                .foregroundStyle(warning ? Color.Vedivox.fg : Color.Vedivox.fgSecondary)
                .padding(.horizontal, VedivoxSpace.s)
                .padding(.vertical, VedivoxSpace.xxs)
                .background(warning ? Color.Vedivox.warningSoft : Color.Vedivox.bgCard, in: Capsule())
        }
    }
}

/// The uppercase label above a group (design system: SectionHeader).
/// Pass the text in Title Case; the style uppercases it.
struct VedivoxSectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: VedivoxSpace.s) {
            Text(title)
                .vedivoxFont(.overline)
                .tracking(0.44) // 0.04em at 11pt
                .textCase(.uppercase)
                .foregroundStyle(Color.Vedivox.fgSecondary)
            if let count { VedivoxCountBadge(count: count) }
        }
    }
}

/// Selectable sidebar row (design system: SidebarRow): no fill, hover
/// `bgHover`, active `bgActive`. The label brings its own padding.
struct VedivoxRowButtonStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, active: active)
    }

    private struct RowBody: View {
        let configuration: Configuration
        let active: Bool
        @State private var hovering = false
        @Environment(\.vedivoxRowHovered) private var forcedHover

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: VedivoxRadius.s)
                        .fill(active ? Color.Vedivox.bgActive : (hovering || forcedHover ? Color.Vedivox.bgHover : Color.clear))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

extension EnvironmentValues {
    /// Draws `vedivoxRow` rows as if under the pointer: snapshots render offscreen, with no pointer to hover.
    @Entry var vedivoxRowHovered = false
}

extension ButtonStyle where Self == VedivoxRowButtonStyle {
    static func vedivoxRow(active: Bool) -> VedivoxRowButtonStyle { VedivoxRowButtonStyle(active: active) }
}

/// Single-line field (design system: TextField): `bgInput`, 1px `line`,
/// 2px `focus` ring while focused — never the system blue ring.
private struct VedivoxFieldModifier: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, VedivoxSpace.m)
            .padding(.vertical, 5)
            .background(Color.Vedivox.bgInput, in: RoundedRectangle(cornerRadius: VedivoxRadius.s))
            .overlay(
                RoundedRectangle(cornerRadius: VedivoxRadius.s)
                    .strokeBorder(focused ? Color.Vedivox.focus : Color.Vedivox.line, lineWidth: focused ? 2 : 1)
            )
    }
}

extension View {
    func vedivoxField() -> some View { modifier(VedivoxFieldModifier()) }

    /// Window ground in `bg` instead of the system material, which macOS
    /// tints with the wallpaper around the floating sidebar and under the
    /// toolbar. Before macOS 15 the window background is already opaque.
    @ViewBuilder func vedivoxWindowBackground(_ palette: VedivoxPalette) -> some View {
        if #available(macOS 15.0, *) {
            containerBackground(Color.Vedivox.bg(palette), for: .window)
        } else {
            self
        }
    }

    /// No system grey band under the toolbar: the content's own ground shows
    /// through. Hidden, not painted — a painted toolbar background covers the
    /// sidebar's top and cuts it off under the traffic lights.
    @ViewBuilder func vedivoxToolbarBackgroundHidden() -> some View {
        if #available(macOS 15.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}
