import KeyboardShortcuts
import SwiftUI

/// Player bar: play button, speed control with presets, waveform scrubber,
/// timecodes and track switcher. Visuals follow the Claude Design bundle
/// (`player.jsx`, `.vedivox-player` styles) —
struct PlayerBarView: View {
    /// A span of the timeline attributed to one speaker, for waveform tinting.
    struct HueSpan: Equatable {
        let start: TimeInterval
        let end: TimeInterval
        let hue: Double
    }

    let isPlaying: Bool
    let currentTime: TimeInterval
    let duration: TimeInterval
    let activeTrack: AudioTrack
    let hasSystemAudio: Bool
    let playbackRate: Float
    let peaks: WaveformPeaks?
    let hueSpans: [HueSpan]
    let onPlayPause: () -> Void
    let onSeek: (TimeInterval) -> Void
    /// «Не в транскрипт» stretches to draw over the waveform.
    var excludedZones: [(start: Double, end: Double)] = []
    let onTrackChange: (AudioTrack) -> Void
    let onRateChange: (Float) -> Void

    /// Dropdown presets from the design spec (labels «норма» / «рекомендуется»).
    static let ratePresets: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]

    /// Room for "H:MM:SS" once the meeting passes an hour; never wraps
    /// (fixedSize), and the reserve keeps the waveform still as time ticks.
    private var timecodeWidth: CGFloat { duration >= 3600 ? 60 : 46 }

    var body: some View {
        HStack(spacing: VedivoxSpace.l) {
            playButton
            speedControl

            Text(WaveformView.formatTime(currentTime))
                .vedivoxFont(.timecode)
                .foregroundStyle(Color.Vedivox.fg)
                .fixedSize()
                .frame(minWidth: timecodeWidth, alignment: .trailing)
                .accessibilityIdentifier("player.currentTime")

            WaveformView(
                peaks: displayedPeaks,
                hues: binHues,
                currentTime: currentTime,
                duration: duration,
                onSeek: onSeek,
                excludedZones: excludedZones
            )

            Text(WaveformView.formatTime(duration))
                .vedivoxFont(.timecode)
                .foregroundStyle(Color.Vedivox.fgSecondary)
                .fixedSize()
                .frame(minWidth: timecodeWidth, alignment: .leading)
                .accessibilityIdentifier("player.duration")

            if hasSystemAudio {
                trackSwitcher
            }
        }
        .padding(.horizontal, VedivoxSpace.xl)
        .padding(.vertical, VedivoxSpace.m)
        .background(Color.Vedivox.bg)
    }

    // MARK: - Controls

    private var playButton: some View {
        Button(action: onPlayPause) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.Vedivox.accentFg)
                .frame(width: 28, height: 28)
                .background(Color.Vedivox.accent, in: Circle())
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Pause (Space)" : "Play (Space)")
    }

    private var speedControl: some View {
        HStack(spacing: VedivoxSpace.xxs) {
            Button {
                stepRate(by: -1)
            } label: {
                Image(systemName: "tortoise.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(playbackRate <= Self.ratePresets.first!)
            .help("Slower\(Self.shortcutHint(.playerSlower))")

            VedivoxPicker(
                selection: Binding(get: { playbackRate }, set: onRateChange),
                options: Self.ratePresets.map { ($0, "\(Self.formatRate($0))\(Self.rateTag($0))") }
            ) {
                Text(Self.formatRate(playbackRate))
                    .vedivoxFont(.timecode)
                    .foregroundStyle(Color.Vedivox.fg)
                    .frame(width: 38, height: 20)
                    .background(Color.Vedivox.bgCard, in: RoundedRectangle(cornerRadius: VedivoxRadius.s))
                    .overlay(RoundedRectangle(cornerRadius: VedivoxRadius.s).strokeBorder(Color.Vedivox.line))
            }
            // Fixed width: sized to its text, "1×" vs "1.75×" moved the hare
            // button under the cursor while clicking through rates.
            .frame(width: 48)
            .help("Playback speed")

            Button {
                stepRate(by: 1)
            } label: {
                Image(systemName: "hare.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.Vedivox.fgSecondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(playbackRate >= Self.ratePresets.last!)
            .help("Faster\(Self.shortcutHint(.playerFaster))")
        }
    }

    private var trackSwitcher: some View {
        TrackSwitcher(selected: activeTrack, label: \.shortLabel, help: \.help, choose: onTrackChange)
    }

    // MARK: - Waveform data

    private var displayedPeaks: [Float] {
        if let track = peaks?.peaks(for: activeTrack) {
            return track
        }
        // Placeholder while peaks are computing (or audio missing): flat dim bars.
        return [Float](repeating: 0.12, count: WaveformPeaksService.defaultBinCount)
    }

    /// Speaker hue per waveform bin, resolved from transcript segment spans.
    private var binHues: [Double?] {
        let n = displayedPeaks.count
        guard duration > 0, !hueSpans.isEmpty else {
            return [Double?](repeating: nil, count: n)
        }
        let spans = hueSpans.sorted { $0.start < $1.start }
        var result = [Double?](repeating: nil, count: n)
        var spanIndex = 0
        for bin in 0 ..< n {
            let t = (Double(bin) + 0.5) / Double(n) * duration
            while spanIndex < spans.count, spans[spanIndex].end < t {
                spanIndex += 1
            }
            if spanIndex < spans.count, spans[spanIndex].start <= t {
                result[bin] = spans[spanIndex].hue
            }
        }
        return result
    }

    // MARK: - Helpers

    private func stepRate(by direction: Int) {
        let presets = Self.ratePresets
        // Current rate may sit between presets (e.g. legacy 1.75) — snap to the nearest.
        let nearestIndex = presets.indices.min(by: {
            abs(presets[$0] - playbackRate) < abs(presets[$1] - playbackRate)
        }) ?? 1
        let newIndex = min(max(0, nearestIndex + direction), presets.count - 1)
        onRateChange(presets[newIndex])
    }

    /// " (⌥[)" — the rate shortcut as set in Settings → Shortcuts; empty when cleared.
    @MainActor private static func shortcutHint(_ name: KeyboardShortcuts.Name) -> String {
        KeyboardShortcuts.getShortcut(for: name).map { " (\($0.description))" } ?? ""
    }

    static func formatRate(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(String(format: "%g", rate))×"
    }

    private static func rateTag(_ rate: Float) -> String {
        if rate == 1.0 { return "  · normal" }
        if rate == 1.5 { return "  · recommended" }
        return ""
    }
}

/// Mix / Mic / Sys in the player; All / Mic / System over the transcript.
struct TrackSwitcher: View {
    let selected: AudioTrack
    let label: (AudioTrack) -> String
    let help: (AudioTrack) -> String
    let choose: (AudioTrack) -> Void

    var body: some View {
        HStack(spacing: VedivoxSpace.xxs) {
            ForEach(AudioTrack.switcherOrder, id: \.self) { track in
                Button {
                    choose(track)
                } label: {
                    Text(label(track))
                        .vedivoxFont(.label)
                        .fixedSize()
                        .foregroundStyle(track == selected ? Color.Vedivox.accentFg : Color.Vedivox.fgSecondary)
                        .padding(.horizontal, VedivoxSpace.m)
                        .padding(.vertical, VedivoxSpace.xs)
                        .background(
                            track == selected ? Color.Vedivox.accent : .clear,
                            in: RoundedRectangle(cornerRadius: VedivoxRadius.s)
                        )
                }
                .buttonStyle(.plain)
                .help(help(track))
            }
        }
        .padding(VedivoxSpace.xxs)
        .background(Color.Vedivox.bgCard, in: RoundedRectangle(cornerRadius: VedivoxRadius.m))
        .overlay(RoundedRectangle(cornerRadius: VedivoxRadius.m).strokeBorder(Color.Vedivox.lineSoft))
    }
}

extension AudioTrack {
    static let switcherOrder: [AudioTrack] = [.mix, .mic, .system]

    var shortLabel: String {
        switch self {
        case .mix: "Mix"
        case .mic: "Mic"
        case .system: "Sys"
        }
    }

    var help: String {
        switch self {
        case .mix: "Both tracks"
        case .mic: "Mic only"
        case .system: "System audio only"
        }
    }
}
