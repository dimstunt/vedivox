import SwiftUI

/// «Настройки встречи» (EditMeetingModal from the design bundle):
/// title, date/time, series and language in one place. Speakers are absent by
/// design — they come from diarization. Calendar-lock lands with Phase 10.
struct MeetingEditSheet: View {
    let meeting: Meeting
    @Bindable var viewModel: MeetingDetailViewModel
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var startTime: Date
    @State private var seriesId: String?
    @State private var language: String
    @FocusState private var titleFocused: Bool

    init(meeting: Meeting, viewModel: MeetingDetailViewModel) {
        self.meeting = meeting
        self.viewModel = viewModel
        _title = State(initialValue: meeting.title)
        _startTime = State(initialValue: meeting.startTime)
        _seriesId = State(initialValue: meeting.seriesId)
        _language = State(initialValue: meeting.language)
    }

    private static let languages: [(code: String, label: String)] = [
        ("ru", "RU"), ("en", "EN"), ("auto", "Auto"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Meeting Settings")
                .vedivoxFont(.title)
                .foregroundStyle(Color.Vedivox.fg)
                .padding(.bottom, VedivoxSpace.xl)

            VStack(alignment: .leading, spacing: VedivoxSpace.l) {
                field("Title") {
                    TextField("Meeting title", text: $title)
                        .textFieldStyle(.plain)
                        .focused($titleFocused)
                        .padding(VedivoxSpace.s)
                        .background(RoundedRectangle(cornerRadius: VedivoxRadius.s).fill(Color.Vedivox.bgInput))
                        .overlay(RoundedRectangle(cornerRadius: VedivoxRadius.s).strokeBorder(Color.Vedivox.line))
                }

                HStack(alignment: .top, spacing: VedivoxSpace.xl) {
                    field("Date & time") {
                        DatePicker("", selection: $startTime, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .fixedSize()
                    }
                    field("Series") {
                        VedivoxPicker(
                            selection: $seriesId,
                            options: [(nil, "No series")] + appState.meetingSeries.map { (String?.some($0.id), $0.name) }
                        )
                        .frame(maxWidth: 220)
                    }
                }

                field("Language") {
                    Picker("", selection: $language) {
                        ForEach(Self.languages, id: \.code) { lang in
                            Text(lang.label).tag(lang.code)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Spacer(minLength: 20)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.vedivoxGhost)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        await save()
                        dismiss()
                    }
                }
                .buttonStyle(.vedivoxProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(VedivoxSpace.xxl)
        .frame(width: 480, height: 300)
        .background(Color.Vedivox.bgCard)
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: VedivoxSpace.s) {
            VedivoxSectionHeader(title: label)
            content()
        }
    }

    private func save() async {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed != meeting.title, !trimmed.isEmpty {
            await viewModel.renameMeeting(to: trimmed)
            if let idx = appState.meetings.firstIndex(where: { $0.id == meeting.id }) {
                appState.meetings[idx].title = trimmed
            }
        }
        if startTime != meeting.startTime {
            await viewModel.updateStartTime(startTime)
        }
        if seriesId != meeting.seriesId {
            await appState.setMeetingSeries(meeting.id, seriesId: seriesId)
        }
        if language != meeting.language {
            let repo = MeetingRepository()
            if var updated = try? await repo.find(meeting.id) {
                updated.language = language
                try? await repo.save(updated)
            }
            await viewModel.load(meetingId: meeting.id)
        }
        await appState.loadMeetings()
        appState.transcriptVersion += 1
    }
}
