import Foundation

/// Hue assignment math for persistent speaker colors.
/// Lives in Models so it is usable from Services (repository, migration) and
/// testable in the headless VedivoxCoreTests target; the view-facing resolver in
/// DesignSystem/SpeakerHue.swift delegates here.
enum SpeakerHueMath {
    /// Deterministic fallback hue (0..<360) from a string key via djb2 hash.
    /// Used for segments whose speaker has no stored hue (e.g. raw labels).
    static func fallback(_ key: String) -> Double {
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Double(hash % 360)
    }

    /// Hue for a new speaker: the midpoint of the largest gap on the hue
    /// circle between existing hues — maximally distant from everyone.
    static func nextHue(existing: [Double]) -> Double {
        let normalized = existing
            .map { $0.truncatingRemainder(dividingBy: 360) }
            .map { $0 < 0 ? $0 + 360 : $0 }
            .sorted()
        guard let first = normalized.first else { return 210 }

        var bestGap = 0.0
        var bestMidpoint = first
        for i in normalized.indices {
            let a = normalized[i]
            let b = i + 1 < normalized.count ? normalized[i + 1] : first + 360
            let gap = b - a
            if gap > bestGap {
                bestGap = gap
                bestMidpoint = (a + gap / 2).truncatingRemainder(dividingBy: 360)
            }
        }
        return bestMidpoint.rounded()
    }

    /// OKLCH → gamma-encoded sRGB, each channel clamped to 0...1. Speaker
    /// colors are defined in OKLCH (design system, Speaker) so every hue
    /// lands at the same perceived lightness; HSB made yellows glare and
    /// blues sink.
    static func srgb(l: Double, c: Double, h: Double) -> (r: Double, g: Double, b: Double) {
        let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
        let l3 = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m3 = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s3 = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        func encode(_ v: Double) -> Double {
            let v = min(max(v, 0), 1)
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return (
            encode(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
            encode(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
            encode(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3)
        )
    }

    /// Evenly spread hues for `count` speakers (migration backfill).
    /// Starts at 210 (the design bundle's default accent hue region).
    static func evenSpread(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let step = 360.0 / Double(count)
        return (0 ..< count).map { (210 + Double($0) * step).truncatingRemainder(dividingBy: 360).rounded() }
    }
}
