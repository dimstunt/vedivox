import SwiftUI
import UniformTypeIdentifiers

/// The microphone priority list in Settings → Recording: numbered
/// rows, drag to reorder (or Move Up / Move Down from the context menu), and
/// tags for the mic a recording would open now and for what is not connected.
struct MicPriorityList: View {
    @Binding var list: MicPriority
    let connected: Set<String>

    private static let dragPrefix = "vedivox-mic:"
    /// The row being dragged; a drop from anywhere else finds it nil.
    @State private var dragging: String?

    var body: some View {
        let current = list.pick(connected: connected) ?? MicPriority.systemDefault.uid
        VStack(spacing: 0) {
            ForEach(Array(list.devices.enumerated()), id: \.element.id) { index, device in
                if index > 0 { Divider().overlay(Color.Vedivox.lineSoft) }
                row(index: index, device: device, isCurrent: device.uid == current)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: VedivoxRadius.s))
        .overlay(RoundedRectangle(cornerRadius: VedivoxRadius.s).strokeBorder(Color.Vedivox.lineSoft))
    }

    private func row(index: Int, device: MicPriority.Device, isCurrent: Bool) -> some View {
        let available = device.uid == MicPriority.systemDefault.uid || connected.contains(device.uid)
        return HStack(spacing: VedivoxSpace.m) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(Color.Vedivox.fgQuaternary)
            Text("\(index + 1)")
                .vedivoxFont(.timecode)
                .foregroundStyle(Color.Vedivox.fgSecondary)
                .frame(minWidth: VedivoxSpace.xl, alignment: .trailing)
                // The old and new number crossfaded mid-move: "2" and "3" stacked.
                .contentTransition(.identity)
            Text(device.name)
                .vedivoxFont(.body)
                .foregroundStyle(available ? Color.Vedivox.fg : Color.Vedivox.fgSecondary)
                .lineLimit(1)
            Spacer()
            if device.isVirtual { tag("Virtual", emphasis: false) }
            if isCurrent { tag("Current", emphasis: true) }
            if !available { tag("Unavailable", emphasis: false) }
        }
        .padding(.horizontal, VedivoxSpace.m)
        .padding(.vertical, VedivoxSpace.s)
        // Opaque, and the dragged row above its neighbour: two clear rows
        // sliding past each other showed through one another — the "shadow"
        // trailing the drag on the owner's recording of build 1690.
        .background(Color.Vedivox.bgCard)
        .contentShape(Rectangle())
        // A move, not `.draggable`: that proposes a copy (the green "+") and
        // reorders only on release. Rows make room while the drag passes.
        .onDrag {
            dragging = device.uid
            return NSItemProvider(object: (Self.dragPrefix + device.uid) as NSString)
        }
        .onDrop(of: [.text], delegate: RowDrop(target: device.uid, list: $list, dragging: $dragging))
        .contextMenu {
            Button("Move Up") { list.devices.swapAt(index, index - 1) }.disabled(index == 0)
            Button("Move Down") { list.devices.swapAt(index, index + 1) }.disabled(index == list.devices.count - 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Move Up") { if index > 0 { list.devices.swapAt(index, index - 1) } }
        .accessibilityAction(named: "Move Down") {
            if index < list.devices.count - 1 { list.devices.swapAt(index, index + 1) }
        }
        .zIndex(dragging == device.uid ? 1 : 0)
    }

    private func tag(_ text: String, emphasis: Bool) -> some View {
        Text(text)
            .vedivoxFont(.caption)
            .foregroundStyle(emphasis ? Color.Vedivox.accentFg : Color.Vedivox.fgSecondary)
            .padding(.horizontal, VedivoxSpace.s)
            .padding(.vertical, VedivoxSpace.xxs)
            .background(emphasis ? Color.Vedivox.accent : Color.Vedivox.bgHover, in: Capsule())
    }
}

private struct RowDrop: DropDelegate {
    let target: String
    @Binding var list: MicPriority
    @Binding var dragging: String?

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = list.devices.firstIndex(where: { $0.uid == dragging }),
              let to = list.devices.firstIndex(where: { $0.uid == target }) else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            list.devices.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
