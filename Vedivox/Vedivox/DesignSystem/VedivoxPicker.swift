import SwiftUI

/// Drop-down choice (design system: Picker): a trigger that opens a Vedivox
/// popover list instead of the system popup menu, which highlights items in
/// the macOS accent. Keys in the open list: ↑↓ move, Return
/// picks, Esc closes.
///
/// The default trigger looks like a field; pass `label` for a custom one
/// (the player's speed chip).
struct VedivoxPicker<Value: Hashable, Label: View>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @ViewBuilder let label: () -> Label

    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VedivoxPickerList(options: options, selected: selection) { value in
                // Esc and a click on the current choice close without a write:
                // some bindings save on every set (the inspector's series).
                if value != selection { selection = value }
                open = false
            }
        }
    }
}

extension VedivoxPicker where Label == VedivoxPickerField {
    init(selection: Binding<Value>, options: [(Value, String)]) {
        self.init(selection: selection, options: options) {
            VedivoxPickerField(text: options.first { $0.0 == selection.wrappedValue }?.1 ?? "")
        }
    }
}

/// The default trigger: the field's fill, stroke and radius, the current
/// choice and an up-down chevron.
struct VedivoxPickerField: View {
    let text: String

    var body: some View {
        HStack(spacing: VedivoxSpace.s) {
            Text(text)
                .vedivoxFont(.body)
                .foregroundStyle(Color.Vedivox.fg)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
                .foregroundStyle(Color.Vedivox.fgSecondary)
        }
        .padding(.horizontal, VedivoxSpace.m)
        .padding(.vertical, 5)
        .background(Color.Vedivox.bgInput, in: RoundedRectangle(cornerRadius: VedivoxRadius.s))
        .overlay(RoundedRectangle(cornerRadius: VedivoxRadius.s).strokeBorder(Color.Vedivox.line))
    }
}

/// The open list. Internal, not private, so the snapshot suite can draw it
/// without a popover.
struct VedivoxPickerList<Value: Hashable>: View {
    let options: [(Value, String)]
    let selected: Value
    let choose: (Value) -> Void
    /// Starts on the current choice; the pointer and the arrow keys move it.
    @State var highlighted: Int?

    @FocusState private var focused: Bool

    init(options: [(Value, String)], selected: Value, highlighted: Int? = nil, choose: @escaping (Value) -> Void) {
        self.options = options
        self.selected = selected
        self.choose = choose
        _highlighted = State(initialValue: highlighted ?? options.firstIndex { $0.0 == selected })
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: VedivoxSpace.xxs) {
                    ForEach(options.indices, id: \.self) { index in
                        row(index)
                    }
                }
                .padding(VedivoxSpace.xs)
            }
            .frame(minWidth: 160)
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.Vedivox.bgCard)
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(.upArrow) { move(-1, proxy) }
            .onKeyPress(.downArrow) { move(1, proxy) }
            .onKeyPress(.return) {
                guard let highlighted else { return .ignored }
                choose(options[highlighted].0)
                return .handled
            }
            .onKeyPress(.escape) {
                choose(selected) // closes without a change
                return .handled
            }
        }
    }

    private func row(_ index: Int) -> some View {
        let isSelected = options[index].0 == selected
        return HStack(spacing: VedivoxSpace.s) {
            Image(systemName: "checkmark")
                .imageScale(.small)
                .foregroundStyle(Color.Vedivox.accentText)
                .opacity(isSelected ? 1 : 0)
            Text(options[index].1)
                .vedivoxFont(.row)
                .foregroundStyle(Color.Vedivox.fg)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VedivoxSpace.s)
        .padding(.vertical, VedivoxSpace.xs)
        .background(
            RoundedRectangle(cornerRadius: VedivoxRadius.xs)
                .fill(isSelected ? Color.Vedivox.bgActive : (highlighted == index ? Color.Vedivox.bgHover : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { if $0 { highlighted = index } }
        .onTapGesture { choose(options[index].0) }
        .id(index)
    }

    private func move(_ step: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !options.isEmpty else { return .ignored }
        let next = min(max((highlighted ?? -1) + step, 0), options.count - 1)
        highlighted = next
        proxy.scrollTo(next)
        return .handled
    }
}
