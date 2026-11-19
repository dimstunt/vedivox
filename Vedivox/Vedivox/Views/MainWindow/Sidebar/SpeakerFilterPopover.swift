import SwiftUI

struct SpeakerFilterPopover: View {
    let allSpeakers: [Speaker]
    let recentIds: [String]
    @Binding var selectedIds: Set<String>

    @Environment(\.colorScheme) private var scheme
    @FocusState private var searchFocused: Bool
    @State private var query: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: VedivoxSpace.s) {
            header

            chipStrip

            Divider().background(Color.Vedivox.lineSoft)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: VedivoxSpace.xxs) {
                    if query.isEmpty, !recentVisible.isEmpty {
                        sectionHeader("Recent")
                        ForEach(recentVisible) { speaker in
                            rowView(for: speaker)
                        }
                        sectionHeader("All (\(allSpeakers.count))")
                        ForEach(restVisible) { speaker in
                            rowView(for: speaker)
                        }
                    } else {
                        ForEach(filtered) { speaker in
                            rowView(for: speaker)
                        }
                    }

                    if filtered.isEmpty, query.isEmpty ? allSpeakers.isEmpty : true {
                        Text(query.isEmpty ? "No speakers" : "No matches")
                            .vedivoxFont(.caption)
                            .foregroundStyle(Color.Vedivox.fgSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, VedivoxSpace.xxl)
                    }
                }
                .padding(.vertical, VedivoxSpace.xs)
            }
        }
        .padding(VedivoxSpace.l)
        .frame(width: 280, height: 440)
        .onAppear { searchFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: VedivoxSpace.s) {
            HStack(spacing: VedivoxSpace.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                TextField("Search speakers", text: $query)
                    .textFieldStyle(.plain)
                    .vedivoxFont(.row)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.Vedivox.fgSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, VedivoxSpace.m)
            .padding(.vertical, VedivoxSpace.s)
            .background(Color.Vedivox.bgInput, in: RoundedRectangle(cornerRadius: VedivoxRadius.s))

            if !selectedIds.isEmpty {
                Button("Clear (\(selectedIds.count))") { selectedIds.removeAll() }
                    .buttonStyle(.plain)
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.accentText)
            }
        }
    }

    // MARK: - Chip strip

    private var chipStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: VedivoxSpace.xs) {
                ForEach(selectedSpeakers) { speaker in
                    chip(speaker)
                }
            }
        }
        .frame(height: 26)
    }

    private func chip(_ speaker: Speaker) -> some View {
        Button {
            selectedIds.remove(speaker.id)
        } label: {
            HStack(spacing: VedivoxSpace.xs) {
                dot(for: speaker, size: 6)
                Text(speaker.displayName)
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fg)
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.Vedivox.fgSecondary)
            }
            .padding(.horizontal, VedivoxSpace.s)
            .padding(.vertical, VedivoxSpace.xs)
            .background(Color.Vedivox.bgCard, in: Capsule())
            .overlay(Capsule().stroke(Color.Vedivox.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rows

    private func sectionHeader(_ text: String) -> some View {
        VedivoxSectionHeader(title: text)
            .padding(.horizontal, VedivoxSpace.s)
            .padding(.top, VedivoxSpace.s)
            .padding(.bottom, VedivoxSpace.xxs)
    }

    private func rowView(for speaker: Speaker) -> some View {
        let selected = selectedIds.contains(speaker.id)
        return SpeakerRow(
            speaker: speaker,
            isSelected: selected,
            hue: speaker.hue ?? SpeakerHue.for(speaker.id),
            onToggle: { toggle(speaker.id) }
        )
        .id("\(speaker.id)-\(selected)")
    }

    private func dot(for speaker: Speaker, size: CGFloat) -> some View {
        Circle()
            .fill(Color.speaker(hue: speaker.hue ?? SpeakerHue.for(speaker.id), scheme: scheme))
            .frame(width: size, height: size)
    }

    // MARK: - Filtering / ordering

    private var filtered: [Speaker] {
        guard !query.isEmpty else { return allSpeakers }
        let q = query.lowercased()
        return allSpeakers.filter { speaker in
            speaker.displayName.lowercased().contains(q)
                || speaker.nameEn.lowercased().contains(q)
        }
    }

    private var recentVisible: [Speaker] {
        let recentSet = Set(recentIds)
        let byId = Dictionary(uniqueKeysWithValues: allSpeakers.map { ($0.id, $0) })
        return recentIds.compactMap { byId[$0] }.filter { _ in true }
            .filter { recentSet.contains($0.id) }
    }

    private var restVisible: [Speaker] {
        let recentSet = Set(recentIds)
        return allSpeakers.filter { !recentSet.contains($0.id) }
    }

    private var selectedSpeakers: [Speaker] {
        allSpeakers.filter { selectedIds.contains($0.id) }
    }

    private func toggle(_ id: String) {
        var next = selectedIds
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        selectedIds = next
    }
}

private struct SpeakerRow: View {
    let speaker: Speaker
    let isSelected: Bool
    let hue: Double
    let onToggle: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: VedivoxSpace.m) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.Vedivox.accentText : Color.Vedivox.fgSecondary)
                Circle()
                    .fill(Color.speaker(hue: hue, scheme: scheme))
                    .frame(width: VedivoxSize.dot, height: VedivoxSize.dot)
                Text(speaker.displayName)
                    .vedivoxFont(.row)
                    .foregroundStyle(Color.Vedivox.fg)
                if speaker.isMe {
                    Text("me")
                        .vedivoxFont(.caption)
                        .foregroundStyle(Color.Vedivox.accentFg)
                        .padding(.horizontal, VedivoxSpace.s)
                        .padding(.vertical, VedivoxSpace.xxs)
                        .background(Color.Vedivox.accent, in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, VedivoxSpace.s)
            .padding(.vertical, VedivoxSpace.xs)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: VedivoxRadius.xs)
                    .fill(isSelected ? Color.Vedivox.bgActive : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}
