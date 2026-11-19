import AVFoundation
import Foundation

/// Pre-rendered waveform peaks for the player bar.
///
/// Peaks are normalized 0...1 amplitudes over a fixed number of bins spanning
/// the meeting timeline (`duration` = the longer of the two tracks). Computed
/// once per meeting and cached as JSON next to the audio files.
struct WaveformPeaks: Codable, Equatable, Sendable {
    var binCount: Int
    /// Timeline length the bins span, in seconds (max of both tracks).
    var duration: TimeInterval
    /// Source file lengths in frames — cache is invalidated when they change
    /// (e.g. after re-recording repair or echo suppression rewrite).
    var micLength: Int64
    var systemLength: Int64
    var mic: [Float]?
    var system: [Float]?

    /// Peaks for a playback track; `.mix` is the element-wise max of both.
    func peaks(for track: AudioTrack) -> [Float]? {
        switch track {
        case .mic: return mic
        case .system: return system
        case .mix:
            switch (mic, system) {
            case let (m?, s?): return zip(m, s).map(max)
            case let (m?, nil): return m
            case let (nil, s?): return s
            case (nil, nil): return nil
            }
        }
    }
}

enum WaveformPeaksService {
    static let defaultBinCount = 280
    private static let cacheFileName = "waveform-peaks.json"

    /// Load peaks for a meeting's audio, using the JSON cache next to the
    /// audio files when it matches the current sources.
    /// Heavy file reads run here — call off the main actor (e.g. from a Task).
    static func load(
        micURL: URL?, systemURL: URL?, binCount: Int = defaultBinCount
    ) -> WaveformPeaks? {
        guard micURL != nil || systemURL != nil else { return nil }

        let micFile = micURL.flatMap { try? AVAudioFile(forReading: $0) }
        let systemFile = systemURL.flatMap { try? AVAudioFile(forReading: $0) }
        guard micFile != nil || systemFile != nil else { return nil }

        let micLength = micFile?.length ?? 0
        let systemLength = systemFile?.length ?? 0
        let cacheURL = (micURL ?? systemURL)!
            .deletingLastPathComponent()
            .appendingPathComponent(cacheFileName)

        if let cached = try? JSONDecoder().decode(WaveformPeaks.self, from: Data(contentsOf: cacheURL)),
           cached.binCount == binCount,
           cached.micLength == micLength,
           cached.systemLength == systemLength {
            return cached
        }

        let micDuration = micFile.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        let systemDuration = systemFile.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        let duration = max(micDuration, systemDuration)
        guard duration > 0 else { return nil }

        var peaks = WaveformPeaks(
            binCount: binCount,
            duration: duration,
            micLength: micLength,
            systemLength: systemLength,
            mic: micFile.flatMap { computePeaks(file: $0, binCount: binCount, timelineDuration: duration) },
            system: systemFile.flatMap { computePeaks(file: $0, binCount: binCount, timelineDuration: duration) }
        )
        normalize(&peaks)

        if let data = try? JSONEncoder().encode(peaks) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return peaks
    }

    /// Absolute-peak per bin over the shared timeline. Bins past the end of a
    /// shorter track stay 0.
    static func computePeaks(
        file: AVAudioFile, binCount: Int, timelineDuration: TimeInterval
    ) -> [Float]? {
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = file.length
        guard totalFrames > 0, sampleRate > 0, timelineDuration > 0 else { return nil }

        var bins = [Float](repeating: 0, count: binCount)
        let framesPerBin = timelineDuration * sampleRate / Double(binCount)
        guard framesPerBin > 0 else { return nil }

        let chunkFrames: AVAudioFrameCount = 262_144
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return nil }

        file.framePosition = 0
        var position: Int64 = 0
        while position < totalFrames {
            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                Log.error("Waveform peaks read failed at frame \(position): \(error.localizedDescription)")
                break
            }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }

            let channels = Int(format.channelCount)
            if let data = buffer.floatChannelData {
                for frame in 0 ..< frames {
                    let bin = min(binCount - 1, Int(Double(position + Int64(frame)) / framesPerBin))
                    var amplitude: Float = 0
                    for ch in 0 ..< channels {
                        amplitude = max(amplitude, abs(data[ch][frame]))
                    }
                    if amplitude > bins[bin] { bins[bin] = amplitude }
                }
            }
            position += Int64(frames)
        }
        return bins
    }

    /// Normalize both tracks by their shared maximum with a perceptual curve,
    /// so quiet speech is still visible and mix = max(mic, system) stays
    /// consistent between tracks.
    private static func normalize(_ peaks: inout WaveformPeaks) {
        let maxAmplitude = max(peaks.mic?.max() ?? 0, peaks.system?.max() ?? 0)
        guard maxAmplitude > 0 else { return }
        func scale(_ values: [Float]?) -> [Float]? {
            values.map { $0.map { value in pow(min(1, value / maxAmplitude), 0.6) } }
        }
        peaks.mic = scale(peaks.mic)
        peaks.system = scale(peaks.system)
    }
}
