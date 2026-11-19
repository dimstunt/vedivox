import AppKit
import KeyboardShortcuts
import SwiftUI

/// Manages the menu bar status item for meeting detection and recording.
@MainActor @Observable
final class MenuBarController: NSObject {
    enum State {
        case idle
        case meetingDetected(name: String)
        case recording(duration: TimeInterval)
        /// Dictation is capturing or transcribing. Separate from `.recording`,
        /// which means a meeting is being recorded.
        case dictating(isProcessing: Bool)
    }

    private(set) var state: State = .idle
    private var statusItem: NSStatusItem?
    /// The status item's current menu: the ⌘K palette offers its commands.
    var statusMenu: NSMenu? { statusItem?.menu }

    var onStartRecording: (() -> Void)?
    /// «Несколько людей на микрофоне»: starts a recording whose mic track is
    /// diarized into separate speakers (transcript-exclusion-marks, D8).
    var onStartMultiSpeakerRecording: (() -> Void)?
    var onStopRecording: (() -> Void)?
    var onKeepRecording: (() -> Void)?
    var onOpenApp: (() -> Void)?
    /// Recording-time «не в транскрипт» toggle (D6).
    var onToggleExclusion: (() -> Void)?

    /// While true the icon goes accent-red for the whole duration of the
    /// mode — the always-visible indicator is the main defence against a
    /// forgotten toggle. Set via `setExcluding`, never inferred.
    private(set) var isExcluding = false

    func setExcluding(_ active: Bool) {
        guard isExcluding != active else { return }
        isExcluding = active
        updateIcon()
        updateMenu()
    }

    /// The running recording was started in multi-speaker mode — the spec
    /// requires the mode to stay visible while recording.
    private(set) var isMultiSpeaker = false

    func setMultiSpeaker(_ active: Bool) {
        guard isMultiSpeaker != active else { return }
        isMultiSpeaker = active
        updateMenu()
    }

    /// Non-nil while the recorded meeting has ended and reminders or the auto
    /// stop are counting: the icon blinks, the title counts down, the menu
    /// leads with Keep Recording. Updated every second by the reminder loop.
    private(set) var meetingEnded: MeetingAutomation.EndedIndicator?

    func setMeetingEnded(_ indicator: MeetingAutomation.EndedIndicator?) {
        guard meetingEnded != indicator else { return }
        let menuChanges = (meetingEnded == nil) != (indicator == nil)
        meetingEnded = indicator
        updateIcon()
        if menuChanges { updateMenu() }
    }

    /// A warning about the running recording, shown first in its menu
    /// (a call track that records nothing).
    private(set) var statusLine: String?

    func setStatusLine(_ line: String?) {
        guard statusLine != line else { return }
        statusLine = line
        updateMenu()
    }

    var alwaysVisible: Bool = false {
        didSet { updateVisibility() }
    }

    func setup() {
        // Idempotent: onAppear fires again when the window is reopened —
        // a second call must not leak a second status item.
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        updateMenu()
        updateVisibility()
    }

    func teardown() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    /// The coloured icon states bake `Color.Vedivox` into the image, so a palette
    /// switch has to redraw it; the main window rebuilds on its own.
    func paletteDidChange() {
        updateIcon()
    }

    func updateState(_ newState: State) {
        state = newState
        updateIcon()
        updateMenu()
        updateVisibility()
    }

    private func updateVisibility() {
        statusItem?.isVisible = alwaysVisible || !isIdle
    }

