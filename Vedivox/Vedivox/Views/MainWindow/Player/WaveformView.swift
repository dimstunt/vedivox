import SwiftUI

/// Interactive waveform for the player bar.
/// Bars are tinted by the speaker talking at that moment; the played part is
/// saturated, the rest dimmed. Click or drag seeks; hover shows a time tooltip.
struct WaveformView: View {
    let peaks: [Float]
    /// Per-bin speaker hue (nil = no speech in that bin).
    let hues: [Double?]
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void
    /// Player bar uses the compact default; the split/trim sheet asks for more.
    var height: CGFloat = 30
    /// «Не в транскрипт» stretches, drawn as a red wash over the bars — the
    /// waveform IS the meeting timeline, so the exclusion map lives on it
    /// rather than in a separate strip (transcript-exclusion-marks, D7/C).
    var excludedZones: [(start: Double, end: Double)] = []

    @State private var hoverFraction: Double?
    @State private var dragFraction: Double?
    @Environment(\.colorScheme) private var scheme

    private var displayedFraction: Double {
        if let dragFraction { return dragFraction }
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                canvas
                if let hoverFraction {
                    hoverIndicator(fraction: hoverFraction, size: geo.size)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragFraction = fraction(at: value.location.x, width: geo.size.width)
                    }
                    .onEnded { value in
                        let target = fraction(at: value.location.x, width: geo.size.width)
                        dragFraction = nil
                        onSeek(target * duration)
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverFraction = fraction(at: point.x, width: geo.size.width)
                case .ended:
                    hoverFraction = nil
                }
            }
        }
        .frame(height: height)
    }

    private var canvas: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let n = peaks.count
            let step = size.width / CGFloat(n)
            let barWidth = max(1, step - 1)
            let playedFraction = displayedFraction

            for i in 0 ..< n {
                let value = CGFloat(max(0.08, min(1, peaks[i])))
                let height = max(2, value * size.height)
                let x = CGFloat(i) * step
                let rect = CGRect(
                    x: x, y: (size.height - height) / 2,
                    width: barWidth, height: height
                )
                let played = Double(i) / Double(n) < playedFraction
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 0.5),
                    with: .color(barColor(hue: hues.indices.contains(i) ? hues[i] : nil, played: played))
                )
            }

            // Excluded stretches: translucent wash + a solid baseline so the
            // zone reads even where the bars are near-silent.
            if duration > 0 {
                for zone in excludedZones {
                    let x0 = size.width * CGFloat(min(max(0, zone.start / duration), 1))
                    let x1 = size.width * CGFloat(min(max(0, zone.end / duration), 1))
                    let width = max(2, x1 - x0)
                    let wash = CGRect(x: x0, y: 0, width: width, height: size.height)
                    context.fill(
                        Path(roundedRect: wash, cornerRadius: 2),
                        with: .color(Color.Vedivox.dangerSoft)
                    )
                    let baseline = CGRect(x: x0, y: size.height - 2, width: width, height: 2)
                    context.fill(
                        Path(roundedRect: baseline, cornerRadius: 1),
                        with: .color(Color.Vedivox.danger)
                    )
                }
            }

            // Playhead
            let playheadX = size.width * CGFloat(playedFraction)
            let playheadRect = CGRect(x: playheadX - 1, y: 0, width: 2, height: size.height)
            context.fill(Path(roundedRect: playheadRect, cornerRadius: 1), with: .color(Color.Vedivox.fg))
        }
    }

    private func hoverIndicator(fraction: Double, size: CGSize) -> some View {
        let x = size.width * CGFloat(fraction)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.Vedivox.fgSecondary.opacity(0.6))
                .frame(width: 1, height: size.height)
                .offset(x: x)
            Text(Self.formatTime(fraction * duration))
                .vedivoxFont(.timecode)
                .foregroundStyle(Color.Vedivox.fg)
                .padding(.horizontal, VedivoxSpace.s)
                .padding(.vertical, VedivoxSpace.xxs)
                .background(Color.Vedivox.bgCard, in: RoundedRectangle(cornerRadius: VedivoxRadius.xs))
                .overlay(RoundedRectangle(cornerRadius: VedivoxRadius.xs).strokeBorder(Color.Vedivox.line))
                // Keep the tooltip inside the view bounds.
                .offset(x: min(max(0, x - 24), max(0, size.width - 52)), y: -22)
        }
        .allowsHitTesting(false)
    }

    private func barColor(hue: Double?, played: Bool) -> Color {
        guard let hue else {
            return played ? Color.Vedivox.fgSecondary : Color.Vedivox.fgQuaternary.opacity(0.6)
        }
        let speaker = Color.speaker(hue: hue, scheme: scheme)
        return played ? speaker : speaker.opacity(0.35)
    }

    private func fraction(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(0, x / width), 1))
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let mins = total / 60
        let secs = total % 60
        if mins >= 60 {
            return String(format: "%d:%02d:%02d", mins / 60, mins % 60, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }
}
