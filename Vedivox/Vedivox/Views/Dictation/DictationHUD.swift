import AppKit
import SwiftUI

/// Floating indicator shown while a dictation is being recorded.
///
/// Until this, the only sign that dictation was running was macOS's own
/// microphone indicator — Vedivox itself said nothing, and the menu bar icon is not
/// where you look while talking into another app.
///
/// The panel deliberately carries no live transcript yet: showing state and
/// duration needs no model at all, so it ships ahead of streaming recognition
/// instead of queueing behind a download.
@MainActor
final class DictationHUDController {

    private var panel: NSPanel?
    private var ticker: Task<Void, Never>?
    private var model: DictationHUDModel?
    /// Where the panel is pinned for this dictation: horizontal centre and
    /// bottom edge, in screen coordinates. Captured once at show time —
    /// recomputing it on every resize is what made the panel drift sideways as
    /// the draft grew, because the pointer (and so the chosen screen) moves.
    private var anchor: (centerX: CGFloat, bottomY: CGFloat)?
    private var resizeObserver: (any NSObjectProtocol)?
    private var activationObserver: (any NSObjectProtocol)?

    /// Draft and status can arrive before the HUD exists — model loading starts
    /// before the recording does. Held here and applied on show, otherwise the
    /// first «loading» message is silently swallowed, which is exactly what
    /// happened on the first run.
    private var pendingDraft = ""
    private var pendingStatus: String?
    private var pendingWarning: String?
    private var pendingLevel: Float = 0

