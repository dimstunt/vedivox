import SwiftUI

struct SidebarNav: View {
    @Binding var selection: AppState.SidebarView
    var listenCount: Int?
    var seriesCount: Int?
    var dictationCount: Int?

    var body: some View {
        VStack(spacing: VedivoxSpace.xxs) {
            NavItem(icon: "list.bullet", label: "All Meetings",
                    active: selection == .meetings,
                    action: { selection = .meetings })
            NavItem(icon: "person.2", label: "Speakers",
                    active: selection == .speakers,
                    action: { selection = .speakers })
            NavItem(icon: "ear", label: "Listen", count: listenCount,
                    active: selection == .listen,
                    action: { selection = .listen })
            NavItem(icon: "link", label: "Series", count: seriesCount,
                    active: selection == .series,
                    action: { selection = .series })
            NavItem(icon: "mic", label: "Dictations", count: dictationCount,
                    active: selection == .dictations,
                    action: { selection = .dictations })
            NavItem(icon: "gearshape", label: "Settings",
                    active: selection == .settings,
                    action: { selection = .settings })
        }
    }
}

private struct NavItem: View {
    let icon: String
    let label: String
    var count: Int?
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: VedivoxSpace.m) {
                Image(systemName: icon)
                    .frame(width: 16, alignment: .center)
                Text(label)
                    .vedivoxFont(.row)
                Spacer(minLength: 4)
                if let count { VedivoxCountBadge(count: count) }
            }
            .padding(.vertical, VedivoxSpace.xs)
            .padding(.horizontal, VedivoxSpace.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(active ? Color.Vedivox.fg : Color.Vedivox.fgSecondary)
        }
        .buttonStyle(.vedivoxRow(active: active))
        .accessibilityIdentifier("sidebar.\(label)")
        .accessibilityLabel(label)
    }
}
