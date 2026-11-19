import AVFoundation
import XCTest

/// fix-multichannel-audio-loss: sound must survive the path from a recording to
/// the transcript, whatever the channel count, and a track must never turn into
/// silence without anyone noticing.
final class AudioIntegrityTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioIntegrityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 1. Channel count fixtures

    /// `AVAudioConverter` returns a full-length file of digital zeros for N > 2
    /// channels. Every layout of speech across channels must come through.
    func testPrepareForRecognitionKeepsSignalForAnyChannelCount() async throws {
        for channels in [1, 2, 3, 6] {
            let layouts: [(name: String, amplitudes: [Float])] = [
                ("all", Array(repeating: 0.5, count: channels)),
                ("ch0", (0 ..< channels).map { $0 == 0 ? 0.5 : 0 }),
                ("ch2", (0 ..< channels).map { $0 == 2 ? 0.5 : 0 }),
            ].filter { $0.amplitudes.contains { $0 > 0 } }

            for layout in layouts {
                let source = tempDir.appendingPathComponent("\(channels)ch-\(layout.name).wav")
                try writeWAV(seconds: 2, rate: 48000, amplitudes: layout.amplitudes, to: source)
                let output = tempDir.appendingPathComponent("\(channels)ch-\(layout.name)-16k.wav")

                try await AudioConverter.convertTo16kHzMonoWAV(input: source, output: output)

                let stats = try readMono(output)
                XCTAssertEqual(stats.duration, 2, accuracy: 0.1, "\(channels)ch/\(layout.name): duration")
                XCTAssertGreaterThan(
                    stats.rmsDBFS, -40,
                    "\(channels)ch/\(layout.name): speech was in the source, result is silence"
                )
            }
        }
    }

    // MARK: - 3. The read loop ends by position

    /// A mid-file I/O error cannot be injected into `AVAudioFile`; what can be
    /// pinned down is that the loop is driven by the file's real length. A WAV
    /// cut in half is, to AVAudioFile, an honest 1 s file — and must convert to
    /// exactly that, not to a header-sized 2 s nor to an error.
    func testTruncatedSourceConvertsToItsRealLength() async throws {
        let source = tempDir.appendingPathComponent("truncated.wav")
        try writeWAV(seconds: 2, rate: 48000, amplitudes: [0.5], to: source)
        let handle = try FileHandle(forWritingTo: source)
        let fullSize = try handle.seekToEnd()
        try handle.truncate(atOffset: fullSize / 2)
        try handle.close()
        let realSeconds = Double(try AVAudioFile(forReading: source).length) / 48000

        let output = tempDir.appendingPathComponent("truncated-16k.wav")
        try await AudioConverter.convertTo16kHzMonoWAV(input: source, output: output)

        let stats = try readMono(output)
        XCTAssertEqual(stats.duration, realSeconds, accuracy: 0.01)
        XCTAssertLessThan(realSeconds, 1.1, "the fixture is not actually truncated")
    }

    // MARK: - 2a. Capture path: channel remap without the system converter

    func testRemapChannelsFoldsThreeToOneAndSpreadsOneToThree() throws {
        let three = try XCTUnwrap(Self.format(channels: 3, rate: 48000))
        let buffer = AVAudioPCMBuffer(pcmFormat: three, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for c in 0 ..< 3 {
            for i in 0 ..< 4800 { buffer.floatChannelData![c][i] = 0.5 * sin(Float(i) * 0.05) }
        }

        // 3 → 1: the very conversion that zeroed the September recordings.
        let mono = try XCTUnwrap(AudioConverter.remapChannels(buffer, to: 1))
        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(mono.frameLength, 4800)
        XCTAssertEqual(Self.peak(mono, channel: 0), 0.5, accuracy: 0.01)

        // 1 → 3: the file stayed 3ch while the device went back to mono.
        let back = try XCTUnwrap(AudioConverter.remapChannels(mono, to: 3, layout: three.channelLayout))
        XCTAssertEqual(back.format.channelCount, 3)
        for c in 0 ..< 3 { XCTAssertEqual(Self.peak(back, channel: c), 0.5, accuracy: 0.01, "channel \(c)") }

        // Both must be writable into files opened the way MicrophoneCapture opens them.
        let monoFile = try micStyleFile(format: mono.format, name: "remap-1ch.wav")
        XCTAssertNoThrow(try monoFile.write(from: mono))
        let threeFile = try micStyleFile(format: three, name: "remap-3ch.wav")
        XCTAssertNoThrow(try threeFile.write(from: back))
    }

    private func micStyleFile(format: AVAudioFormat, name: String) throws -> AVAudioFile {
        try AVAudioFile(
            forWriting: tempDir.appendingPathComponent(name),
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: !format.isInterleaved,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: format.isInterleaved
        )
    }

    /// Speech in one channel of three keeps its level: silent channels are left
    /// out of the average instead of pulling it down by 9.5 dB (design § решение 2).
    func testDownmixLeavesSilentChannelsOut() throws {
        let three = try XCTUnwrap(Self.format(channels: 3, rate: 48000))
        let buffer = AVAudioPCMBuffer(pcmFormat: three, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for i in 0 ..< 4800 { buffer.floatChannelData![2][i] = 0.5 * sin(Float(i) * 0.05) }

        let mono = AudioConverter.downmixToMono(buffer)
        XCTAssertEqual(Self.peak(mono, channel: 0), 0.5, accuracy: 0.01)
    }

    // MARK: - 2b. Quiet tracks are lifted before recognition

    func testQuietTrackIsNormalizedAndLoudTrackIsLeftAlone() async throws {
        // −68 dBFS RMS: the level the system leaves the mic at during a phone call.
        let quiet = tempDir.appendingPathComponent("quiet.wav")
        try writeWAV(seconds: 1, rate: 48000, amplitudes: [0.00056], to: quiet)
        let quietOut = tempDir.appendingPathComponent("quiet-16k.wav")
        try await AudioConverter.convertTo16kHzMonoWAV(input: quiet, output: quietOut)
        XCTAssertEqual(try readMono(quietOut).peak, AudioConverter.normalizeTargetPeak, accuracy: 0.02)

        let loud = tempDir.appendingPathComponent("loud.wav")
        try writeWAV(seconds: 1, rate: 48000, amplitudes: [0.9], to: loud)
        let loudOut = tempDir.appendingPathComponent("loud-16k.wav")
        try await AudioConverter.convertTo16kHzMonoWAV(input: loud, output: loudOut)
        XCTAssertEqual(try readMono(loudOut).peak, 0.9, accuracy: 0.02)
    }

    // MARK: - 4. Result is verified against the source

    func testVerifyRejectsSilenceFromASoundingSource() throws {
        let source = tempDir.appendingPathComponent("v-source.wav")
        try writeWAV(seconds: 2, rate: 16000, amplitudes: [0.5], to: source)
        let silence = tempDir.appendingPathComponent("v-silence.wav")
        try writeWAV(seconds: 2, rate: 16000, amplitudes: [0], to: silence)

        XCTAssertThrowsError(try AudioConverter.verify(source: source, result: silence))
        XCTAssertNoThrow(try AudioConverter.verify(source: source, result: silence, requireEnergy: false))
    }

    func testVerifyRejectsAShorterResult() throws {
        let source = tempDir.appendingPathComponent("v-long.wav")
        try writeWAV(seconds: 2, rate: 16000, amplitudes: [0.5], to: source)
        let short = tempDir.appendingPathComponent("v-short.wav")
        try writeWAV(seconds: 1, rate: 16000, amplitudes: [0.5], to: short)

        XCTAssertThrowsError(try AudioConverter.verify(source: source, result: short))
    }

    func testVerifyAcceptsAnHonestlySilentSource() throws {
        let source = tempDir.appendingPathComponent("v-quiet-source.wav")
        try writeWAV(seconds: 2, rate: 16000, amplitudes: [0.001], to: source)
        let result = tempDir.appendingPathComponent("v-quiet-result.wav")
        try writeWAV(seconds: 2, rate: 16000, amplitudes: [0], to: result)

        XCTAssertNoThrow(try AudioConverter.verify(source: source, result: result))
        XCTAssertFalse(try AudioConverter.trackStats(of: source).sounded)
    }

    // MARK: - 6. The source outlives a failed compression

    func testCompressAndReplaceDeletesTheWavOnlyAfterVerification() async throws {
        let wav = tempDir.appendingPathComponent("c.wav")
        try writeWAV(seconds: 2, rate: 48000, amplitudes: [0.5], to: wav)
        let m4a = tempDir.appendingPathComponent("c.m4a")

        try await AudioConverter.compressAndReplace(wav: wav, m4a: m4a)

        XCTAssertTrue(FileManager.default.fileExists(atPath: m4a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
        XCTAssertTrue(try AudioConverter.trackStats(of: m4a).sounded)
    }

    /// The failure branch: the WAV is the only copy of the
    /// recording, so a compression that fails must leave it and no m4a.
    func testCompressAndReplaceKeepsTheWavWhenCompressionFails() async throws {
        let wav = tempDir.appendingPathComponent("keep.wav")
        try writeWAV(seconds: 2, rate: 48000, amplitudes: [0.5], to: wav)
        try unfinalize(wav)
        let m4a = tempDir.appendingPathComponent("keep.m4a")

        do {
            try await AudioConverter.compressAndReplace(wav: wav, m4a: m4a)
            XCTFail("an unreadable source must not count as compressed")
        } catch {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path), "the recording survives")
        XCTAssertFalse(FileManager.default.fileExists(atPath: m4a.path))
    }

    // MARK: - 6a. Import: a multichannel file through the extraction step

    /// An imported file is extracted to mic.wav before anything else, and that
    /// step built its format with the initializer that returns nil above two
    /// channels — a 5.1 video or a multichannel WAV crashed the app. The whole
    /// import path must keep speech that sits in one channel of several.
    func testImportExtractionKeepsSignalOfAMultichannelFile() async throws {
        for channels in [3, 6] {
            let source = tempDir.appendingPathComponent("import-\(channels)ch.wav")
            try writeWAV(seconds: 2, rate: 48000, amplitudes: (0 ..< channels).map { $0 == 2 ? 0.5 : 0 }, to: source)
            let extracted = tempDir.appendingPathComponent("import-\(channels)ch-mic.wav")
            let mono = tempDir.appendingPathComponent("import-\(channels)ch-16k.wav")

            try await AudioConverter.extractAudioToWAV(input: source, output: extracted)
            try await AudioConverter.convertTo16kHzMonoWAV(input: extracted, output: mono)

            let stats = try readMono(mono)
            XCTAssertEqual(stats.duration, 2, accuracy: 0.05, "\(channels) ch")
            XCTAssertGreaterThan(stats.rmsDBFS, -30, "\(channels) ch")
        }
    }

    // MARK: - 7. A recording cut off by a crash or a quit (header never finalized)

    /// What a crash leaves behind: all the audio on disk and a header that still
    /// says "no data yet" (RIFF = header size, data = 0, measured on a killed
    /// writer). `AVAudioFile` reads such a file as empty.
    private func unfinalize(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let head = try XCTUnwrap(try handle.read(upToCount: 8192))
        let dataTag = try XCTUnwrap(head.range(of: Data("data".utf8)))
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Self.le(UInt32(dataTag.lowerBound)))
        try handle.seek(toOffset: UInt64(dataTag.lowerBound + 4))
        try handle.write(contentsOf: Self.le(0))
    }

    private static func le(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    func testRepairRestoresARecordingLeftWithoutAFinalizedHeader() throws {
        let wav = tempDir.appendingPathComponent("crashed.wav")
        try writeWAV(seconds: 2, rate: 48000, amplitudes: [0.5, 0.5], to: wav)
        try unfinalize(wav)
        XCTAssertEqual(try AVAudioFile(forReading: wav).length, 0, "the fixture must read as empty, like a crashed recording")

        XCTAssertTrue(try AudioConverter.repairWAVHeaderIfNeeded(wav))

        XCTAssertEqual(try AVAudioFile(forReading: wav).length, 96000)
        XCTAssertFalse(try AudioConverter.repairWAVHeaderIfNeeded(wav), "a repaired file needs no second repair")
    }

    /// A source the reader refuses (here: the crashed recording above) used to
    /// "compress" into an empty file reported as a success.
    func testCompressFailsOnASourceItCannotRead() async throws {
        let wav = tempDir.appendingPathComponent("unreadable.wav")
        try writeWAV(seconds: 2, rate: 48000, amplitudes: [0.5], to: wav)
        try unfinalize(wav)
        let m4a = tempDir.appendingPathComponent("unreadable.m4a")

        do {
            try await AudioConverter.compressToAAC(input: wav, output: m4a)
            XCTFail("nothing was read, so nothing was compressed")
        } catch {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: m4a.path), "no empty file left behind")
    }

    /// Recovery can be handed an imported original. A finalized WAV with a
    /// metadata chunk after the audio has a data chunk honestly shorter than
    /// the file — "repairing" it turned the metadata into noise.
    func testRepairLeavesAFinalizedFileWithTrailingMetadataAlone() throws {
        let wav = tempDir.appendingPathComponent("tagged.wav")
        try writeWAV(seconds: 1, rate: 48000, amplitudes: [0.5], to: wav)
        let handle = try FileHandle(forUpdating: wav)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("LIST".utf8) + Self.le(12) + Data("INFOmetadata".utf8))
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Self.le(UInt32(size - 8)))
        try handle.close()
        let before = try Data(contentsOf: wav)

        XCTAssertFalse(try AudioConverter.repairWAVHeaderIfNeeded(wav))

        XCTAssertEqual(try Data(contentsOf: wav), before)
    }

    /// A long recording passes 4 GiB (48 kHz stereo float: 3.1 h). The repair
    /// used to read the whole file into memory and trap on the 32-bit size — at
    /// every launch, since recovery runs at launch. A sparse file stands in for
    /// the real thing.
    func testRepairHandlesAFileLargerThanFourGigabytes() throws {
        let wav = tempDir.appendingPathComponent("huge.wav")
        try writeWAV(seconds: 1, rate: 48000, amplitudes: [0.5], to: wav)
        try unfinalize(wav)
        let handle = try FileHandle(forUpdating: wav)
        try handle.truncate(atOffset: 5 << 30)
        try handle.close()

        XCTAssertTrue(try AudioConverter.repairWAVHeaderIfNeeded(wav))

        let head = try FileHandle(forReadingFrom: wav).read(upToCount: 8) ?? Data()
        XCTAssertEqual(head.suffix(4), Self.le(.max), "sizes past 32 bits are clamped, not wrapped")
    }

    static func peak(_ buffer: AVAudioPCMBuffer, channel: Int) -> Float {
        var p: Float = 0
        for i in 0 ..< Int(buffer.frameLength) { p = max(p, abs(buffer.floatChannelData![channel][i * buffer.stride])) }
        return p
    }

    // MARK: - Helpers

    struct MonoStats {
        let duration: Double
        let rmsDBFS: Float
        let peak: Float
    }

    func readMono(_ url: URL) throws -> MonoStats {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        var acc: Float = 0
        var peak: Float = 0
        if let data = buffer.floatChannelData?[0] {
            for i in 0 ..< n {
                acc += data[i] * data[i]
                peak = max(peak, abs(data[i]))
            }
        }
        let rms = n > 0 ? (acc / Float(n)).squareRoot() : 0
        return MonoStats(
            duration: Double(file.length) / file.processingFormat.sampleRate,
            rmsDBFS: rms > 0 ? 20 * log10(rms) : -.infinity,
            peak: peak
        )
    }

    /// Float32 non-interleaved WAV, one 440 Hz sine per channel scaled by
    /// `amplitudes[channel]`. N > 2 channels need an explicit layout —
    /// `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)` returns nil.
    func writeWAV(seconds: Double, rate: Double, amplitudes: [Float], to url: URL) throws {
        let format = try XCTUnwrap(Self.format(channels: amplitudes.count, rate: rate))
        let frames = Int(seconds * rate)
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for (c, amplitude) in amplitudes.enumerated() {
            for i in 0 ..< frames {
                buffer.floatChannelData![c][i] = amplitude * Float(sin(2.0 * .pi * 440 * Double(i) / rate))
            }
        }
        try file.write(from: buffer)
    }

    static func format(channels: Int, rate: Double) -> AVAudioFormat? {
        if channels <= 2 {
            return AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate,
                channels: AVAudioChannelCount(channels), interleaved: false
            )
        }
        guard let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        ) else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
    }
}