    /// Shows the indicator and starts the clock.
    ///
    /// A fresh panel every time, never a cached one: a panel sticks to the Space
    /// it was created on and then fails to appear over a full-screen app on any
    /// other — an open bug in openquack, whose attempts to fix it by window level
    /// and ordering are recorded as not working.
    func show() {
        hide()

        let model = DictationHUDModel()
        model.draft = pendingDraft
        model.status = pendingStatus
        model.warning = pendingWarning
        model.level = pendingLevel
        // Which app the text is heading for, kept current for as long as the HUD
        // is up. The target is settled at paste time, and switching windows
        // mid-dictation to choose the destination is deliberate behaviour — so a
        // frozen icon does not merely go stale, it says the text will land
        // somewhere it will not.
        model.targetIcon = NSWorkspace.shared.frontmostApplication?.icon
        self.model = model
        // Size comes from the content, never from a guessed rectangle.
        //
        // The first cut hardcoded 168x44 and the label still truncated to «Зап…»
        // — and the measurement below says the content only wants 133x38, so the
        // panel was already wider than needed and «too narrow» was never the
        // reason. What fixed it was denying the row any compression at all
        // (`.fixedSize()` in the view) and sizing the panel from the result.
        // The layout that truncated inside a larger panel was not explained, so
        // the numbers are logged rather than assumed.
        let hosting = NSHostingView(rootView: DictationHUDView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.layoutSubtreeIfNeeded()
        let intrinsic = hosting.intrinsicContentSize
        let fitting = hosting.fittingSize
        // Take whichever measurement actually came back: `fittingSize` alone
        // returned something too narrow on the first attempt and the label was
        // truncated to «Зап…», so the numbers get logged rather than trusted.
        let size = NSSize(
            width: max(intrinsic.width, fitting.width),
            height: max(intrinsic.height, fitting.height)
        )
        Log.info("Dictation HUD: intrinsic \(intrinsic), fitting \(fitting) → \(size)")

        let panel = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        // Without this the HUD does not show over a full-screen app — which is
        // exactly the case of dictating into a full-screen browser.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Purely informational, so it must not swallow clicks anywhere in its
        // rectangle — including the transparent padding under the shadow.
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        let anchor = Self.anchor()
        self.anchor = anchor
        panel.setFrameOrigin(Self.origin(for: size, anchor: anchor))

        // NSHostingView with .intrinsicContentSize resizes the window itself,
        // keeping the bottom-left corner fixed — so the panel grew to the right
        // as the draft arrived and the anchor set above never got a say. Re-pin
        // on every resize, whoever caused it.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak panel] _ in
            guard let panel else { return }
            MainActor.assumeIsolated {
                panel.setFrameOrigin(Self.origin(for: panel.frame.size, anchor: anchor))
            }
        }

        // Follow the focus. `NSWorkspace`'s own centre, not the default one:
        // application activation is posted there and nowhere else. Safe to
        // observe for the whole dictation precisely because the panel is
        // non-activating — it never fires on account of the HUD itself.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak model] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                model?.targetIcon = app?.icon ?? NSWorkspace.shared.frontmostApplication?.icon
            }
            // Info, not debug: this is how the icon gets verified without a
            // screenshot, and it only fires while a HUD is actually up.
            Log.info("Dictation HUD: target is now \(app?.localizedName ?? "unknown")")
        }

        // orderFrontRegardless, never makeKeyAndOrderFront: the app the user is
        // dictating into must stay active, or the paste at the end lands in the
        // wrong place — or nowhere.
        panel.orderFrontRegardless()
        self.panel = panel

        let startedAt = CFAbsoluteTimeGetCurrent()
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                model.elapsed = CFAbsoluteTimeGetCurrent() - startedAt
                // The clock gets wider when the label crosses ten minutes or an
                // hour, and the panel is not resized by the hosting view alone.
                // Keeping it in step here also serves the live transcript later.
                let wanted = hosting.intrinsicContentSize
                let current = panel.frame.size
                if wanted.width > 0, wanted.height > 0,
                   abs(wanted.width - current.width) > 0.5 || abs(wanted.height - current.height) > 0.5,
                   let anchor = self.anchor {
                    // Re-anchor rather than re-place: the panel grows evenly to
                    // both sides and its bottom edge stays put.
                    panel.setContentSize(wanted)
                    panel.setFrameOrigin(Self.origin(for: wanted, anchor: anchor))
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        Log.info("Dictation HUD: shown")
    }

    /// Hides the indicator. Called when recording ends — the HUD does not
    /// outlive the recording, so anything that happens after (a failed paste)
    /// needs its own channel.
    /// Shows the draft transcript as it grows. Ignored when no HUD is up.
    func update(draft: String) {
        pendingDraft = draft
        model?.draft = draft
    }

    /// Explains the missing draft — a model still downloading, or unavailable.
    /// The HUD is the only surface that reaches the user here: the main window
    /// banner is useless during dictation because the window is closed.
    func update(status: String?) {
        pendingStatus = status
        model?.status = status
    }

    /// Something wrong with this dictation itself, not with the draft — shown
    /// whatever the draft says, and only for the dictation it was raised in.
    func update(warning: String?) {
        pendingWarning = warning
        model?.warning = warning
    }

    /// Microphone level, 0…1. Bars that move with the voice answer the question
    /// the clock cannot: whether the microphone is hearing anything at all.
    func update(level: Float) {
        pendingLevel = level
        model?.level = level
    }

    func hide() {
        ticker?.cancel()
        ticker = nil
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        resizeObserver = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        model = nil
        anchor = nil
        pendingDraft = ""
        pendingLevel = 0
        pendingWarning = nil
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        Log.info("Dictation HUD: hidden")
    }

    /// Bottom centre of the screen the user is actually looking at, clear of
    /// the Dock.
    ///
    /// Picked by pointer location rather than `NSScreen.main`: with an external
    /// display, dictating on the second screen would otherwise put the HUD on
    /// the first one.
    ///
    /// Centred on `frame`, not `visibleFrame`: with the Dock on a side, the
    /// visible rectangle is off-centre and the HUD would sit visibly askew.
    private static func anchor() -> (centerX: CGFloat, bottomY: CGFloat) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return (0, 0) }
        return (screen.frame.midX, screen.visibleFrame.minY + 96)
    }

    private static func origin(for size: NSSize, anchor: (centerX: CGFloat, bottomY: CGFloat)) -> NSPoint {
        NSPoint(x: anchor.centerX - size.width / 2, y: anchor.bottomY)
    }
}

/// `NSPanel` becomes key by default — that is a separate axis from
/// `.nonactivatingPanel` in the style mask, so both have to be denied
/// explicitly for the HUD to never take focus.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Internal rather than private so `VedivoxTests` can render the panel at known
/// states — see `DictationHUDSnapshotTests`.
@MainActor
@Observable
final class DictationHUDModel {
    var elapsed: TimeInterval = 0
    /// Smoothed microphone level, 0…1.
    var level: Float = 0
    /// Icon of the app the text is currently heading for — the frontmost one,
    /// re-read whenever focus moves during the dictation.
    var targetIcon: NSImage?
    /// Draft transcript — explicitly NOT what will be pasted, see
    /// `DictationLiveTranscriber`. Empty until the recogniser produces its first
    /// chunk, which takes as long as the configured chunk size.
    var draft: String = ""
    /// Why there is no draft yet, when there is a reason worth showing.
    var status: String?
    /// A degraded dictation the user should know about (Escape not captured).
    var warning: String?
}

/// Note for whoever extends this: `.onHover` and `.help()` do not work at all on
/// a non-activating panel — an `NSTrackingArea` on a dedicated view is the only
/// route if hovering ever becomes necessary.
struct DictationHUDView: View {
    let model: DictationHUDModel

