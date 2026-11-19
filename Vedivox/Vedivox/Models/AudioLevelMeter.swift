import Foundation

/// Turns raw microphone samples into a 0…1 level for the dictation HUD
///
/// A pulsing dot says «recording». Bars that move with the voice say «the
/// microphone hears *you*» — which is the question a user actually has when
/// nothing appears on screen for the first couple of seconds.
///
/// The mapping is deliberately not linear in amplitude: speech RMS sits around
/// 0.01–0.1, so a linear bar would sit near zero and never move. Decibels with a
/// 55 dB window put normal speech in the upper half of the range.
struct AudioLevelMeter {

    /// Below this the input is treated as silence. Guards against log10(0) and
    /// keeps room tone from lighting up the display.
    private static let noiseFloor: Float = 0.002
    /// Window in dB mapped onto 0…1. -55 dBFS reads as silence, 0 dBFS as full.
    private static let rangeDB: Float = 55
    /// Weight of the previous value. Without smoothing the bars flicker on every
    /// buffer; with too much they lag behind the voice.
    private static let smoothing: Float = 0.7

    private(set) var level: Float = 0

    /// Feeds one buffer and returns the smoothed level.
    @discardableResult
    mutating func append(_ samples: [Float]) -> Float {
        level = Self.smoothing * level + (1 - Self.smoothing) * Self.instantLevel(of: samples)
        return level
    }

    mutating func reset() {
        level = 0
    }

    /// Unsmoothed level of a single buffer — the part worth testing, since it
    /// carries the whole amplitude-to-display mapping.
    static func instantLevel(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        var sumOfSquares: Float = 0
        for sample in samples where sample.isFinite {
            sumOfSquares += sample * sample
        }
        let rms = (sumOfSquares / Float(samples.count)).squareRoot()
        guard rms > noiseFloor else { return 0 }

        let decibels = 20 * log10(rms)
        return min(max((decibels + rangeDB) / rangeDB, 0), 1)
    }
}
