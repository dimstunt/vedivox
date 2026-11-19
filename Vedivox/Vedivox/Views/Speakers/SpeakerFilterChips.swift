import SwiftUI

/// Speaker chips with a meeting count; a click adds the speaker to the filter,
/// a second click takes them out.
struct SpeakerFilterChips: View {
    let filter: SpeakerChipFilter
    @Binding var selection: Set<SpeakerChipFilter.Key>
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        FlowLayoutLite(spacing: VedivoxSpace.s) {
            ForEach(filter.chips) { chip in
                chipButton(chip)
            }
        }
    }

    private func chipButton(_ chip: SpeakerChipFilter.Chip) -> some View {
        let isOn = selection.contains(chip.key)
        let hue = chip.speaker.map { $0.hue ?? SpeakerHue.for($0.id) }
        // The unnamed chip stands for several people, so it gets no speaker colour.
        let accent = hue.map { Color.speaker(hue: $0, scheme: scheme) } ?? Color.Vedivox.fgSecondary
        let fill = hue.map { Color.speakerBg(hue: $0, scheme: scheme) } ?? Color.Vedivox.bgInput
        let meetings = "\(chip.meetingCount) meeting\(chip.meetingCount == 1 ? "" : "s")"
        return Button {
            if isOn {
                selection.remove(chip.key)
            } else {
                selection.insert(chip.key)
            }
        } label: {
            HStack(spacing: VedivoxSpace.s) {
                Circle()
                    .fill(accent)
                    .frame(width: VedivoxSize.dot, height: VedivoxSize.dot)
                Text(chip.label)
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fg)
                Text("\(chip.meetingCount)")
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgQuaternary)
            }
            .padding(.horizontal, VedivoxSpace.m)
            .padding(.vertical, VedivoxSpace.xs)
            .background(isOn ? fill : Color.Vedivox.bgCard, in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? accent : Color.Vedivox.lineSoft))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isOn
            ? "Click again to stop filtering by this chip"
            : chip.speaker == nil
            ? "Unnamed voices (Speaker N) talk in \(meetings); the same label in two meetings is two different people. Click to show only these meetings"
            : "Speaks in \(meetings). Click to show only the meetings with them")
    }
}