    /// Width of everything below the status row. Fixed, not adaptive: a panel
    /// that resizes with every word jitters.
    private static let bodyWidth: CGFloat = 360

    var body: some View {
        // The status row is much narrower than the body, so on a panel sized by
        // the body it sat against the left edge with a hand's width of nothing
        // beside it. Centring it needs an explicit width: `.fixedSize()` below
        // proposes nil to its children, and `maxWidth: .infinity` under a nil
        // proposal resolves to the ideal width — that is, to no expansion at all.
        //
        // Only while there *is* a body: on a bare status row the panel is barely
        // wider than the row itself, and forcing it to 360 would stretch the
        // panel for nothing.
        let hasBody = !model.draft.isEmpty || model.status != nil || model.warning != nil

        VStack(alignment: .leading, spacing: VedivoxSpace.s) {
            statusRow
                .frame(width: hasBody ? Self.bodyWidth : nil)
            if let warning = model.warning {
                Text(warning)
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.warning)
                    .lineLimit(2)
                    .frame(width: Self.bodyWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = model.status, model.draft.isEmpty {
                Text(status)
                    .vedivoxFont(.caption)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                    .lineLimit(1)
                    .frame(width: Self.bodyWidth, alignment: .leading)
            }
            if !model.draft.isEmpty {
                // Italic and dimmed: the convention for text the system is still
                // working out. The spec requires the draft to read as provisional,
                // because what actually gets pasted comes from a better model and
                // will differ in places.
                Text(model.draft)
                    .vedivoxFont(.caption)
                    .italic()
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                    .lineLimit(2, reservesSpace: true)
                    // Head truncation keeps the newest words visible — the tail
                    // is what the user is saying right now.
                    .truncationMode(.head)
                    // Left-aligned even though the row above is centred: centred
                    // multi-line text gives the eye no fixed edge to return to,
                    // and the second line would shift sideways on every update.
                    // Vertical fixedSize lets the two lines claim their height
                    // instead of being clipped mid-glyph.
                    .frame(width: Self.bodyWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Refuse to compress below the ideal size: without this the hosting view
        // hands the row whatever width the panel happens to have, and the label
        // truncates instead of the panel growing.
        .fixedSize()
        .padding(.horizontal, VedivoxSpace.xl)
        .padding(.vertical, VedivoxSpace.l)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: VedivoxRadius.l))
        .overlay(RoundedRectangle(cornerRadius: VedivoxRadius.l).strokeBorder(Color.Vedivox.line))
    }

    private var statusRow: some View {
        HStack(spacing: VedivoxSpace.m) {
            if let icon = model.targetIcon {
                // Where the text is heading. Worth the space precisely because
                // the target is chosen at paste time — this is the only place
                // the user sees it before the text lands.
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: VedivoxRadius.xs))
            }

            LevelBars(level: model.level)

            Text("Recording")
                .vedivoxFont(.label)
                .foregroundStyle(Color.Vedivox.fg)
                .lineLimit(1)

            Text(ElapsedTimeLabel.text(for: model.elapsed))
                .vedivoxFont(.tabular)
                .foregroundStyle(Color.Vedivox.fgSecondary)
                .lineLimit(1)
        }
    }
}

/// Microphone level as a row of bars, tallest in the middle.
///
/// Replaces a pulsing dot, which could only say «recording». Silence and a dead
/// microphone look identical on a dot; on bars they do not.
private struct LevelBars: View {
    let level: Float

    private static let count = 7
    private static let barWidth: CGFloat = 2.5
    private static let maxHeight: CGFloat = 15
    private static let minHeight: CGFloat = 3

    var body: some View {
        HStack(alignment: .center, spacing: VedivoxSpace.xxs) {
            ForEach(0 ..< Self.count, id: \.self) { index in
                Capsule()
                    .fill(Color.Vedivox.recording)
                    .frame(width: Self.barWidth, height: height(at: index))
                    .animation(.easeOut(duration: 0.09), value: level)
            }
        }
        .frame(height: Self.maxHeight)
    }

    /// Bars fall off from the centre, so the row reads as a voice rather than a
    /// bar chart. `pow(0.6)` lifts quiet speech into visible territory — a
    /// linear mapping leaves normal talking barely off the floor.
    private func height(at index: Int) -> CGFloat {
        let middle = Double(Self.count - 1) / 2
        let distance = abs(Double(index) - middle) / middle
        let falloff = 1 - distance * 0.55
        let amplified = pow(Double(max(level, 0)), 0.6)
        return Self.minHeight + (Self.maxHeight - Self.minHeight) * amplified * falloff
    }
}
