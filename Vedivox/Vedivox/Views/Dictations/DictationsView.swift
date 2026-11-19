import KeyboardShortcuts
import SwiftUI

/// Dictation history.
///
/// Replaces a `ComingSoonView` placeholder that claimed the feature did not
/// exist — the same class of untruth as the settings toggle and the loading
/// banner's «first run».
struct DictationsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.dictations.isEmpty {
                ContentUnavailableView(
                    "No dictations yet",
                    systemImage: "text.cursor",
                    description: Text(
                        "Press \(shortcutDescription), dictate — the text is inserted and saved here"
                    )
                )
            } else {
                list
            }
        }
        .task { await appState.loadDictations() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: VedivoxSpace.m) {
                ForEach(appState.dictations) { dictation in
                    DictationRow(
                        dictation: dictation,
                        onCopy: { appState.copyDictationText(dictation) },
                        onRetranscribe: { await appState.retranscribeDictation(dictation) },
                        onDelete: { Task { await appState.deleteDictation(dictation) } }
                    )
                    .padding(.horizontal, VedivoxSpace.l)
                }
            }
            .padding(.vertical, VedivoxSpace.l)
        }
    }

    private var shortcutDescription: String {
        KeyboardShortcuts.getShortcut(for: .toggleDictation)?.description ?? "the dictation shortcut"
    }
}

/// One history entry.
///
/// Takes closures rather than reaching for `AppState`: that keeps it renderable
/// in isolation, which is what lets the snapshot tests pin its layout.
struct DictationRow: View {
    let dictation: Dictation
    var onCopy: () -> Void = {}
    var onRetranscribe: () async -> AppState.RetranscribeOutcome = { .unchanged }
    var onDelete: () -> Void = {}

    /// What just happened, shown for a moment beside the buttons.
    ///
    /// Both actions were silent until a user pressed copy and could not tell
    /// whether it had worked. Copying leaves no trace on screen by nature, and
    /// re-transcription usually returns the same text — so in both cases the
    /// result of a successful press is *nothing changing*, which is
    /// indistinguishable from a dead button.
    ///
    /// Words rather than a checkmark: a tick can say «done», but not «done, and
    /// the text is the same as before», which is the common answer here.
    @State private var flash: String?
    @State private var isRetranscribing = false

    var body: some View {
        VStack(alignment: .leading, spacing: VedivoxSpace.s) {
            HStack(spacing: VedivoxSpace.m) {
                Text(dictation.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgSecondary)

                Text(ElapsedTimeLabel.text(for: dictation.durationSeconds))
                    .vedivoxFont(.timecode)
                    .foregroundStyle(Color.Vedivox.fgSecondary)

                if let app = dictation.targetApp {
                    Text("→ \(app)")
                        .vedivoxFont(.caption)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                }

                // Only worth saying when it did not: a successful dictation is
                // the expected case and needs no badge.
                if !dictation.inserted, !dictation.text.isEmpty {
                    Text("not inserted")
                        .vedivoxFont(.caption)
                        .foregroundStyle(Color.Vedivox.warning)
                }

                Spacer()

                if let flash {
                    Text(flash)
                        .vedivoxFont(.caption)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                        .transition(.opacity)
                }

                actions
            }

            // Empty text is a real outcome, not a rendering bug: the clip was
            // kept so it can be re-recognized from here.
            Text(dictation.text.isEmpty ? emptyText : dictation.text)
                .vedivoxFont(.transcript)
                .foregroundStyle(dictation.text.isEmpty ? Color.Vedivox.fgSecondary : Color.Vedivox.fg)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(VedivoxSpace.l)
        .background(Color.Vedivox.bgCard, in: RoundedRectangle(cornerRadius: VedivoxRadius.m))
        .overlay(RoundedRectangle(cornerRadius: VedivoxRadius.m).strokeBorder(Color.Vedivox.line))
    }

    /// Owed a recognition and having had none are different stories.
    private var emptyText: String {
        dictation.awaitingTranscription
            ? "Not transcribed yet: Vedivox quit during this dictation"
            : "Nothing recognized"
    }

    private var actions: some View {
        HStack(spacing: VedivoxSpace.s) {
            Button {
                onCopy()
                show("Copied")
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.vedivoxIcon)
            .help("Copy text")

            // Absent rather than disabled when the audio is gone: retention
            // removes audio from older entries by design, and a permanently
            // greyed-out button reads as breakage.
            if dictation.hasAudio {
                Button {
                    Task {
                        isRetranscribing = true
                        let outcome = await onRetranscribe()
                        isRetranscribing = false
                        switch outcome {
                        case .replaced: show("Updated")
                        case .unchanged: show("No changes")
                        case .failed: show("Failed")
                        }
                    }
                } label: {
                    if isRetranscribing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.vedivoxIcon)
                // Recognition takes seconds; a second press would run it again
                // over the same audio for the same answer.
                .disabled(isRetranscribing)
                .help("Re-transcribe")
            }

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.vedivoxIcon)
            .help("Delete")
        }
        .foregroundStyle(Color.Vedivox.fgSecondary)
        .animation(.easeInOut(duration: 0.15), value: flash)
    }

    /// Says what just happened, then takes it away.
    ///
    /// Two seconds: long enough to be read by someone who looked away to check
    /// the result, short enough not to become a permanent label on the row. A
    /// second action inside that window replaces the message rather than
    /// queueing behind it — hence the guard before clearing.
    private func show(_ message: String) {
        flash = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard flash == message else { return }
            flash = nil
        }
    }
}
