import AVFoundation
import Foundation

/// Audio read front to back as deinterleaved Float32.
protocol PCMSource: AnyObject {
    var processingFormat: AVAudioFormat { get }
    var length: AVAudioFramePosition { get }
    var framePosition: AVAudioFramePosition { get }
    func read(into buffer: AVAudioPCMBuffer) throws
}

extension AVAudioFile: PCMSource {}

enum AudioConverter {
    /// Extensions that `AVAudioFile(forReading:)` may open directly.
    ///
    /// `AVAudioFile` leaks its file descriptor permanently on QuickTime `.mov`
    /// containers: the fd outlives the object, so once the pipeline deletes an
    /// imported `original.mov` the freed space stays invisible until the app
    /// restarts. Measured on macOS 15 — `.wav`, `.m4a` and `.mp4` all release
    /// the fd, `.mov` never does. Imports are transcoded to `mic.wav` within a
    /// second anyway, so playback and waveform rendering never need to read the
    /// original container directly.
    static let directReadSafeExtensions: Set<String> = [
        "wav", "m4a", "mp3", "aiff", "aif", "caf",
    ]

    /// Whether `url` may be handed to `AVAudioFile(forReading:)` — used by the
    /// playback/waveform fallback to the original imported file.
    static func isSafeForDirectRead(_ url: URL) -> Bool {
        directReadSafeExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Channel handling (fix-multichannel-audio-loss)

    /// Per-channel RMS of a Float32 buffer, interleaved or not.
    static func channelRMS(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let stride = buffer.stride
        return (0 ..< Int(buffer.format.channelCount)).map { c in
            guard frames > 0 else { return 0 }
            var acc: Float = 0
            for i in 0 ..< frames {
                let v = data[c][i * stride]
                acc += v * v
            }
            return (acc / Float(frames)).squareRoot()
        }
    }

    static func dBFS(_ linear: Float) -> Float {
        linear > 0 ? 20 * log10(linear) : -.infinity
    }

    static func formatDBFS(_ values: [Float]) -> String {
        values.map { String(format: "%.1f", dBFS($0)) }.joined(separator: " ")
    }

    /// Folds N channels into one by hand: `AVAudioConverter` returns digital
    /// zeros for N > 2 (design § решение 1). Channels more than 20 dB below the
    /// loudest one are left out of the average, so speech that sits in a single
    /// channel of three keeps its level instead of losing 9.5 dB (решение 2).
    static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
            channels: 1, interleaved: false
        )!
        let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(max(frames, 1)))!
        mono.frameLength = AVAudioFrameCount(frames)
        guard frames > 0, let src = buffer.floatChannelData, let dst = mono.floatChannelData?[0] else { return mono }

        let rms = channelRMS(buffer)
        let loudest = rms.max() ?? 0
        let sounding = (0 ..< channels).filter { rms[$0] > 0 && rms[$0] >= loudest * 0.1 }
        let used = sounding.isEmpty ? Array(0 ..< channels) : sounding
        let scale = 1 / Float(used.count)
        let stride = buffer.stride
        for i in 0 ..< frames {
            var sum: Float = 0
            for c in used { sum += src[c][i * stride] }
            dst[i] = sum * scale
        }
        return mono
    }

    /// Float32 non-interleaved format with `channels` channels at `sampleRate`.
    /// N > 2 needs an explicit layout — the plain initializer returns nil.
    static func float32Format(channels: AVAudioChannelCount, sampleRate: Double, layout: AVAudioChannelLayout? = nil) -> AVAudioFormat? {
        if channels <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)
        }
        let layout = layout ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
        guard let layout else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
    }

    /// Brings a buffer to `channels` channels without the system converter:
    /// N → 1 folds via `downmixToMono`, 1 → N copies mono into every channel
    /// (so a later fold returns the same level), anything else goes via mono.
    /// Sample rate is untouched.
    static func remapChannels(
        _ buffer: AVAudioPCMBuffer, to channels: AVAudioChannelCount, layout: AVAudioChannelLayout? = nil
    ) -> AVAudioPCMBuffer? {
        let inChannels = buffer.format.channelCount
        if inChannels == channels { return buffer }
        let mono = inChannels == 1 ? buffer : downmixToMono(buffer)
        if channels == 1 { return mono }
        guard let format = float32Format(channels: channels, sampleRate: buffer.format.sampleRate, layout: layout),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(buffer.frameLength, 1)),
              let src = mono.floatChannelData?[0], let dst = out.floatChannelData
        else { return nil }
        out.frameLength = buffer.frameLength
        let stride = out.stride
        for c in 0 ..< Int(channels) {
            for i in 0 ..< Int(out.frameLength) { dst[c][i * stride] = src[i] }
        }
        return out
    }

    // MARK: - Preparation for recognition

    /// Peak the recognition copy is lifted to. Only upward: a track that already
    /// peaks above this is left alone (design § решение 7).
    static let normalizeTargetPeak: Float = 0.7

    /// Converts any audio file to 16kHz mono WAV suitable for transcription.
    ///
    /// N > 2 channels are folded to mono by hand before the system converter, two
    /// are mixed by it, the read loop ends by position (a thrown read is an
    /// error, not EOF), and the
    /// result is peak-normalized upward so a track the system attenuated during a
    /// phone call is still recognizable.
    static func convertTo16kHzMonoWAV(input: URL, output: URL) async throws {
        try convertTo16kHzMonoWAV(name: input.lastPathComponent, output: output) { try AVAudioFile(forReading: input) }
    }

    /// The same from any reader; `open` starts it over. The source is read
    /// twice — for the peak, then to write — so that the file is written once:
    /// a scaled second copy and the float copies FluidAudio made of it were
    /// most of what processing wrote to disk.
    static func convertTo16kHzMonoWAV(name: String, output: URL, open: () throws -> any PCMSource) throws {
        let probe = try open()
        var peak: Float = 0
        let probeRMS = try resampleTo16kMono(probe, name: name) { buffer in
            guard let data = buffer.floatChannelData?[0] else { return }
            for i in 0 ..< Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
        }
        if !probeRMS.isEmpty {
            let format = probe.processingFormat
            Log.info("Prepared \(name): \(Int(format.sampleRate)) Hz \(format.channelCount)ch, first \(String(format: "%.1f", min(2, Double(probe.length) / format.sampleRate))) s RMS per channel: \(formatDBFS(probeRMS)) dBFS, output peak \(String(format: "%.1f", dBFS(peak))) dBFS")
        }

        let gain = peak > 0 && peak < normalizeTargetPeak ? normalizeTargetPeak / peak : 1
        let file = try AVAudioFile(
            forWriting: output, settings: recognitionSettings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        _ = try resampleTo16kMono(try open(), name: name) { buffer in
            if gain != 1, let data = buffer.floatChannelData?[0] {
                for i in 0 ..< Int(buffer.frameLength) { data[i] *= gain }
            }
            try file.write(from: buffer)
        }
        if gain != 1 {
            Log.info("Normalized \(output.lastPathComponent): peak \(String(format: "%.1f", dBFS(peak))) → \(String(format: "%.1f", dBFS(normalizeTargetPeak))) dBFS (+\(String(format: "%.1f", dBFS(gain))) dB)")
        }
    }

    /// A recognition file: 16-bit mono at 16 kHz. FluidAudio maps exactly this
    /// in place; anything else it first copies to a temporary Float32 file, once
    /// for recognition and once for diarization.
    /// shortcut: samples over full scale are clipped (AAC overshoots, a hot
    /// microphone); attenuate the track instead if recognition of loud ones suffers.
    static var recognitionSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ] }

    /// Resample + fold to 16 kHz mono Float32, buffer by buffer. Returns the
    /// per-channel RMS of the source's first two seconds (design § решение 2).
    private static func resampleTo16kMono(
        _ input: any PCMSource, name: String, _ body: (AVAudioPCMBuffer) throws -> Void
    ) throws -> [Float] {
        let inputFormat = input.processingFormat
        let channels = Int(inputFormat.channelCount)
        let totalFrames = input.length

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
        )!
        // The system converter only ever sees one or two channels.
        let converterInput = channels > 2
            ? float32Format(channels: 1, sampleRate: inputFormat.sampleRate)!
            : inputFormat
        guard let converter = AVAudioConverter(from: converterInput, to: outputFormat) else {
            throw AudioConverterError.converterCreationFailed
        }
        // Stereo is mixed, not remapped: remapping keeps the left channel
        // alone, and a voice in the right one never reached the transcript
        converter.downmix = true

        let bufferCapacity: AVAudioFrameCount = 4096
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: bufferCapacity)!

        let probeFrames = Int(inputFormat.sampleRate * 2)
        var probeAcc = [Float](repeating: 0, count: channels)
        var probeCount = 0

        var readError: Error?

        while true {
            var converterError: NSError?
            let status = converter.convert(to: outputBuffer, error: &converterError) { _, outStatus in
                guard readError == nil, input.framePosition < totalFrames else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: bufferCapacity)!
                do {
                    try input.read(into: inputBuffer)
                } catch {
                    readError = error
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard inputBuffer.frameLength > 0 else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if probeCount < probeFrames {
                    let rms = channelRMS(inputBuffer)
                    let n = Float(inputBuffer.frameLength)
                    for c in 0 ..< channels { probeAcc[c] += rms[c] * rms[c] * n }
                    probeCount += Int(inputBuffer.frameLength)
                }
                outStatus.pointee = .haveData
                return channels > 2 ? downmixToMono(inputBuffer) : inputBuffer
            }

            if let readError {
                Log.error("Read failed at frame \(input.framePosition)/\(totalFrames) of \(name): \(readError.localizedDescription)")
                throw readError
            }
            if status == .error {
                Log.error("Converting \(name) failed: \(converterError?.localizedDescription ?? "no error object")")
                throw AudioConverterError.conversionFailed
            }
            if outputBuffer.frameLength == 0 || status == .endOfStream {
                break
            }
            try body(outputBuffer)
        }

        // A source that ends before its header says (truncated file, failed
        // read) is an error — not a shorter result.
        if input.framePosition < totalFrames {
            throw AudioIntegrityError.sourceTruncated(read: input.framePosition, expected: totalFrames)
        }
        return probeCount > 0 ? probeAcc.map { ($0 / Float(probeCount)).squareRoot() } : []
    }

    // MARK: - Verification (design § решение 4)

    /// RMS below this is the noise floor: meetings where the user stayed silent
    /// sit at −43…−69 dBFS, the lost track of 2026-08-14 at −30 dBFS.
    static let speechFloorDBFS: Float = -40

    struct TrackStats {
        let duration: Double
        /// RMS of the loudest channel, so speech in one channel of six still counts.
        let rmsDBFS: Float

        var sounded: Bool { rmsDBFS > AudioConverter.speechFloorDBFS }
    }

    /// Stats of the whole file, or of `seconds` starting at `from`.
    static func trackStats(of url: URL, from: Double = 0, seconds: Double = .infinity) throws -> TrackStats {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let capacity: AVAudioFrameCount = 65536
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        let start = min(file.length, AVAudioFramePosition(from * format.sampleRate))
        let end = seconds.isFinite ? min(file.length, start + AVAudioFramePosition(seconds * format.sampleRate)) : file.length
        file.framePosition = start
        var acc = [Float](repeating: 0, count: channels)
        var frames = 0
        while file.framePosition < end {
            try file.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(end - file.framePosition)))
            guard buffer.frameLength > 0 else { break }
            let rms = channelRMS(buffer)
            let n = Float(buffer.frameLength)
            for c in 0 ..< channels { acc[c] += rms[c] * rms[c] * n }
            frames += Int(buffer.frameLength)
        }
        let loudest = frames > 0 ? (acc.max() ?? 0) / Float(frames) : 0
        return TrackStats(duration: Double(end - start) / format.sampleRate, rmsDBFS: dBFS(loudest.squareRoot()))
    }

    enum AudioIntegrityError: Error, LocalizedError {
        case durationMismatch(source: Double, result: Double)
        case energyLost(sourceDBFS: Float, resultDBFS: Float)
        case sourceTruncated(read: AVAudioFramePosition, expected: AVAudioFramePosition)
        case shifted(seconds: Double)

        var errorDescription: String? {
            switch self {
            case .shifted(let seconds):
                "Audio transformation shifted the track by \(Int((seconds * 1000).rounded())) ms"
            case .durationMismatch(let s, let r):
                "Audio transformation changed duration: \(String(format: "%.1f", s)) s → \(String(format: "%.1f", r)) s"
            case .energyLost(let s, let r):
                "Audio transformation lost the signal: \(String(format: "%.1f", s)) dBFS → \(String(format: "%.1f", r)) dBFS"
            case .sourceTruncated(let read, let expected):
                "Audio source ended early: \(read) of \(expected) frames"
            }
        }
    }

    /// Post-condition of every audio transformation: the result lasts as long
    /// as the source (5 %, 0.1 s slack for AAC priming) and, when the source had
    /// energy above the noise floor, so does the result. `requireEnergy: false`
    /// for transformations that remove energy on purpose (the echo gate).
    @discardableResult
    static func verify(source: URL, result: URL, requireEnergy: Bool = true) throws -> TrackStats {
        let s = try trackStats(of: source)
        let r = try trackStats(of: result)
        if abs(s.duration - r.duration) > max(0.05 * s.duration, 0.1) {
            throw AudioIntegrityError.durationMismatch(source: s.duration, result: r.duration)
        }
        if requireEnergy, s.sounded, !r.sounded {
            throw AudioIntegrityError.energyLost(sourceDBFS: s.rmsDBFS, resultDBFS: r.rmsDBFS)
        }
        Log.debug("Verified \(result.lastPathComponent) against \(source.lastPathComponent): \(String(format: "%.1f", s.duration)) s, \(String(format: "%.1f", s.rmsDBFS)) → \(String(format: "%.1f", r.rmsDBFS)) dBFS")
        return s
    }

    /// `verify` for a concatenation: the result lasts as long as the parts together,
    /// and each stretch of it has energy where its part had.
    static func verifyJoin(parts: [URL], result: URL) throws {
        let stats = try parts.map { try trackStats(of: $0) }
        let total = stats.reduce(0) { $0 + $1.duration }
        let file = try AVAudioFile(forReading: result)
        let resultDuration = Double(file.length) / file.processingFormat.sampleRate
        if abs(total - resultDuration) > max(0.05 * total, 0.1) {
            throw AudioIntegrityError.durationMismatch(source: total, result: resultDuration)
        }
        var offset = 0.0
        for s in stats {
            if s.sounded {
                let r = try trackStats(of: result, from: offset, seconds: s.duration)
                if !r.sounded { throw AudioIntegrityError.energyLost(sourceDBFS: s.rmsDBFS, resultDBFS: r.rmsDBFS) }
            }
            offset += s.duration
        }
        Log.debug("Verified join \(result.lastPathComponent): \(String(format: "%.1f", total)) s from \(parts.count) parts")
    }

    /// Time shift of `result` against `source`, in seconds, to 10 ms.
    ///
    /// A re-encode must keep the mic and system tracks aligned; a decoder that
    /// handles encoder priming differently in the old and new file would not.
    /// Compares 10 ms RMS envelopes at 16 kHz by cross-correlation within ±50 ms.
    /// A flat envelope (silence) has no shape to align and reads as 0.
    static func shift(of result: URL, against source: URL) async throws -> Double {
        let a = try await envelope(of: source)
        let b = try await envelope(of: result)
        let n = min(a.count, b.count)
        guard n > 10 else { return 0 }
        func centered(_ x: [Float]) -> [Float] {
            let mean = x.prefix(n).reduce(0, +) / Float(n)
            return x.prefix(n).map { $0 - mean }
        }
        let (x, y) = (centered(a), centered(b))
        var best = (lag: 0, score: -Float.infinity)
        for lag in -5 ... 5 {
            var score: Float = 0
            for i in max(0, -lag) ..< min(n, n - lag) { score += x[i] * y[i + lag] }
            if score > best.score { best = (lag, score) }
        }
        return best.score > 0 ? Double(best.lag) * 0.01 : 0
    }

    /// RMS per 10 ms (160 samples at 16 kHz mono), streamed: a two-hour track
    /// is 720k values instead of 115M samples.
    private static func envelope(of url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioConverterError.noAudioTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }

        var envelope: [Float] = []
        var sum: Float = 0
        var count = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / 4)
            _ = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            for v in floats {
                sum += v * v
                count += 1
                if count == 160 {
                    envelope.append((sum / 160).squareRoot())
                    sum = 0
                    count = 0
                }
            }
        }
        return envelope
    }

    /// Compress `wav` to `m4a` and delete the WAV only once the copy is verified
    /// against it (design § решение 6). On a mismatch the copy is removed, the
    /// WAV stays, and the error is thrown.
    static func compressAndReplace(wav: URL, m4a: URL) async throws {
        try await compressToAAC(input: wav, output: m4a)
        do {
            try verify(source: wav, result: m4a)
        } catch {
            try? FileManager.default.removeItem(at: m4a)
            throw error
        }
        try? FileManager.default.removeItem(at: wav)
    }

    /// Repairs a WAV file whose header was not finalized (e.g., app crash during recording).
    /// AVAudioEngine writes RIFF/data sizes as 0 or pre-allocated values when starting;
    /// on normal stop it rewrites them. A crash leaves them wrong.
    /// Returns true if the file was repaired, false if it was already valid.
    ///
    /// Patches eight bytes in place: the file can be several GB, and it is the
    /// only copy of the recording — rewriting it whole would cut it short if
    /// the rewrite itself were interrupted.
    @discardableResult
    static func repairWAVHeaderIfNeeded(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize > 44 else {
            throw AudioConverterError.fileTooSmall
        }

        // The chunks before the audio fit in the first kilobytes (AVAudioFile
        // pads its header to 4 KB).
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: 64 * 1024) ?? Data()
        guard head.prefix(4) == Data("RIFF".utf8) else {
            throw AudioConverterError.notAWAVFile
        }
        func size(at offset: Int) -> UInt32 {
            head.subdata(in: offset ..< offset + 4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }

        // A RIFF size that matches the file means the writer finished: leave
        // the file alone, whatever follows its audio (metadata chunks).
        let currentRiffSize = size(at: 4)
        let expectedRiffSize = UInt32(clamping: fileSize - 8)
        guard currentRiffSize != expectedRiffSize else { return false }

        // Walk the chunks to the audio — a byte search would also stop at
        // "data" inside another chunk's text.
        var offset = 12
        while offset + 8 <= head.count, head.subdata(in: offset ..< offset + 4) != Data("data".utf8) {
            let chunkSize = Int(size(at: offset + 4))
            offset += 8 + chunkSize + chunkSize % 2
        }
        guard offset + 8 <= head.count else {
            throw AudioConverterError.noDataChunk
        }
        let currentDataSize = size(at: offset + 4)
        // WAV sizes are 32-bit: past 4 GiB the header can only say "the maximum".
        let expectedDataSize = UInt32(clamping: fileSize - UInt64(offset + 8))

        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: withUnsafeBytes(of: expectedRiffSize.littleEndian) { Data($0) })
        try handle.seek(toOffset: UInt64(offset + 4))
        try handle.write(contentsOf: withUnsafeBytes(of: expectedDataSize.littleEndian) { Data($0) })

        Log.info("Fixed \(url.lastPathComponent): RIFF \(currentRiffSize)→\(expectedRiffSize), data \(currentDataSize)→\(expectedDataSize)")

        return true
    }

    /// Whether `url` opens as media with at least one audio track. Import asks
    /// up front, so a damaged file fails the import itself instead of a
    /// background job after the import already reported success.
    static func hasAudioTrack(_ url: URL) async -> Bool {
        let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        return !(tracks ?? []).isEmpty
    }

    /// Extract audio from any media file (including video containers) to a native-quality WAV.
    /// Uses AVAssetReader so it handles .mp4, .mov, .webm, etc.
    static func extractAudioToWAV(input: URL, output: URL) async throws {
        let asset = AVURLAsset(url: input)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = audioTracks.first else {
            throw AudioConverterError.noAudioTrack
        }

        // Detect source sample rate and channel count
        let descriptions = try await track.load(.formatDescriptions)
        var sampleRate: Double = 44100
        var channelCount: AVAudioChannelCount = 1
        if let desc = descriptions.first {
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)!.pointee
            sampleRate = asbd.mSampleRate
            channelCount = max(AVAudioChannelCount(asbd.mChannelsPerFrame), 1)
        }

        // More than two channels need an explicit layout on both ends: the
        // plain AVAudioFormat initializer returns nil for them — a 5.1 video
        // or a multichannel WAV crashed the app on the force unwrap — and the
        // reader refuses N > 2 without one. All N channels are kept: the fold
        // to mono happens later, by hand (`convertTo16kHzMonoWAV`).
        let layout = channelCount > 2
            ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channelCount)
            : nil

        let reader = try AVAssetReader(asset: asset)
        var readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
        ]
        if let layout {
            readerSettings[AVChannelLayoutKey] = Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        reader.add(trackOutput)

        let format = layout.map {
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, interleaved: true, channelLayout: $0)
        } ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: channelCount, interleaved: true)
        guard let outputFormat = format else {
            throw AudioConverterError.converterCreationFailed
        }
        let outputFile = try AVAudioFile(
            forWriting: output,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        reader.startReading()
        // Stop background decoding on every exit path — the loop below can throw
        // or break while the reader is still `.reading`. No-op once completed.
        defer { reader.cancelReading() }

        let bytesPerFrame = Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        while reader.status == .reading {
            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else { break }
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            guard numSamples > 0,
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
                  let pcmBuffer = AVAudioPCMBuffer(
                      pcmFormat: outputFormat,
                      frameCapacity: AVAudioFrameCount(numSamples)
                  )
            else { continue }

            pcmBuffer.frameLength = AVAudioFrameCount(numSamples)

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(
                blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &dataPointer
            )

            if let src = dataPointer {
                memcpy(pcmBuffer.int16ChannelData![0], src, min(length, numSamples * bytesPerFrame))
            }

            try outputFile.write(from: pcmBuffer)
        }

        guard reader.status == .completed else {
            throw AudioConverterError.conversionFailed
        }

        Log.info("Extracted audio: \(Int(sampleRate))Hz \(channelCount)ch → \(output.lastPathComponent)")
    }

    /// Compress any audio file to AAC mono .m4a using AVAssetWriter.
    /// Storage preset (compact-meeting-storage): 64 kbps at 24 kHz — half the size of the old
    /// 128 kbps at 48 kHz, chosen by ear over 48 kbps; speaker embeddings stay at cos ≥ 0.996.
    /// `maxOutputRate` exists for the recompress gate (VedivoxBench, preset A = 48 kHz); production
    /// always takes the default.
    static func compressToAAC(input: URL, output: URL, maxOutputRate: Double = 24000) async throws {
        let asset = AVURLAsset(url: input)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = audioTracks.first else {
            throw AudioConverterError.noAudioTrack
        }

        let descriptions = try await track.load(.formatDescriptions)
        var sampleRate: Double = 48000
        if let desc = descriptions.first {
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)!.pointee
            sampleRate = asbd.mSampleRate
        }

        // AAC-LC tops out at 96 kHz and the encoder throws an uncatchable NSException on an
        // unsupported rate/bitrate pair (a 192 kHz import took the whole app down).
        // Cap at 24 kHz — the reader resamples; the models only see up to 8 kHz — and give
        // lower rates the encoder's ceiling — 3 bits per sample in 8 kbps steps (8 kHz → 24,
        // 11.025 → 32, 16 → 48): above it the encoder fails (64 kbps at 16 kHz, Bluetooth mic,
        // 8e5f65f), and scaling down to ~21 kbps cut the band the speaker embeddings use
        // (cos 0.77–0.88 against the original).
        let outputRate = min(sampleRate, maxOutputRate)
        let effectiveBitrate = min(64_000, Int(outputRate * 3) / 8000 * 8000)

        // Reader: decode to PCM float32 mono
        let reader = try AVAssetReader(asset: asset)
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: outputRate,
            AVNumberOfChannelsKey: 1,
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        reader.add(trackOutput)

        // Writer: encode to AAC mono
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outputRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: effectiveBitrate,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        writer.add(writerInput)

        // Every step is checked. Unchecked, a source the reader refused became
        // an empty file reported as a success; a read error halfway, a short
        // file reported as a success; and a refused append (a full disk)
        // waited forever — the writer is never "ready" again, so the block
        // below was not called a second time and the continuation never resumed.
        guard reader.startReading() else {
            throw reader.error ?? AudioConverterError.conversionFailed
        }
        // Same as above: `finishWriting` can leave the reader mid-read on failure.
        defer { reader.cancelReading() }
        guard writer.startWriting() else {
            throw writer.error ?? AudioConverterError.conversionFailed
        }
        writer.startSession(atSourceTime: .zero)

        // These AVFoundation types are not Sendable but we ensure single-threaded
        // access via the serial dispatch queue below.
        nonisolated(unsafe) let input_ = writerInput
        nonisolated(unsafe) let output_ = trackOutput
        nonisolated(unsafe) let writer_ = writer

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "com.vedivox.aac-encode")
            input_.requestMediaDataWhenReady(on: queue) {
                while input_.isReadyForMoreMediaData {
                    if let buffer = output_.copyNextSampleBuffer(), input_.append(buffer) { continue }
                    input_.markAsFinished()
                    if writer_.status == .writing {
                        writer_.finishWriting { continuation.resume() }
                    } else {
                        continuation.resume()
                    }
                    return
                }
            }
        }

        guard writer_.status == .completed, reader.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw writer_.error ?? reader.error ?? AudioConverterError.conversionFailed
        }

        Log.info("Compressed to AAC: \(input.lastPathComponent) → \(output.lastPathComponent) (\(effectiveBitrate / 1000) kbps, \(Int(sampleRate)) → \(Int(outputRate)) Hz)")
    }

    /// Trim audio to a time range. Non-destructive — writes to a new file.
    /// Uses passthrough (no re-encoding) for AAC → AAC.
    static func trimAudio(input: URL, output: URL, from: Double, to: Double) async throws {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds

        let startTime = CMTime(seconds: max(0, from), preferredTimescale: 1000)
        let endTime = CMTime(seconds: min(to, duration), preferredTimescale: 1000)
        let timeRange = CMTimeRange(start: startTime, end: endTime)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw AudioConverterError.converterCreationFailed
        }

        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        session.timeRange = timeRange
        try await session.export(to: output, as: .m4a)

        Log.info("Trimmed audio: \(input.lastPathComponent) [\(String(format: "%.1f", from))s–\(String(format: "%.1f", to))s] → \(output.lastPathComponent)")
    }

    /// Concatenate two audio files into one, stored at the storage preset and verified
    /// against both (`verifyJoin`); on a mismatch `output` is removed and the error thrown.
    /// `compress` is a seam for tests.
    static func mergeAudio(
        file1: URL, file2: URL, output: URL,
        compress: (URL, URL) async throws -> Void = { try await compressToAAC(input: $0, output: $1) }
    ) async throws {
        let asset1 = AVURLAsset(url: file1)
        let asset2 = AVURLAsset(url: file2)

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioConverterError.noAudioTrack
        }

        let track1 = try await asset1.loadTracks(withMediaType: .audio).first
        let track2 = try await asset2.loadTracks(withMediaType: .audio).first

        guard let t1 = track1, let t2 = track2 else {
            throw AudioConverterError.noAudioTrack
        }

        let duration1 = try await asset1.load(.duration)
        let duration2 = try await asset2.load(.duration)

        try track.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration1),
            of: t1, at: .zero
        )
        try track.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration2),
            of: t2, at: duration1
        )

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioConverterError.converterCreationFailed
        }

        // The AppleM4A preset picks its own bitrate, so the join is re-encoded at the
        // storage preset — otherwise a merge would undo compact storage for the meeting.
        let joined = output.deletingPathExtension().appendingPathExtension("joining.m4a")
        try? FileManager.default.removeItem(at: joined)
        defer { try? FileManager.default.removeItem(at: joined) }
        try await session.export(to: joined, as: .m4a)
        try await compress(joined, output)
        do {
            try verifyJoin(parts: [file1, file2], result: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }

        Log.info("Merged audio: \(file1.lastPathComponent) + \(file2.lastPathComponent) → \(output.lastPathComponent) (\(String(format: "%.1f", duration1.seconds + duration2.seconds))s)")
    }

    enum AudioConverterError: Error, LocalizedError {
        case converterCreationFailed
        case conversionFailed
        case trimFailed(String)
        case fileTooSmall
        case notAWAVFile
        case noDataChunk
        case noAudioTrack

        var errorDescription: String? {
            switch self {
            case .converterCreationFailed: "Failed to create audio converter"
            case .conversionFailed: "Audio conversion failed"
            case .trimFailed(let msg): "Audio trim failed: \(msg)"
            case .fileTooSmall: "WAV file is too small"
            case .notAWAVFile: "File is not a valid WAV file"
            case .noDataChunk: "WAV file has no data chunk"
            case .noAudioTrack: "File contains no audio track"
            }
        }
    }
}
