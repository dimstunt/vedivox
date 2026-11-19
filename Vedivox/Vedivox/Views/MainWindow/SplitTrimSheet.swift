import SwiftUI

/// Split / Trim modal (SplitModal from the design bundle):
/// waveform with a draggable cut marker (split) or keep-range handles (trim)
/// plus a live preview of the resulting parts. Backend is the existing
/// `AppState.splitMeeting` / `trimMeeting`; per-segment fine-tuning is still
/// available via the transcript context menu («Разделить здесь»).
struct SplitTrimSheet: View {
    let meeting: Meeting
    @Bindable var viewModel: MeetingDetailViewModel
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable {
        case split = "Split"
        case trim = "Trim"
    }

    /// The Trim bound the arrow keys move.
    private enum TrimEdge: String, CaseIterable {
        case start = "Start"
        case end = "End"
    }

    @State private var mode: Mode
    @State private var splitTime: Double
    @State private var trimFrom: Double
    @State private var trimTo: Double
    @State private var trimEdge: TrimEdge = .start

    private let duration: Double

    init(meeting: Meeting, viewModel: MeetingDetailViewModel, mode: Mode = .split) {
        self.meeting = meeting
        _mode = State(initialValue: mode)
        self.viewModel = viewModel
        let d = meeting.durationSeconds ?? viewModel.segments.last?.endTime ?? 0
        duration = d
        let playhead = viewModel.playback.currentTime
        _splitTime = State(initialValue: SplitCutPoint.initial(
            playhead: playhead, segmentStarts: viewModel.segments.map(\.startTime).sorted(), duration: d
        ))
        _trimFrom = State(initialValue: 0)
        _trimTo = State(initialValue: d)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(mode == .split ? "Split Recording" : "Trim Recording")
                .vedivoxFont(.title)
                .foregroundStyle(Color.Vedivox.fg)
                .padding(.bottom, VedivoxSpace.l)

            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.bottom, VedivoxSpace.m)

