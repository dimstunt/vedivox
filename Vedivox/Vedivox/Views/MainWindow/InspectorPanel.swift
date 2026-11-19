import SwiftUI

/// Right-side inspector consolidating Description and the Series picker
/// into a single collapsible panel.
struct InspectorPanel: View {
    @Bindable var viewModel: MeetingDetailViewModel
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DescriptionInspectorSection(viewModel: viewModel)
                Divider()
                SeriesInspectorSection(viewModel: viewModel)
            }
            .padding(.vertical, VedivoxSpace.xs)
        }
    }
}

// MARK: - Section chrome

private struct InspectorSectionHeader: View {
    let title: String
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: VedivoxSpace.s) {
            VedivoxSectionHeader(title: title)

            Spacer()

            if let trailing { trailing }
        }
        .padding(.bottom, VedivoxSpace.m)
    }
}

// MARK: - Description

private struct DescriptionInspectorSection: View {
    @Bindable var viewModel: MeetingDetailViewModel
    @State private var isEditing = false
    @State private var saveTask: Task<Void, Never>?
    /// The meeting `saveTask` will save into.
    @State private var saveTaskMeetingId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorSectionHeader(
                title: "Description",
                trailing: AnyView(
                    Button(isEditing ? "Done" : "Edit") { isEditing.toggle() }
                        .buttonStyle(.vedivoxLink)
                        .vedivoxFont(.caption)
                )
            )

            if isEditing {
                editor
            } else {
                preview
            }
        }
        .padding(.horizontal, VedivoxSpace.l)
        .padding(.vertical, VedivoxSpace.l)
    }

    private var editor: some View {
        TextEditor(text: $viewModel.descriptionText)
            .vedivoxFont(.tabular)
            .frame(minHeight: 120, maxHeight: 280)
            .scrollContentBackground(.hidden)
            .padding(VedivoxSpace.xs)
            .background(
                RoundedRectangle(cornerRadius: VedivoxRadius.s)
                    .fill(Color.Vedivox.bgInput)
            )
            .onChange(of: viewModel.descriptionText) { _, text in
                guard let id = viewModel.meeting?.id else { return }
                // A newer edit of the same meeting replaces the pending save.
                // A pending save of ANOTHER meeting is left to finish: this
                // view outlives the switch, and the switch used to cancel the
                // last half second of typing in the meeting just left.
                if saveTaskMeetingId == id { saveTask?.cancel() }
                // What a load put here is what is stored: nothing to save.
                guard text != (viewModel.meeting?.description ?? "") else { return }
                saveTaskMeetingId = id
                saveTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    await viewModel.updateDescription(text, meetingId: id)
                }
            }
    }

    @ViewBuilder
    private var preview: some View {
        if viewModel.descriptionText.isEmpty {
            Text("No description yet. Double-click to add one.")
                .vedivoxFont(.body)
                .foregroundStyle(Color.Vedivox.fgSecondary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { isEditing = true }
        } else {
            DescriptionMarkdownView(
                source: viewModel.descriptionText,
                onSeek: { t in viewModel.seekAndPlay(to: t) },
                onCheckboxToggle: { idx in
                    let next = toggleMarkdownCheckbox(viewModel.descriptionText, at: idx)
                    guard next != viewModel.descriptionText else { return }
                    viewModel.descriptionText = next
                    if let id = viewModel.meeting?.id {
                        Task { await viewModel.updateDescription(next, meetingId: id) }
                    }
                }
            )
            .padding(VedivoxSpace.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: VedivoxRadius.s)
                    .fill(Color.Vedivox.bgInput)
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { isEditing = true }
        }
    }
}

// MARK: - Series

private struct SeriesInspectorSection: View {
    @Bindable var viewModel: MeetingDetailViewModel
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorSectionHeader(title: "Series")

            VedivoxPicker(selection: Binding(
                get: { viewModel.meeting?.seriesId },
                set: { newId in
                    guard let meetingId = viewModel.meeting?.id else { return }
                    Task {
                        try? await MeetingRepository().updateSeriesId(meetingId, seriesId: newId)
                        await viewModel.load(meetingId: meetingId)
                        await appState.loadMeetings()
                        await appState.loadSeries()
                    }
                }
            ), options: [(nil, "No series")] + appState.meetingSeries.map { (String?.some($0.id), $0.name) })
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, VedivoxSpace.l)
        .padding(.vertical, VedivoxSpace.l)
    }
}
