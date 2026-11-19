import AppKit
import SwiftUI

/// Banner shown during recording when the system-audio tap couldn't start, so
/// the user knows they're getting a mic-only recording and how to fix it
/// Before this the failure was logged and swallowed. Also when
/// the tap runs but records only zeros while a call plays, and
/// when the call comes through chopped and rebuilding the tap did not help.
struct SystemAudioWarningBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.recordingVM.isRecording, appState.recordingVM.systemAudioUnavailable {
            VedivoxBanner(
                .warning,
                title: "System audio is not being recorded",
                message: "Only the microphone is being recorded. Allow screen and system audio recording in System Settings."
            ) {
                Image(systemName: "speaker.slash.fill")
            } trailing: {
                settingsButton
            }
            .padding(.horizontal, VedivoxSpace.l)
            .onAppear { Log.info("Banner appeared: system audio unavailable") }
        } else if appState.recordingVM.isRecording, appState.recordingVM.systemAudioSilent {
            VedivoxBanner(.warning, title: SilentCallTrack.bannerTitle, message: SilentCallTrack.bannerMessage) {
                Image(systemName: "speaker.slash.fill")
            } trailing: {
                settingsButton
            }
            .padding(.horizontal, VedivoxSpace.l)
            .onAppear { Log.info("Banner appeared: call track silent") }
        } else if appState.recordingVM.isRecording, appState.recordingVM.systemAudioChopped {
            VedivoxBanner(.warning, title: TapChopDetector.bannerTitle, message: TapChopDetector.bannerMessage) {
                Image(systemName: "waveform.badge.exclamationmark")
            }
            .padding(.horizontal, VedivoxSpace.l)
            .onAppear { Log.info("Banner appeared: call audio chopped") }
        }
    }

    private var settingsButton: some View {
        Button("Settings") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        .buttonStyle(.vedivoxGhost)
    }
}