    private var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        switch state {
        case .idle:
            // «Они» is lit only when there is a call to record.
            button.image = MenuBarGlyph.image(them: MenuBarGlyph.dimmed, lamp: .ring, label: "Vedivox")
            button.title = ""
        case .meetingDetected:
            button.image = MenuBarGlyph.image(lamp: .ring, label: "Meeting detected")
            button.title = ""
        case .recording(let duration):
            if let ended = meetingEnded, ended.highlighted {
                button.image = MenuBarGlyph.image(
                    lamp: .solid,
                    color: NSColor(Color.Vedivox.warning),
                    label: "Meeting ended, still recording"
                )
            } else if isExcluding {
                // A template image is monochrome by definition — the status bar
                // ignores contentTintColor for it, so the red is baked in.
                button.image = MenuBarGlyph.image(
                    lamp: .solid,
                    color: NSColor(Color.Vedivox.recording),
                    label: "Recording (excluded from transcript)"
                )
            } else {
                button.image = MenuBarGlyph.image(lamp: .solid, label: "Recording")
            }
            if let left = meetingEnded?.secondsLeft {
                button.title = " stop in \(left)s"
            } else {
                let m = Int(duration) / 60
                let s = Int(duration) % 60
                button.title = " \(String(format: "%d:%02d", m, s))"
            }
        case .dictating(let isProcessing):
            button.image = isProcessing
                ? MenuBarGlyph.image(lamp: .arc, label: "Transcribing")
                : MenuBarGlyph.image(them: 0, lamp: .solid, label: "Dictation")
            button.title = ""
        }
        button.contentTintColor = nil
    }

    private func updateMenu() {
        let menu = NSMenu()

        switch state {
        case .idle:
            let item = NSMenuItem(title: "No meeting detected", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(NSMenuItem.separator())
            // Manual recording must not depend on detection —
            // the callback handles a nil detection (title "Recording").
            let startItem = NSMenuItem(title: "Start Recording", action: #selector(startRecordingAction), keyEquivalent: "")
            startItem.target = self
            startItem.setShortcut(for: .toggleRecording)
            menu.addItem(startItem)
            let multiItem = NSMenuItem(
                title: "Start Recording (Multi-Speaker Mic)",
                action: #selector(startMultiSpeakerRecordingAction),
                keyEquivalent: ""
            )
            multiItem.target = self
            menu.addItem(multiItem)
        case .meetingDetected(let name):
            let nameItem = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            nameItem.isEnabled = false
            menu.addItem(nameItem)
            menu.addItem(NSMenuItem.separator())
            let startItem = NSMenuItem(title: "Start Recording", action: #selector(startRecordingAction), keyEquivalent: "")
            startItem.target = self
            startItem.setShortcut(for: .toggleRecording)
            menu.addItem(startItem)
            let multiItem = NSMenuItem(
                title: "Start Recording (Multi-Speaker Mic)",
                action: #selector(startMultiSpeakerRecordingAction),
                keyEquivalent: ""
            )
            multiItem.target = self
            menu.addItem(multiItem)
        case .recording:
            let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecordingAction), keyEquivalent: "")
            stopItem.target = self
            stopItem.setShortcut(for: .toggleRecording)
            if meetingEnded != nil {
                let keepItem = NSMenuItem(title: "Keep Recording", action: #selector(keepRecordingAction), keyEquivalent: "")
                keepItem.target = self
                menu.addItem(keepItem)
                menu.addItem(stopItem)
                menu.addItem(NSMenuItem.separator())
            }
            if let statusLine {
                let lineItem = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
                lineItem.isEnabled = false
                lineItem.image = NSImage(systemSymbolName: "speaker.slash", accessibilityDescription: nil)
                menu.addItem(lineItem)
            }
            if isMultiSpeaker {
                let modeItem = NSMenuItem(title: "Mode: Multi-Speaker Mic", action: nil, keyEquivalent: "")
                modeItem.isEnabled = false
                menu.addItem(modeItem)
            }
            let exclusionItem = NSMenuItem(
                title: "Exclude from Transcript",
                action: #selector(toggleExclusionAction),
                keyEquivalent: ""
            )
            exclusionItem.target = self
            exclusionItem.setShortcut(for: .toggleExclusion)
            exclusionItem.state = isExcluding ? .on : .off
            menu.addItem(exclusionItem)
            if meetingEnded == nil {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(stopItem)
            }
        case .dictating(let isProcessing):
            // Dictation is driven by the hotkey; the menu only reports status.
            let item = NSMenuItem(
                title: isProcessing ? "Transcribing…" : "Dictating…",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let openItem = NSMenuItem(title: "Open Vedivox", action: #selector(openAppAction), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        statusItem?.menu = menu
    }

    @objc private func startRecordingAction() {
        onStartRecording?()
    }

    @objc private func startMultiSpeakerRecordingAction() {
        onStartMultiSpeakerRecording?()
    }

    @objc private func stopRecordingAction() {
        onStopRecording?()
    }

    @objc private func keepRecordingAction() {
        onKeepRecording?()
    }

    @objc private func toggleExclusionAction() {
        onToggleExclusion?()
    }

    @objc private func openAppAction() {
        onOpenApp?()
    }
}
