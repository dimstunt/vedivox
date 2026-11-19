import AppKit
import SwiftUI

/// Asks for a GitHub star once, after the fifth processed meeting (StarPrompt).
/// Either button retires it for good.
struct StarBanner: View {
    @Environment(AppState.self) private var appState
    @AppStorage(StarPrompt.dismissedKey) private var dismissed = false

    var body: some View {
        if StarPrompt.shouldShow(
            processedMeetings: appState.meetings.lazy.filter { $0.status == .done }.count,
            dismissed: dismissed,
            busy: appState.recordingVM.isRecording || appState.recordingVM.isProcessing
                || appState.meetings.contains { $0.status.isInProgress }
        ) {
            VedivoxBanner(
                .neutral,
                title: "Vedivox is free and open source",
                message: "If it helps you, a star helps others find it."
            ) {
                Image(systemName: "star")
            } trailing: {
                HStack(spacing: VedivoxSpace.s) {
                    Button("Not Now") { dismissed = true }
                        .buttonStyle(.vedivoxGhost)
                    Button("Star on GitHub") {
                        NSWorkspace.shared.open(VedivoxLinks.repository)
                        dismissed = true
                    }
                    .buttonStyle(.vedivoxProminent)
                }
            }
            .padding(.horizontal, VedivoxSpace.l)
            .padding(.top, VedivoxSpace.m)
        }
    }
}
