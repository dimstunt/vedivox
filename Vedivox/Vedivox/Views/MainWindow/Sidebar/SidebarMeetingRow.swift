import AppKit
import SwiftUI

struct SidebarMeetingRow: View {
    let meeting: Meeting
    let seriesName: String?
    let active: Bool
    let onSelect: () -> Void

    @Environment(AppState.self) private var appState

    private var isMultiTarget: Bool {
        appState.selectedMeetingIds.count > 1
            && appState.selectedMeetingIds.contains(meeting.id)
    }

    /// Row bodies evaluated, read by the list's PerfTrace.
    private static var bodyCount = 0

    static func takeBodyCount() -> Int {
        defer { bodyCount = 0 }
        return bodyCount
    }

    var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = Self.bodyCount += 1 // `_ =` is not allowed inside a view builder
        Button {
            onSelect()
        } label: {
            VStack(alignment: .leading, spacing: VedivoxSpace.xs) {
                HStack(spacing: VedivoxSpace.s) {
                    Text(timeString)
                        .vedivoxFont(.tabular)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                    if let duration = meeting.durationSeconds {
                        separator
                        Text(durationString(duration))
                            .vedivoxFont(.caption)
                            .foregroundStyle(Color.Vedivox.fgSecondary)
                    }
                    if let seriesName {
                        separator
                        Text(seriesName)
                            .vedivoxFont(.caption)
                            .foregroundStyle(Color.Vedivox.fgSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    statusBadge
                }

                Text(meeting.title.isEmpty ? "Untitled" : meeting.title)
                    .vedivoxFont(.row)
                    .foregroundStyle(active ? Color.Vedivox.fg : Color.Vedivox.fgSecondary)
                    .lineLimit(1)
            }
            .padding(.vertical, VedivoxSpace.xs)
            .padding(.horizontal, VedivoxSpace.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.vedivoxRow(active: active || isMultiTarget))
        .accessibilityIdentifier("sidebar.meeting")
        .contextMenu { contextMenuContent }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if isMultiTarget {
            let ids = Array(appState.selectedMeetingIds)
            Button {
                copyToClipboard(ids.joined(separator: "\n"))
            } label: {
                Label("Copy IDs (\(ids.count))", systemImage: "doc.on.doc")
            }
            // Undo Merge in the transcript header reverts it.
            if ids.count == 2 {
                Button {
                    Task { await appState.mergeMeetings(ids[0], ids[1]) }
                } label: {
                    Label("Merge Meetings", systemImage: "arrow.triangle.merge")
                }
                .disabled(appState.mergeInProgress)
            }
            Divider()
            Button(role: .destructive) {
                appState.requestDeleteMeetings(Set(ids))
            } label: {
                Label("Delete \(ids.count) Meetings", systemImage: "trash")
            }
        } else {
            Button {
                onSelect()
            } label: {
                Label("Open", systemImage: "arrow.right.circle")
            }
            Button {
                onSelect()
                appState.renameRequestMeetingId = meeting.id
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                onSelect()
                appState.meetingEditRequestId = meeting.id
            } label: {
                Label("Meeting Settings…", systemImage: "slider.horizontal.3")
            }
            seriesSubmenu
            Button {
                Task { await appState.exportMeeting(meeting.id) }
            } label: {
                Label("Export to Markdown", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut(appState.shortcut(.exportMarkdown))
            Divider()
            Button {
                copyToClipboard(meeting.id)
            } label: {
                Label("Copy ID", systemImage: "doc.on.doc")
            }
            Button {
                copyToClipboard("vedivox://meeting/\(meeting.id)")
            } label: {
                Label("Copy Link", systemImage: "link")
            }
            Divider()
            Button(role: .destructive) {
                appState.requestDeleteMeetings([meeting.id])
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    /// «Добавить в серию» — one entry per existing series, checkmark on the
    /// current one, plus removal when the meeting is already in a series.
    private var seriesSubmenu: some View {
        Menu {
            ForEach(appState.meetingSeries) { series in
                if meeting.seriesId == series.id {
                    Button {
                        Task { await appState.setMeetingSeries(meeting.id, seriesId: nil) }
                    } label: {
                        Label(series.name, systemImage: "checkmark")
                    }
                } else {
                    Button(series.name) {
                        Task { await appState.setMeetingSeries(meeting.id, seriesId: series.id) }
                    }
                }
            }
            if meeting.seriesId != nil {
                Divider()
                Button("Remove from Series") {
                    Task { await appState.setMeetingSeries(meeting.id, seriesId: nil) }
                }
            }
        } label: {
            Label("Add to Series", systemImage: "link")
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var timeString: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US")
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: meeting.startTime)
    }

    private func durationString(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m) min" }
        return "\(total) s"
    }

    private var separator: some View {
        Text("·").vedivoxFont(.caption).foregroundStyle(Color.Vedivox.fgQuaternary)
    }

    private var statusHelp: String {
        MeetingStatusReason.help(status: meeting.status, stored: meeting.statusReason) ?? ""
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch meeting.status {
        case .recording:
            Image(systemName: "record.circle").foregroundStyle(Color.Vedivox.recording)
        case .transcribing:
            Image(systemName: "waveform").foregroundStyle(Color.Vedivox.warning)
        case .diarizing:
            Image(systemName: "person.2").foregroundStyle(Color.Vedivox.warning)
        case .needsAttention:
            Image(systemName: "exclamationmark.circle").foregroundStyle(Color.Vedivox.warning)
                .help(statusHelp)
        case .error:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.Vedivox.danger)
                .help(statusHelp)
        case .done:
            EmptyView()
        }
    }
}
