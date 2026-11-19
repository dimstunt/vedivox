import SwiftUI

/// Top-of-window banner shown while a model warm-up is running long enough to
/// be worth reporting, or when it failed — with a Retry button.
///
/// Before this, `modelLoadError` was written to `AppState` but never rendered
/// by any view, so an offline first run failed completely silently. Progress is
/// determinate for transcription (Parakeet reports a fraction) and indeterminate
/// for the offline diarizer (whose `prepareModels` exposes no progress handler).
///
/// The banner deliberately says nothing about «first run»: warm-up happens on
/// every launch and the app cannot tell them apart. `isModelLoading` gates the
/// flash away, so what is left to say is just the stage.
struct ModelLoadingBanner: View {
    @Environment(AppState.self) private var appState

    /// Meetings whose processing failed — on a first run without network,
    /// every recording made before the models arrived.
    private var failedMeetings: [Meeting] { appState.failedMeetingsOffer.candidates(among: appState.meetings) }

    var body: some View {
        if let update = appState.libraryUpdate {
            // Before anything else: models are not even asked for until the
            // database opens.
            placed(VedivoxBanner(
                .neutral,
                title: "Updating your library…",
                message: update == .backingUp
                    ? "Making a safety copy of the database before this version changes it"
                    : "Applying this version's changes to the database — a large library takes a minute or two"
            ) {
                ProgressView().controlSize(.small)
            })
            .onAppear { Log.info("Banner appeared: library update (\(update))") }
        } else if let error = appState.modelLoadError {
            errorBanner(error)
                .onAppear { Log.info("Banner appeared: model load error") }
        } else if appState.isModelLoading, let progress = appState.modelLoadProgress {
            loadingBanner(progress)
                .onAppear { Log.info("Banner appeared: model loading (\(progress.localizedTitle))") }
        } else if appState.mergeInProgress {
            placed(VedivoxBanner(.neutral, title: "Merging meetings…") {
                ProgressView().controlSize(.small)
            })
        } else if !appState.failedMeetingsOffer.dismissed, !failedMeetings.isEmpty {
            failedBanner(failedMeetings)
                .onAppear { Log.info("Banner appeared: \(failedMeetings.count) failed meeting(s)") }
        }
    }

    private func failedBanner(_ failed: [Meeting]) -> some View {
        let names = failed.prefix(3).map { "“\($0.title)”" }.joined(separator: ", ")
            + (failed.count > 3 ? " and \(failed.count - 3) more" : "")
        return placed(VedivoxBanner(
            .warning,
            title: failed.count == 1 ? "1 meeting was not processed" : "\(failed.count) meetings were not processed",
            message: names
        ) {
            Image(systemName: "exclamationmark.triangle.fill")
        } trailing: {
            HStack(spacing: VedivoxSpace.s) {
                Button("Not Now") { appState.failedMeetingsOffer.dismissed = true }
                    .buttonStyle(.vedivoxGhost)
                Button("Reprocess") {
                    Task { await appState.reprocessFailedMeetings(failed) }
                }
                .buttonStyle(.vedivoxProminent)
                .disabled(appState.failedMeetingsOffer.isRunning)
            }
        })
    }

    private func loadingBanner(_ progress: ModelLoadProgress) -> some View {
        // Always-animating spinner, not a determinate bar: ANE compilation
        // reports no progress, so a bar froze mid-value for ~30 s and read
        // as a hang. The fraction stays visible as digits.
        placed(VedivoxBanner(
            .neutral,
            title: progress.localizedTitle,
            message: progress.stage == .transcription ? "Compiling for the Neural Engine can take ~30 s" : nil
        ) {
            ProgressView().controlSize(.small)
        } trailing: {
            if let fraction = progress.fraction {
                Text("\(Int((fraction * 100).rounded()))%")
                    .vedivoxFont(.timecode)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
            }
        })
    }

    private func errorBanner(_ error: String) -> some View {
        placed(VedivoxBanner(.warning, title: "Could not load models", message: error) {
            Image(systemName: "exclamationmark.triangle.fill")
        } trailing: {
            Button("Retry") {
                Task { await appState.warmUpModel() }
            }
            .buttonStyle(.vedivoxProminent)
        })
    }

    private func placed(_ banner: some View) -> some View {
        banner
            .padding(.horizontal, VedivoxSpace.l)
            .padding(.top, VedivoxSpace.m)
    }
}
