import AppKit
import CoreServices

/// What Settings → Privacy & Permissions shows per grant: one mark,
/// a caption whose first words name the status, and one button.
enum PermissionFacts {
    enum Grant: Equatable {
        /// `notAsked`: macOS has not asked yet; `unknown`: macOS does not say.
        case allowed, refused, notAsked, unknown

        /// The first words of the caption; unknown has its own wording per row.
        var word: String? {
            switch self {
            case .allowed: "Allowed."
            case .refused: "Not allowed."
            case .notAsked: "Not asked yet."
            case .unknown: nil
            }
        }
    }

    struct Row: Equatable {
        let grant: Grant
        let caption: String

        /// The status word, then what the grant is for.
        init(_ grant: Grant, purpose: String) {
            self.init(grant: grant, caption: [grant.word, purpose].compactMap { $0 }.joined(separator: " "))
        }

        init(grant: Grant, caption: String) {
            self.grant = grant
            self.caption = caption
        }
    }

    /// Every row has one; not asked and unknown share the neutral mark so
    /// neither reads as a refusal.
    enum Mark: Equatable {
        case allowed, refused, neutral

        var symbol: String {
            switch self {
            case .allowed: "checkmark.circle.fill"
            case .refused: "xmark.circle.fill"
            case .neutral: "questionmark.circle"
            }
        }

        var help: String {
            switch self {
            case .allowed: "Allowed"
            case .refused: "Not allowed"
            case .neutral: "Not asked yet, or macOS does not say"
            }
        }
    }

    static func mark(_ grant: Grant) -> Mark {
        switch grant {
        case .allowed: .allowed
        case .refused: .refused
        case .notAsked, .unknown: .neutral
        }
    }

    enum Action: Equatable {
        /// Show macOS's own prompt — on a click only, never on opening the screen.
        case ask
        /// Find the grant out by trying it (system audio): shows macOS's
        /// prompt if it never asked, and confirms the grant if it did.
        case check
        case openSettings
    }

    /// `canAsk`: macOS can prompt for this grant itself (microphone, calendars,
    /// notifications). Before the first answer a click asks; after it, System
    /// Settings is the only place to change it — and an app that never asked
    /// may not even be listed there. `canCheck`: Vedivox can try the grant
    /// while macOS does not say (system audio, not during a recording).
    static func action(_ grant: Grant, canAsk: Bool, canCheck: Bool = false) -> Action {
        if grant == .notAsked, canAsk { return .ask }
        if grant == .unknown, canCheck { return .check }
        return .openSettings
    }

    // MARK: - Calendars

    static let calendarsPurpose = "Names a detected meeting after its calendar event."

    /// The status sentence, shared by Privacy and Settings → Meetings. Checked
    /// calendars without access (settings carried over from Vox, say) are said // rename:keep
    /// out loud: the feature looks on and does nothing.
    static func calendarStatus(_ grant: Grant, checked: Int) -> String {
        let word = grant.word ?? ""
        guard checked > 0, grant != .allowed else { return word }
        let calendars = checked == 1 ? "1 calendar is" : "\(checked) calendars are"
        return "\(word) \(calendars) checked for meeting titles, but Vedivox cannot read \(checked == 1 ? "it" : "them")."
    }

    static func calendars(_ grant: Grant, checked: Int) -> Row {
        Row(grant: grant, caption: calendarStatus(grant, checked: checked) + " " + calendarsPurpose)
    }

    // MARK: - System audio

    static let systemAudioPurpose = "The other participants."

    /// When a recording of this install last heard sound on the system track.
    /// Kept in this app's own settings, never carried over from the old
    /// identifier (`LegacySettings.leftBehind`): macOS grants the permission
    /// per app, and a Vox recording proves nothing for Vedivox. // rename:keep
    static let systemAudioHeardKey = "systemAudioHeardAt"

    /// Called by the processing of a recording just made, once the system
    /// track's stats say it sounded: zeros are what a refusal records.
    static func noteSystemAudioHeard(_ defaults: UserDefaults = .standard, at date: Date = Date()) {
        defaults.set(date, forKey: systemAudioHeardKey)
    }

    static func systemAudio(_ defaults: UserDefaults = .standard, now: Date = Date(), check: SystemAudioCheck? = nil) -> Row {
        let heard = defaults.object(forKey: systemAudioHeardKey) as? Date
        return systemAudio(lastCapture: heard.flatMap { now.timeIntervalSince($0) < 30 * 86400 ? $0 : nil }, check: check)
    }

    /// No public API reads the Screen & System Audio Recording grant, so the
    /// proof is sound heard in the last 30 days — by a recording or by a check.
    static func systemAudio(lastCapture: Date?, check: SystemAudioCheck? = nil) -> Row {
        if let lastCapture {
            let day = lastCapture.formatted(date: .abbreviated, time: .omitted)
            return Row(grant: .allowed, caption: "Allowed. Vedivox heard system audio on \(day). " + systemAudioPurpose)
        }
        if let hint = check.flatMap(systemAudioHint) {
            return Row(grant: .unknown, caption: "Not confirmed yet. " + hint)
        }
        return Row(grant: .unknown, caption: "Not confirmed yet. The other participants; macOS does not report it. Check asks macOS and listens for a second — play any sound first; a recording that hears them confirms it too.")
    }