            Text(mode == .split
                 ? "Click the waveform to place the cut point. ← → move it by a second, ⌥← ⌥→ by a segment. Each part becomes a separate meeting."
                 : "Set the bounds — everything outside is deleted along with its segments. ← → move the chosen bound by a second, ⌥← ⌥→ by a segment, Tab switches between Start and End.")
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)
                .padding(.bottom, VedivoxSpace.l)

            timeline
                .padding(.bottom, VedivoxSpace.xs)

            HStack {
                Text(WaveformView.formatTime(0))
                Spacer()
                Text(WaveformView.formatTime(duration / 2))
                Spacer()
                Text(WaveformView.formatTime(duration))
            }
            .vedivoxFont(.timecode)
            .foregroundStyle(Color.Vedivox.fgSecondary)
            .padding(.bottom, VedivoxSpace.l)

            if mode == .trim {
                trimSliders
                    .padding(.bottom, VedivoxSpace.s)
                trimNudges
                    .padding(.bottom, VedivoxSpace.l)
            } else {
                splitNudges
                    .padding(.bottom, VedivoxSpace.l)
            }

            preview

            Spacer(minLength: 16)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.vedivoxGhost)
                    .keyboardShortcut(.cancelAction)
                Button(applyTitle) {
                    apply()
                }
                .buttonStyle(.vedivoxProminent)
                .disabled(!canApply)
            }
        }
        .padding(VedivoxSpace.xxl)
        .frame(width: 560, height: 430)
        .background(Color.Vedivox.bgCard)
    }

    // MARK: - Timeline

    private var timeline: some View {
        ZStack(alignment: .topLeading) {
            WaveformView(
                peaks: viewModel.waveformPeaks?.peaks(for: .mix) ?? [],
                hues: [],
                currentTime: 0,
                duration: duration,
                onSeek: { t in
                    switch mode {
                    case .split:
                        splitTime = clamp(t, 1, duration - 1)
                    case .trim:
                        // Move whichever handle is closer to the click.
                        if abs(t - trimFrom) <= abs(t - trimTo) {
                            trimFrom = clamp(t, 0, trimTo - 1)
                            trimEdge = .start
                        } else {
                            trimTo = clamp(t, trimFrom + 1, duration)
                            trimEdge = .end
                        }
                    }
                },
                height: 64
            )

            GeometryReader { geo in
                if mode == .split {
                    marker(at: splitTime, in: geo.size, color: Color.Vedivox.accentText)
                } else {
                    // Dim the discarded ends, mark the keep-range boundaries.
                    let fromX = x(of: trimFrom, in: geo.size)
                    let toX = x(of: trimTo, in: geo.size)
                    Rectangle()
                        .fill(Color.Vedivox.bg.opacity(0.72))
                        .frame(width: max(0, fromX), height: geo.size.height)
                    Rectangle()
                        .fill(Color.Vedivox.bg.opacity(0.72))
                        .frame(width: max(0, geo.size.width - toX), height: geo.size.height)
                        .offset(x: toX)
                    // The bound the keys move is drawn like Split's cut.
                    marker(at: trimFrom, in: geo.size, color: trimEdge == .start ? Color.Vedivox.accentText : Color.Vedivox.success)
                    marker(at: trimTo, in: geo.size, color: trimEdge == .end ? Color.Vedivox.accentText : Color.Vedivox.success)
                }
            }
            .allowsHitTesting(false)
        }
        .frame(height: 64)
    }

    // The line and the time badge are positioned independently: a shared
    // VStack + offset would shift the line right by half the badge width
    // (the "markers drift right" bug).
    private func marker(at time: Double, in size: CGSize, color: Color) -> some View {
        let posX = x(of: time, in: size)
        let badgeHalfWidth: CGFloat = 24
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(color)
                .frame(width: 2, height: size.height)
                .offset(x: posX - 1)
            Text(WaveformView.formatTime(time))
                .vedivoxFont(.timecode)
                .foregroundStyle(Color.Vedivox.fg)
                .padding(.horizontal, VedivoxSpace.xs)
                .padding(.vertical, VedivoxSpace.xxs)
                .background(Color.Vedivox.bgActive, in: RoundedRectangle(cornerRadius: VedivoxRadius.xs))
                .fixedSize()
                .position(
                    x: min(max(posX, badgeHalfWidth), size.width - badgeHalfWidth),
                    y: 9
                )
        }
    }

    private func x(of time: Double, in size: CGSize) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * size.width
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }

    // MARK: - Split nudges

    /// Fine moves of the cut without the mouse: a second, or to the
    /// neighbouring segment start — cuts usually belong on a turn boundary.
    private var splitNudges: some View {
        HStack(spacing: VedivoxSpace.s) {
            Button("◀ Segment") { stepSegment(forward: false) }
                .keyboardShortcut(.leftArrow, modifiers: .option)
            Button("◀ 1 s") { splitTime = SplitCutPoint.clamped(splitTime - 1, duration) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("1 s ▶") { splitTime = SplitCutPoint.clamped(splitTime + 1, duration) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Segment ▶") { stepSegment(forward: true) }
                .keyboardShortcut(.rightArrow, modifiers: .option)
        }
        .buttonStyle(.vedivoxGhost)
    }

    private func stepSegment(forward: Bool) {
        splitTime = SplitCutPoint.segmentStep(
            from: splitTime, segmentStarts: viewModel.segments.map(\.startTime).sorted(),
            forward: forward, duration: duration
        )
    }

    // MARK: - Trim sliders

    private var trimSliders: some View {
        HStack(spacing: VedivoxSpace.xl) {
            VStack(alignment: .leading, spacing: VedivoxSpace.xxs) {
                VedivoxSectionHeader(title: "Start")
                Slider(value: $trimFrom, in: 0 ... max(1, trimTo - 1)) { if $0 { trimEdge = .start } }
                Text(WaveformView.formatTime(trimFrom))
                    .vedivoxFont(.timecode)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
            }
            VStack(alignment: .leading, spacing: VedivoxSpace.xxs) {
                VedivoxSectionHeader(title: "End")
                Slider(value: $trimTo, in: min(trimFrom + 1, duration) ... duration) { if $0 { trimEdge = .end } }
                Text(WaveformView.formatTime(trimTo))
                    .vedivoxFont(.timecode)
                    .foregroundStyle(Color.Vedivox.fgSecondary)
            }
        }
    }

    /// Split's keys for whichever bound is chosen.
    private var trimNudges: some View {
        HStack(spacing: VedivoxSpace.s) {
            Picker("", selection: $trimEdge) {
                ForEach(TrimEdge.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button("◀ Segment") { stepTrimSegment(forward: false) }
                .keyboardShortcut(.leftArrow, modifiers: .option)
            Button("◀ 1 s") { moveTrimEdge(to: trimEdgeTime - 1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("1 s ▶") { moveTrimEdge(to: trimEdgeTime + 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Segment ▶") { stepTrimSegment(forward: true) }
                .keyboardShortcut(.rightArrow, modifiers: .option)
            Button("Switch bound") { trimEdge = trimEdge == .start ? .end : .start }
                .keyboardShortcut(.tab, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .buttonStyle(.vedivoxGhost)
    }

    private var trimEdgeTime: Double { trimEdge == .start ? trimFrom : trimTo }

    /// A second apart, as the sliders keep them.
    private var trimEdgeRange: ClosedRange<Double> {
        trimEdge == .start ? 0 ... max(0, trimTo - 1) : min(trimFrom + 1, duration) ... duration
    }

    private func moveTrimEdge(to time: Double) {
        let moved = TrimBound.clamped(time, within: trimEdgeRange)
        if trimEdge == .start { trimFrom = moved } else { trimTo = moved }
    }

    private func stepTrimSegment(forward: Bool) {
        let stops = (trimEdge == .start ? viewModel.segments.map(\.startTime) : viewModel.segments.map(\.endTime)).sorted()
        moveTrimEdge(to: TrimBound.segmentStep(from: trimEdgeTime, stops: stops, forward: forward, within: trimEdgeRange))
    }

    // MARK: - Preview

    private var segmentCounts: (part1: Int, part2: Int) {
        let segments = viewModel.segments
        let part1 = segments.filter { $0.endTime <= splitTime }.count
        return (part1, segments.count - part1)
    }

    private var trimCounts: (keep: Int, remove: Int) {
        TrimBound.counts(segments: viewModel.segments.map { ($0.startTime, $0.endTime) }, from: trimFrom, to: trimTo)
    }

    @ViewBuilder
    private var preview: some View {
        if mode == .split {
            let counts = segmentCounts
            VStack(alignment: .leading, spacing: VedivoxSpace.s) {
                previewRow(
                    num: "#1",
                    range: "\(WaveformView.formatTime(0)) → \(WaveformView.formatTime(splitTime))",
                    detail: "\(counts.part1) seg."
                )
                previewRow(
                    num: "#2",
                    range: "\(WaveformView.formatTime(splitTime)) → \(WaveformView.formatTime(duration))",
                    detail: "\(counts.part2) seg."
                )
            }
        } else {
            let counts = trimCounts
            previewRow(
                num: "✂",
                range: "\(WaveformView.formatTime(trimFrom)) → \(WaveformView.formatTime(trimTo))",
                detail: "keeps \(counts.keep) seg., deletes \(counts.remove)"
            )
        }
    }

    private func previewRow(num: String, range: String, detail: String) -> some View {
        HStack(spacing: VedivoxSpace.l) {
            Text(num)
                .vedivoxFont(.overline)
                .foregroundStyle(Color.Vedivox.fgSecondary)
                .frame(width: 20, alignment: .leading)
            Text(range)
                .vedivoxFont(.tabular)
                .foregroundStyle(Color.Vedivox.fg)
            Spacer()
            Text(detail)
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)
        }
        .padding(.horizontal, VedivoxSpace.l)
        .padding(.vertical, VedivoxSpace.s)
        .background(RoundedRectangle(cornerRadius: VedivoxRadius.s).fill(Color.Vedivox.bgInput))
    }

    // MARK: - Apply

    private var applyTitle: String {
        mode == .split
            ? "Split in 2"
            : "Trim to \(WaveformView.formatTime(trimTo - trimFrom))"
    }

    private var canApply: Bool {
        guard duration > 1 else { return false }
        switch mode {
        case .split:
            let counts = segmentCounts
            return counts.part1 > 0 && counts.part2 > 0
        case .trim:
            return trimCounts.keep > 0 && (trimFrom > 0 || trimTo < duration)
        }
    }

    private func apply() {
        let meetingId = meeting.id
        switch mode {
        case .split:
            let t = splitTime
            Task { await appState.splitMeeting(meetingId, atTime: t) }
        case .trim:
            let from = trimFrom
            let to = trimTo
            Task { await appState.trimMeeting(meetingId, keepFrom: from, keepTo: to) }
        }
        dismiss()
    }
}
