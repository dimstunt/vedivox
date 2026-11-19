import AVFoundation

/// Taps a capture stream a second time and hands out 16 kHz mono Float
/// samples — the format ASR wants — without touching the file being recorded
/// The microphone for dictation's
/// draft; both tracks of a meeting for its live transcript.
///
/// Deliberately hands out `[Float]` rather than `AVAudioPCMBuffer`: the buffer
/// is not `Sendable`, and it belongs to the audio thread that will reuse it.
/// Copying out the samples is what makes the hand-off safe.
///
/// `@unchecked Sendable` because the converter is touched only from the audio
/// tap callback, which is serial. Nothing else may call `feed`.
final class LiveAudioSink: @unchecked Sendable {

    private let onSamples: @Sendable ([Float]) -> Void
    private let onLevel: (@Sendable (Float) -> Void)?
    private let onFeedDuration: (@Sendable (Double) -> Void)?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var meter = AudioLevelMeter()
    private var samplesSinceLevelReport = 0

    /// ~40 ms between level reports. The tap fires ~50 times a second and the
    /// bars cannot show more than the display refresh anyway; reporting every
    /// buffer would just wake the main actor for nothing.
    private static let levelReportInterval = 640

    private static let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    /// `onFeedDuration` gets the seconds each `feed` took — what this second
    /// consumer costs the audio thread (live-transcript D8). Without it nothing
    /// is timed.
    init(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onLevel: (@Sendable (Float) -> Void)? = nil,
        onFeedDuration: (@Sendable (Double) -> Void)? = nil
    ) {
        self.onSamples = onSamples
        self.onLevel = onLevel
        self.onFeedDuration = onFeedDuration
    }

    /// The same consumer with a level report riding on its conversion. A tap
    /// has room for one sink, and a meeting has two listeners on the
    /// microphone: the live transcript and the reminders' speech clock.
    func reporting(level: @escaping @Sendable (Float) -> Void) -> LiveAudioSink {
        let earlier = onLevel
        return LiveAudioSink(
            onSamples: onSamples,
            onLevel: { value in
                earlier?(value)
                level(value)
            },
            onFeedDuration: onFeedDuration
        )
    }

    /// Converts one tap buffer and delivers its samples. Called on the audio
    /// thread — everything here must stay allocation-light and non-blocking.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let onFeedDuration else { return convert(buffer) }
        let started = CFAbsoluteTimeGetCurrent()
        convert(buffer)
        onFeedDuration(CFAbsoluteTimeGetCurrent() - started)
    }

    private func convert(_ source: AVAudioPCMBuffer) {
        guard source.frameLength > 0 else { return }
        // The system converter writes digital zeros for more than two channels
        // (fix-multichannel-audio-loss), so those are folded by hand first.
        let buffer = source.format.channelCount > 2 ? AudioConverter.downmixToMono(source) : source
        let inputFormat = buffer.format

        // The engine can hand over a different format after a device change,
        // and a converter built for the old one would silently produce garbage.
        if sourceFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: Self.target)
            // Two channels are mixed, not remapped: remapping keeps the left
            // one alone, and a voice in the right one was never heard.
            converter?.downmix = true
            sourceFormat = inputFormat
        }
        guard let converter else { return }

        let ratio = Self.target.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return }

        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }

        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        onSamples(samples)

        guard let onLevel else { return }
        meter.append(samples)
        samplesSinceLevelReport += samples.count
        if samplesSinceLevelReport >= Self.levelReportInterval {
            samplesSinceLevelReport = 0
            onLevel(meter.level)
        }
    }
}