    /// What a check of the system-audio grant found.
    enum SystemAudioCheck: Equatable, Sendable {
        /// A non-zero sample: the grant is on.
        case heard
        /// Only zeros: nothing was playing, or the grant is off — macOS
        /// gives both the same way.
        case silent
        /// Core Audio refused to build or start the capture.
        case failed(OSStatus)
    }

    static let systemAudioSettingsPath = "System Settings → Privacy & Security → Screen & System Audio Recording"

    /// The words under a check that confirmed nothing, shared by the welcome
    /// wizard and Settings → Privacy. Nil when there is nothing to explain.
    static func systemAudioHint(_ check: SystemAudioCheck) -> String? {
        switch check {
        case .heard:
            nil
        case .silent:
            "Nothing was playing, so Vedivox heard only silence and cannot tell yet. If you clicked Allow, there is nothing more to do: the first recording with sound confirms it. To check now, play any sound and check again. If you clicked Don\u{2019}t Allow, turn Vedivox on in \(systemAudioSettingsPath)."
        case .failed(let status):
            "macOS did not start system audio capture (error \(status)). Check that Vedivox is on in \(systemAudioSettingsPath)."
        }
    }

    /// Runs the check and keeps a heard sound as the proof the Privacy row reads.
    static func checkSystemAudio(_ defaults: UserDefaults = .standard) async -> SystemAudioCheck {
        let result = await SystemAudioCapture.check()
        Log.info("System audio check: \(result)")
        if result == .heard { noteSystemAudioHeard(defaults) }
        return result
    }

    // MARK: - Automation

    enum Answer: Equatable {
        case allowed, refused, notAsked, notRunning, unknown(OSStatus)

        init(_ status: OSStatus) {
            switch status {
            case OSStatus(noErr): self = .allowed
            case OSStatus(errAEEventNotPermitted): self = .refused
            case OSStatus(errAEEventWouldRequireUserConsent): self = .notAsked
            case OSStatus(procNotFound): self = .notRunning
            default: self = .unknown(status)
            }
        }
    }

    static let automationPurpose = "Lets meeting detection read browser tabs to find Google Meet and Telemost calls. macOS asks once per browser."

    /// One line over the browsers, e.g. "Allowed for Chrome, Arc · Safari not
    /// asked yet". Allowed needs every running browser allowed and at least
    /// one of them; a refusal anywhere is a refusal.
    static func automation(_ answers: [(browser: String, answer: Answer)]) -> Row {
        guard let line = automationLine(answers) else {
            return Row(grant: .unknown, caption: "Unknown: no supported browser is running, so macOS cannot say. " + automationPurpose)
        }
        let has = { (match: (Answer) -> Bool) in answers.contains { match($0.answer) } }
        let grant: Grant = has { $0 == .refused } ? .refused
            : has { if case .unknown = $0 { true } else { false } } ? .unknown
            : has { $0 == .notAsked } ? .notAsked
            : .allowed
        return Row(grant: grant, caption: line + ". " + automationPurpose)
    }

    /// The welcome wizard's line after asking: what macOS answered
    /// for the open browsers, and which ones it will ask later.
    static func automationAsked(_ answers: [(browser: String, answer: Answer)]) -> String {
        let closed = answers.filter { $0.answer == .notRunning }.map(\.browser)
        let line = automationLine(answers).map { $0 + "." } ?? "No supported browser is open."
        guard !closed.isEmpty else { return line }
        let tabs = closed.count == 1 ? "its" : "their"
        return line + " \(closed.joined(separator: ", ")): not open, so macOS asks the first time Vedivox looks at \(tabs) tabs."
    }

    /// "Allowed for Chrome, Arc · Safari not asked yet"; nil when no browser is running.
    private static func automationLine(_ answers: [(browser: String, answer: Answer)]) -> String? {
        func names(_ match: (Answer) -> Bool) -> String? {
            let list = answers.filter { match($0.answer) }.map(\.browser)
            return list.isEmpty ? nil : list.joined(separator: ", ")
        }
        let allowed = names { $0 == .allowed }
        let refused = names { $0 == .refused }
        let notAsked = names { $0 == .notAsked }
        let unknown = names {
            if case .unknown = $0 {
                true
            } else {
                false
            }
        }
        let parts = [
            allowed.map { "Allowed for \($0)" },
            refused.map { "not allowed for \($0)" },
            notAsked.map { "\($0) not asked yet" },
            unknown.map { "\($0) unknown" },
        ].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        let line = parts.joined(separator: " · ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// Asks macOS per browser. `ask` false never prompts: it returns
    /// errAEEventWouldRequireUserConsent instead (AppleEvents.h). `ask` true
    /// shows the prompt for each open browser not answered yet, one after
    /// another, and waits for each answer — a browser that is not open cannot
    /// be asked. The call blocks, so never on the main thread.
    static func readAutomation(ask: Bool = false) async -> [(browser: String, answer: Answer)] {
        await Task.detached(priority: ask ? .userInitiated : .utility) {
            BrowserTabDetector.browsers.map { browser in
                var target = AEAddressDesc()
                let bundleId = browser.bundleId
                let created = bundleId.withCString { pointer in
                    AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target)
                }
                guard created == 0 else { return (browser.name, .unknown(OSStatus(created))) }
                defer { AEDisposeDesc(&target) }
                let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
                return (browser.name, Answer(status))
            }
        }.value
    }
}

extension PermissionFacts.Grant {
    init(_ calendar: CalendarService.AuthStatus) {
        switch calendar {
        case .authorized: self = .allowed
        case .notDetermined: self = .notAsked
        case .denied: self = .refused
        }
    }
}
