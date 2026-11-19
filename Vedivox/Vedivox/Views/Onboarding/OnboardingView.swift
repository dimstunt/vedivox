import ApplicationServices
import AVFoundation
import SwiftUI

/// First-launch welcome wizard. Walks the user through the two
/// recording permissions (microphone, system audio) and an opt-in for meeting
/// detection, then hands off to `AppState.completeOnboarding`. Shown as a modal
/// overlay while `appState.showOnboarding` is true.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState

    enum Step: Int, CaseIterable {
        case welcome, microphone, systemAudio, accessibility, detection
    }

    @State private var step: Step = .welcome
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    /// Starts from the proof a recording of this install left.
    @State private var systemAudioGranted = PermissionFacts.systemAudio().grant == .allowed
    @State private var systemAudioCheck: PermissionFacts.SystemAudioCheck?
    @State private var checkingSystemAudio = false
    @State private var automationAnswer: String?
    @State private var askingAutomation = false
    @State private var accessibilityRequested = false
    @State private var accessibilityGranted = AXIsProcessTrusted()
    /// Starts from the stored choice: someone who came over from the app's old
    /// name sees this wizard again for the permissions, not to be opted out.
    @State private var enableDetection = UserDefaults.standard.bool(forKey: "meetingDetectionEnabled")

    var body: some View {
        ZStack {
            Color.Vedivox.scrim.ignoresSafeArea()
            card
        }
    }

    private var card: some View {
        VStack(spacing: VedivoxSpace.xxl) {
            content
        }
        .frame(width: 460)
        .padding(VedivoxSpace.xxxl)
        .background(Color.Vedivox.bgCard, in: RoundedRectangle(cornerRadius: VedivoxRadius.l))
        .overlay(RoundedRectangle(cornerRadius: VedivoxRadius.l).strokeBorder(Color.Vedivox.line))
        .shadow(radius: 30) // shadow-modal
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .microphone: microphoneStep
        case .systemAudio: systemAudioStep
        case .accessibility: accessibilityStep
        case .detection: detectionStep
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: VedivoxSpace.xl) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.Vedivox.accentText)
            Text("Welcome to Vedivox")
                .vedivoxFont(.header)
                .foregroundStyle(Color.Vedivox.fg)
            Text("Vedivox records meetings, transcribes speech, and separates speakers — entirely on your Mac, no cloud.")
                .vedivoxFont(.body)
                .foregroundStyle(Color.Vedivox.fgSecondary)
                .multilineTextAlignment(.center)
            Text("Next up: a couple of permissions to make everything work.")
                .vedivoxFont(.row)
                .foregroundStyle(Color.Vedivox.fgSecondary)
                .multilineTextAlignment(.center)
            Button("Get Started") { advance() }
                .buttonStyle(.vedivoxProminent)
                .padding(.top, VedivoxSpace.xs)
        }
    }

    private var microphoneStep: some View {
        stepScaffold(
            icon: "mic.fill",
            title: "Microphone",
            text: "Needed to record your voice during meetings."
        ) {
            VStack(spacing: VedivoxSpace.l) {
                if micStatus == .authorized {
                    Label("Microphone allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.Vedivox.success)
                } else {
                    Button("Allow Microphone") {
                        Task {
                            let ok = await AVCaptureDevice.requestAccess(for: .audio)
                            micStatus = ok ? .authorized : AVCaptureDevice.authorizationStatus(for: .audio)
                        }
                    }
                    .buttonStyle(.vedivoxProminent)
                }
                if micStatus == .denied {
                    hint("Access denied. Enable Vedivox in System Settings → Privacy & Security → Microphone.")
                    // macOS asks only once: after a refusal the switch is there (#6).
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.vedivoxGhost)
                }
            }
        }
    }

    private var systemAudioStep: some View {
        stepScaffold(
            icon: "speaker.wave.2.fill",
            title: "System Audio",
            text: "Needed to record other participants from Zoom, Meet, and other apps. Vedivox listens for a second, so macOS asks now and not at your first meeting."
        ) {
            VStack(spacing: VedivoxSpace.l) {
                if systemAudioGranted {
                    Label("System audio allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.Vedivox.success)
                } else if checkingSystemAudio {
                    ProgressView().controlSize(.small)
                    hint("If macOS asks, click Allow.")
                } else {
                    if systemAudioCheck != nil {
                        Label("Not confirmed yet", systemImage: "questionmark.circle")
                            .foregroundStyle(Color.Vedivox.fgSecondary)
                    }
                    Button(systemAudioCheck == nil ? "Allow System Audio" : "Check Again") { checkSystemAudio() }
                        .buttonStyle(.vedivoxProminent)
                        // A recording proves it better, and the check must not run next to one.
                        .disabled(appState.recordingVM.isRecording)
                    if let text = systemAudioCheck.flatMap(PermissionFacts.systemAudioHint) {
                        hint(text)
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.vedivoxGhost)
                    }
                }
            }
        }
    }

    private func checkSystemAudio() {
        checkingSystemAudio = true
        Task {
            let result = await PermissionFacts.checkSystemAudio()
            systemAudioCheck = result
            systemAudioGranted = result == .heard
            checkingSystemAudio = false
        }
    }

    private var accessibilityStep: some View {
        stepScaffold(
            icon: "accessibility",
            title: "Accessibility",
            text: "Lets dictation type text into other apps, and lets Vedivox see when you are muted in Zoom so what you say off the call stays out of the transcript."
        ) {
            VStack(spacing: VedivoxSpace.l) {
                if accessibilityGranted {
                    Label("Accessibility allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.Vedivox.success)
                } else {
                    Button(accessibilityRequested ? "Check Again" : "Allow Accessibility") {
                        // The value of kAXTrustedCheckOptionPrompt; Swift 6 rejects the global itself.
                        let prompt = "AXTrustedCheckOptionPrompt"
                        accessibilityGranted = AXIsProcessTrustedWithOptions(
                            [prompt: !accessibilityRequested] as CFDictionary
                        )
                        accessibilityRequested = true
                    }
                    .buttonStyle(.vedivoxProminent)
                    if accessibilityRequested {
                        hint("Enable Vedivox in System Settings → Privacy & Security → Accessibility, then press “Check Again”. Dictation may need a Vedivox restart to pick it up.")
                    }
                }
            }
        }
    }

    private var detectionStep: some View {
        stepScaffold(
            icon: "bell.badge.fill",
            title: "Call auto-detection",
            text: "Vedivox can notice calls starting in Zoom, Meet, and Slack and offer to record. This needs notifications and access to browser tabs — enable if you want it."
        ) {
            VStack(spacing: VedivoxSpace.l) {
                Toggle("Detect calls automatically", isOn: $enableDetection)
                    .toggleStyle(.switch)
                    .tint(Color.Vedivox.accent)
                if enableDetection {
                    // Otherwise the question comes up the first time detection
                    // looks at a browser — on 2026-11-17, an hour into the evening.
                    hint("macOS asks once per browser whether Vedivox may read its tabs, and only while that browser is open — so the question can pop up during a call. Ask now for the open ones:")
                    if let automationAnswer { hint(automationAnswer) }
                    Button(askingAutomation ? "Waiting for macOS…" : "Ask Now") { askAutomation() }
                        .buttonStyle(.vedivoxGhost)
                        .disabled(askingAutomation)
                }
            }
        }
    }

    private func askAutomation() {
        askingAutomation = true
        Task {
            automationAnswer = PermissionFacts.automationAsked(await PermissionFacts.readAutomation(ask: true))
            askingAutomation = false
        }
    }

    // MARK: - Scaffolding

    private func stepScaffold(
        icon: String,
        title: String,
        text: String,
        @ViewBuilder action: () -> some View
    ) -> some View {
        VStack(spacing: VedivoxSpace.xl) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(Color.Vedivox.accentText)
            Text(title)
                .vedivoxFont(.title)
                .foregroundStyle(Color.Vedivox.fg)
            Text(text)
                .vedivoxFont(.body)
                .foregroundStyle(Color.Vedivox.fgSecondary)
                .multilineTextAlignment(.center)
            action()
            navRow.padding(.top, VedivoxSpace.m)
        }
    }

    private var navRow: some View {
        HStack {
            Button("Back") { back() }
                .buttonStyle(.vedivoxGhost)
            Spacer()
            Button(step == .detection ? "Done" : "Next") { advance() }
                .buttonStyle(.vedivoxProminent)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .vedivoxFont(.caption)
            .foregroundStyle(Color.Vedivox.fgSecondary)
            .multilineTextAlignment(.center)
    }

    // MARK: - Navigation

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
        } else {
            Task { await appState.completeOnboarding(enableDetection: enableDetection) }
        }
    }

    private func back() {
        if let prev = Step(rawValue: step.rawValue - 1) {
            step = prev
        }
    }
}
