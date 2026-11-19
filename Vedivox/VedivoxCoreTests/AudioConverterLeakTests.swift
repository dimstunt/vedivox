import AVFoundation
import XCTest

/// Regression tests for the imported-file descriptor leak.
///
/// Symptom: after importing video meetings, Vedivox held read fds on
/// `~/Library/Application Support/Vedivox/audio/<id>/original.mov` files that the
/// pipeline had already deleted — 10 handles / 5.35 GB of invisible disk space
/// that only came back on restart.
///
/// Cause: while the import is still running the freshly created meeting is
/// already selected, so `micAudioPath` is empty and playback/waveform fall back
/// to `sourceFilePath` (the original `.mov`). `AVAudioFile(forReading:)` never
/// releases its fd for QuickTime containers.
final class AudioConverterLeakTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioConverterLeakTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Direct-read guard

    func testVideoContainersAreNotSafeForDirectRead() {
        for ext in ["mov", "MOV", "mp4", "webm", "ogg"] {
            let url = URL(fileURLWithPath: "/tmp/original.\(ext)")
            XCTAssertFalse(
                AudioConverter.isSafeForDirectRead(url),
                ".\(ext) must never reach AVAudioFile — it is the fd leak path"
            )
        }
    }

    func testPlainAudioIsSafeForDirectRead() {
        for ext in ["wav", "WAV", "m4a", "mp3", "aiff", "aif", "caf"] {
            let url = URL(fileURLWithPath: "/tmp/original.\(ext)")
            XCTAssertTrue(
                AudioConverter.isSafeForDirectRead(url),
                ".\(ext) is a plain audio container and should stay playable"
            )
        }
    }

    // MARK: - Converter must not retain descriptors

    /// `extractAudioToWAV` opens the source through AVAssetReader. Guards against
    /// a future change that abandons the reader and starts retaining handles.
    func testExtractAudioToWAVReleasesFileDescriptors() async throws {
        let source = tempDir.appendingPathComponent("source.wav")
        try writeWAV(seconds: 1, rate: 16000, to: source)

        // Warm-up: first run pulls in AVFoundation's own long-lived resources.
        let warmInput = tempDir.appendingPathComponent("warm.wav")
        try FileManager.default.copyItem(at: source, to: warmInput)
        try await AudioConverter.extractAudioToWAV(
            input: warmInput, output: tempDir.appendingPathComponent("warm-out.wav")
        )
        try FileManager.default.removeItem(at: warmInput)

        let baseline = openFileDescriptorCount()

        let runs = 5
        for i in 0 ..< runs {
            let input = tempDir.appendingPathComponent("in-\(i).wav")
            try FileManager.default.copyItem(at: source, to: input)
            try await AudioConverter.extractAudioToWAV(
                input: input, output: tempDir.appendingPathComponent("out-\(i).wav")
            )
            // The pipeline deletes the original once the import finishes.
            try FileManager.default.removeItem(at: input)
        }

        let growth = openFileDescriptorCount() - baseline
        XCTAssertLessThan(
            growth, runs,
            "converter retained ~1 fd per conversion (grew by \(growth) over \(runs) runs)"
        )
    }

    // MARK: - Unsupported sample rates

    /// A 192 kHz import made `AVAssetWriterInput` throw an NSException (uncatchable from
    /// Swift) and abort the app; 128 kbps did the same at 16 kHz. Every input rate must get a
    /// rate/bitrate pair the encoder accepts, capped at the 24 kHz storage rate.
    func testCompressToAACAcceptsEveryInputRate() async throws {
        for rate in [8000.0, 11025, 16000, 22050, 24000, 44100, 48000, 192_000] {
            let source = tempDir.appendingPathComponent("in-\(Int(rate)).wav")
            try writeWAV(seconds: 0.5, rate: rate, to: source)
            let output = tempDir.appendingPathComponent("out-\(Int(rate)).m4a")

            do {
                try await AudioConverter.compressToAAC(input: source, output: output)
            } catch {
                XCTFail("\(Int(rate)) Hz: \(error)")
                continue
            }

            let result = try AVAudioFile(forReading: output)
            XCTAssertEqual(result.fileFormat.sampleRate, min(rate, 24000), "\(rate) Hz")
            XCTAssertEqual(result.fileFormat.channelCount, 1)
            XCTAssertGreaterThan(result.length, 0)
        }
    }

    /// The merge export preset picks its own bitrate; the join must come out at the storage
    /// preset, or merging two meetings would undo compact storage for them.
    func testMergeAudioStoresAtStoragePreset() async throws {
        let first = tempDir.appendingPathComponent("a.wav")
        let second = tempDir.appendingPathComponent("b.wav")
        try writeWAV(seconds: 3, rate: 48000, to: first, noise: true)
        try writeWAV(seconds: 3, rate: 48000, to: second, noise: true)
        let output = tempDir.appendingPathComponent("merged.m4a")

        try await AudioConverter.mergeAudio(file1: first, file2: second, output: output)

        let result = try AVAudioFile(forReading: output)
        let seconds = Double(result.length) / result.fileFormat.sampleRate
        let bytes = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int)
        XCTAssertEqual(result.fileFormat.sampleRate, 24000)
        XCTAssertEqual(seconds, 6, accuracy: 0.1)
        // 64 kbps nominal; 10% headroom for the container.
        XCTAssertLessThanOrEqual(Double(bytes * 8) / seconds, 64_000 * 1.1)
    }

    /// A join shorter than its parts (a truncated re-encode) is refused: no output, parts intact.
    func testMergeAudioRefusesAShortJoin() async throws {
        let first = tempDir.appendingPathComponent("a.wav")
        let second = tempDir.appendingPathComponent("b.wav")
        try writeWAV(seconds: 3, rate: 48000, to: first, noise: true)
        try writeWAV(seconds: 3, rate: 48000, to: second, noise: true)
        let before = try [first, second].map { try Data(contentsOf: $0) }
        let output = tempDir.appendingPathComponent("merged.m4a")

        do {
            // Only the first part makes it into the "join".
            try await AudioConverter.mergeAudio(file1: first, file2: second, output: output) { _, out in
                try await AudioConverter.compressToAAC(input: first, output: out)
            }
            XCTFail("a 3 s join of 3 s + 3 s must be refused")
        } catch AudioConverter.AudioIntegrityError.durationMismatch {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try [first, second].map { try Data(contentsOf: $0) }, before)
    }

    /// Full length but the second half silent: the energy the later part had is gone.
    func testVerifyJoinCatchesASilentHalf() throws {
        let first = tempDir.appendingPathComponent("a.wav")
        let second = tempDir.appendingPathComponent("b.wav")
        let result = tempDir.appendingPathComponent("join.wav")
        try writeWAV(seconds: 3, rate: 48000, to: first, noise: true)
        try writeWAV(seconds: 3, rate: 48000, to: second, noise: true)
        try writeWAV(seconds: 6, rate: 48000, to: result, noise: true, silentFrom: 3)

        XCTAssertThrowsError(try AudioConverter.verifyJoin(parts: [first, second], result: result)) {
            guard case AudioConverter.AudioIntegrityError.energyLost = $0 else { return XCTFail("\($0)") }
        }
        let whole = tempDir.appendingPathComponent("whole.wav")
        try writeWAV(seconds: 6, rate: 48000, to: whole, noise: true)
        XCTAssertNoThrow(try AudioConverter.verifyJoin(parts: [first, second], result: whole))
    }

    // MARK: - Helpers

    private func openFileDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }

    private func writeWAV(seconds: Double, rate: Double, to url: URL, noise: Bool = false, silentFrom: Double = .infinity) throws {
        let frames = Int(seconds * rate)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: true,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0 ..< frames {
            buffer.floatChannelData![0][i] = Double(i) / rate >= silentFrom ? 0 : noise
                ? Float.random(in: -0.5 ... 0.5)
                : Float(sin(2.0 * .pi * 440 * Double(i) / rate)) * 0.5
        }
        try file.write(from: buffer)
    }
}
