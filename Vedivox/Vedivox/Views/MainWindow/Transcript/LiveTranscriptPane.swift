import SwiftUI

/// The window of the meeting being recorded: its live text in place of the
/// «after the recording stops» notice.
struct LiveTranscriptPane: View {
    @Environment(AppState.self) private var appState
    let meetingId: String
    @State private var model = LiveTranscriptScreenModel()

    var body: some View {
        LiveTranscriptContent(model: model)
            .task(id: meetingId) {
                // Read once: an edit of the vocabulary reaches the next recording's window.
                let normaliser = LiveTranscriptCommand.Normaliser(vocabulary: TermNormalizer.loadVocabulary())
                await model.follow(while: Self.mainWindowOnScreen) {
                    await appState.liveTranscriptTurns(for: meetingId, normaliser: normaliser)
                }
            }
    }

    /// A closed main window lingers invisible with this pane alive, and a
    /// hidden or covered one is read by nobody.
    private static func mainWindowOnScreen() -> Bool {
        NSApp.windows.contains {
            $0.identifier?.rawValue.hasPrefix("main-") == true && $0.occlusionState.contains(.visible)
        }
    }
}

/// The pane's drawing alone, so a snapshot can show it without a recording.
struct LiveTranscriptContent: View {
    let model: LiveTranscriptScreenModel
    private static let end = "live-transcript-end"

    var body: some View {
        switch model.content {
        case nil:
            // Fills the pane on purpose: the first reading is milliseconds away.
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .off:
            notice("Recording...", "Transcript will appear after the recording stops.")
        case .listening:
            VStack(spacing: 0) {
                preliminary
                notice("Listening…", "What is said appears here a few seconds after it is said.")
            }
        case .turns(let rows):
            VStack(spacing: 0) {
                preliminary
                turns(rows)
            }
        }
    }

    private var preliminary: some View {
        Text("Preliminary text — the final transcript replaces it after the recording stops")
            .vedivoxFont(.caption)
            .foregroundStyle(Color.Vedivox.fgSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, VedivoxSpace.xl)
            .padding(.vertical, VedivoxSpace.m)
    }

    private func notice(_ title: String, _ detail: String) -> some View {
        VStack(spacing: VedivoxSpace.l) {
            Image(systemName: "record.circle")
                .font(.largeTitle)
                .foregroundStyle(Color.Vedivox.recording)
            Text(title)
                .vedivoxFont(.bodyStrong)
            Text(detail)
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func turns(_ rows: [LiveTranscriptScreenModel.Row]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: VedivoxSpace.xl) {
                    ForEach(rows) { LiveTurnRow(row: $0) }
                    // On screen while the reader is at the end of the text; its
                    // leaving is how the pane knows they scrolled up to read.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.end)
                        .onAppear { model.readerScrolled(atEnd: true) }
                        .onDisappear { model.readerScrolled(atEnd: false) }
                }
                .padding(.horizontal, VedivoxSpace.xl)
                .padding(.bottom, VedivoxSpace.xl)
            }
            .onAppear { proxy.scrollTo(Self.end, anchor: .bottom) }
            .onChange(of: model.scrollTick) { proxy.scrollTo(Self.end, anchor: .bottom) }
        }
    }
}

/// One turn, laid out as a run of the finished transcript: who and when on
/// the left, the text on the right.
private struct LiveTurnRow: View {
    let row: LiveTranscriptScreenModel.Row
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: VedivoxSpace.xl) {
            VStack(alignment: .trailing, spacing: VedivoxSpace.m) {
                Text(displayName)
                    .vedivoxFont(.overline)
                    .foregroundStyle(nameColour)
                    .padding(.vertical, VedivoxSpace.xxs)
                Text(row.time)
                    .vedivoxFont(.timecode)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                    .padding(.vertical, VedivoxSpace.xxs)
            }
            .frame(width: 120, alignment: .trailing)

            Text(row.text)
                .vedivoxFont(.body)
                .lineSpacing(2)
                .textSelection(.enabled)
                .foregroundStyle(Color.Vedivox.fg)
                .transcriptBubble(scheme)
        }
        .transcriptColumn()
    }

    /// `vedivox live` keeps `me` and `others`; the window says it in words.
    private var displayName: String {
        row.speaker == .me ? "You" : row.speaker == .others ? "Others" : row.speaker.name
    }

    /// Nobody in particular is not a persona: muted, like UNKNOWN in the transcript.
    private var nameColour: Color {
        row.speaker == .others
            ? Color.Vedivox.fgSecondary
            : Color.speakerLabel(row.speaker.name, key: row.speaker.name, scheme: scheme)
    }
}
