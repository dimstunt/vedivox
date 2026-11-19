import Accelerate
import AVFoundation
import Foundation

/// Gate mic audio based on system audio activity.
/// Where system audio is active (speech from remote participants), mic audio is zeroed
/// to remove echo from the speaker/headphones.
enum AudioGate {

    struct Config {
        /// RMS energy frame size in seconds.
        var frameSize: Double = 0.010 // 10ms
        /// Threshold = factor × P95(system energy). Frames above this are "active".
        var thresholdFactor: Double = 0.10
        /// Hold time after system goes silent — keep gate closed for this long.
        var holdTime: Double = 0.500 // 500ms
        /// Crossfade duration at gate boundaries to avoid clicks.
        var crossfadeDuration: Double = 0.020 // 20ms
    }

    /// Apply echo suppression gate: zero mic audio where system audio is active.
    /// Returns the gated mic samples at the same sample rate.
    static func apply(
        micSamples: [Float],
        systemSamples: [Float],
        sampleRate: Double,
        config: Config = Config()
    ) -> [Float] {
        let frameLength = Int(config.frameSize * sampleRate)
        guard frameLength > 0, !micSamples.isEmpty else { return micSamples }

        // 1. Compute RMS energy envelope of system audio
        let systemEnergy = rmsEnergy(systemSamples, frameLength: frameLength)
        guard !systemEnergy.isEmpty else { return micSamples }

        // 2. Adaptive threshold: 10% of P95(system energy)
        let threshold = percentile(systemEnergy, p: 0.95) * Float(config.thresholdFactor)

        // 3. Binary gate: 1.0 = pass mic, 0.0 = suppress mic
        var gate = systemEnergy.map { $0 > threshold ? Float(0.0) : Float(1.0) }

        // 4. Hold: after system goes silent, keep gate closed for holdTime
        let holdFrames = Int(config.holdTime / config.frameSize)
        applyHold(&gate, holdFrames: holdFrames)

        // 5. Expand gate to sample-level
        var sampleGate = [Float](repeating: 1.0, count: micSamples.count)
        for (i, g) in gate.enumerated() {
            let start = i * frameLength
            let end = min(start + frameLength, micSamples.count)
            guard start < end else { continue }
            for j in start ..< end {
                sampleGate[j] = g
            }
        }

        // 6. Crossfade at gate boundaries
        let crossfadeSamples = Int(config.crossfadeDuration * sampleRate)
        applyCrossfade(&sampleGate, crossfadeSamples: crossfadeSamples)

        // 7. Multiply mic by gate (vDSP)
        var result = [Float](repeating: 0, count: micSamples.count)
        vDSP_vmul(micSamples, 1, sampleGate, 1, &result, 1, vDSP_Length(micSamples.count))

        return result
    }

    // MARK: - Energy Computation

    /// Compute per-frame RMS energy.
    static func rmsEnergy(_ samples: [Float], frameLength: Int) -> [Float] {
        let frameCount = samples.count / frameLength
        guard frameCount > 0 else { return [] }

        var energies = [Float](repeating: 0, count: frameCount)
        for i in 0 ..< frameCount {
            let offset = i * frameLength
            var sumSq: Float = 0
            samples.withUnsafeBufferPointer { buf in
                vDSP_svesq(
                    buf.baseAddress! + offset, 1,
                    &sumSq,
                    vDSP_Length(frameLength)
                )
            }
            energies[i] = sqrt(sumSq / Float(frameLength))
        }
        return energies
    }

    // MARK: - Gate Processing

    private static func percentile(_ values: [Float], p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(Int(Double(sorted.count) * p), sorted.count - 1)
        return sorted[index]
    }

    /// After a 0→1 transition, keep 0 for holdFrames more frames.
    private static func applyHold(_ gate: inout [Float], holdFrames: Int) {
        var holdCounter = 0
        for i in gate.indices {
            if gate[i] == 0.0 {
                holdCounter = holdFrames
            } else if holdCounter > 0 {
                gate[i] = 0.0
                holdCounter -= 1
            }
        }
    }

    /// Smooth 0↔1 transitions with linear crossfade.
    /// Finds transition points first, then applies ramps without cascading.
    private static func applyCrossfade(_ gate: inout [Float], crossfadeSamples: Int) {
        guard crossfadeSamples > 0, gate.count > crossfadeSamples else { return }

        // Find transition points (indices where value changes)
        var transitions: [(index: Int, from: Float, to: Float)] = []
        for i in 1 ..< gate.count {
            if gate[i] != gate[i - 1] {
                transitions.append((index: i, from: gate[i - 1], to: gate[i]))
            }
        }

        // Apply ramps at each transition
        for t in transitions {
            let rampLength = min(crossfadeSamples, gate.count - t.index)
            for j in 0 ..< rampLength {
                let frac = Float(j + 1) / Float(rampLength + 1)
                gate[t.index + j] = t.from + (t.to - t.from) * frac
            }
        }
    }

    // MARK: - File I/O

    /// Load float samples from a WAV file.
    static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw AudioGateError.bufferCreationFailed
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData?[0] else {
            throw AudioGateError.noChannelData
        }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    /// Write float samples to a mono WAV file.
    static func writeSamples(_ samples: [Float], to url: URL, sampleRate: Double = 16000) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw AudioGateError.bufferCreationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    enum AudioGateError: Error, LocalizedError {
        case bufferCreationFailed
        case noChannelData

        var errorDescription: String? {
            switch self {
            case .bufferCreationFailed: "Failed to create audio buffer"
            case .noChannelData: "No audio channel data found"
            }
        }
    }
}
