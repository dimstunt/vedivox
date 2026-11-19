import SwiftUI

struct SidebarRecordingBlock: View {
    @Bindable var recordingVM: RecordingViewModel
    @Environment(AppState.self) private var appState

    /// No in-window ⌘⇧R any more: the global recording shortcut works here too
    /// so the tooltip names it.
    private var startHelp: String {
        appState.shortcutText(.toggleRecording).map { "Start Recording (\($0))" } ?? "Start Recording"
    }

    /// Start is the neutral primary button with a recording-red mark; solid red
    /// is kept for Stop, so red on screen means a recording is live
    /// (option A).
    private var startButton: some View {
        Button {
            Task { await recordingVM.startRecording(appState: appState) }
        } label: {
            Label {
                Text("Start Recording")
            } icon: {
                Image(systemName: "record.circle")
                    .foregroundStyle(Color.Vedivox.recordingMark)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.vedivoxProminent)
        .help(startHelp)
        .accessibilityIdentifier("recording.start")
        .accessibilityLabel("Start Recording")
    }

    var body: some View {
        VStack(spacing: VedivoxSpace.m) {
            switch recordingVM.state {
            case .idle:
                startButton

            case .recording:
                VStack(spacing: VedivoxSpace.s) {
                    HStack(spacing: VedivoxSpace.s) {
                        Circle()
                            .fill(Color.Vedivox.recording)
                            .frame(width: VedivoxSize.dot, height: VedivoxSize.dot)
                        Text("Recording")
                            .vedivoxFont(.label)
                            .foregroundStyle(Color.Vedivox.fg)
                        Spacer()
                        Text(recordingVM.formattedDuration)
                            .vedivoxFont(.tabular)
                            .foregroundStyle(Color.Vedivox.recording)
                    }
                    Button {
                        Task { await recordingVM.stopRecording(appState: appState) }
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.vedivoxRecord)
                    .accessibilityIdentifier("recording.stop")
                    .accessibilityLabel("Stop Recording")
                }

            case .processing:
                // Recording is allowed while the previous meeting is still
                // transcribing — keep the start button available,
                // back-to-back meetings shouldn't wait for the pipeline.
                // The «Processing N meetings…» line below says what is going on.
                startButton

            case .done:
                Label("Transcript ready", systemImage: "checkmark.circle.fill")
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.success)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            recordingVM.reset()
                        }
                    }

            case .error(let msg):
                VStack(alignment: .leading, spacing: VedivoxSpace.xs) {
                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                        .vedivoxFont(.caption)
                        .foregroundStyle(Color.Vedivox.danger)
                    Text(msg)
                        .vedivoxFont(.caption)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                    Button("Dismiss") { recordingVM.reset() }
                        .controlSize(.small)
                }
            }

            processingLine
        }
    }

    /// Reprocesses and imports too, not only the stopped recording: a meeting
    /// processed off screen was otherwise invisible.
    @ViewBuilder private var processingLine: some View {
        let recordingId = recordingVM.state == .recording ? recordingVM.currentMeetingId : nil
        let processing = ProcessingMeetings.of(appState.meetings, recordingId: recordingId)
        if let first = processing.first {
            Button {
                appState.view = .meetings
                appState.selectedMeetingIds = [first.id]
                appState.revealInSidebarRequest += 1
            } label: {
                HStack(spacing: VedivoxSpace.m) {
                    ProgressView().controlSize(.small)
                    Text(ProcessingMeetings.label(processing.count))
                        .vedivoxFont(.caption)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open “\(first.title)”")
            .accessibilityIdentifier("sidebar.processing")
        }
    }
}
