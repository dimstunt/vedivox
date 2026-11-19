import AVFoundation
import Foundation

/// Rewrites a recording whose effective sample rate changed mid-capture so
/// every part plays at the correct speed at the file's header rate.
///
/// Input is the rate-segment map produced by `RateSegmentTracker`. Segments
/// whose measured rate snaps to the header rate are copied as-is; deviating
/// segments are resampled (their raw frames are relabeled to the measured
/// device rate, then converted back to the header rate), which restores both
/// speed and pitch.
enum AudioRateCorrector {

    /// Standard audio sample rates for snapping measured values.
    static let standardSampleRates: [Double] = [
        8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000,
    ]

    /// Round a measured sample rate to the nearest standard value.
    static func nearestStandardRate(_ measured: Double) -> Double {
        standardSampleRates.min(by: { abs($0 - measured) < abs($1 - measured) }) ?? measured
    }

    enum CorrectorError: Error {
        case cannotCreateFormat
        case cannotCreateBuffer
        case cannotCreateConverter
    }

    /// Rewrite `url` in place according to `segments`.
    /// Returns false (leaving the file untouched) when no segment deviates
    /// from the header rate after snapping.
    static func correctInPlace(url: URL, segments: [RateSegment]) throws -> Bool {
        let source = try AVAudioFile(forReading: url)
        let headerRate = source.processingFormat.sampleRate
        let totalFrames = source.length

        let snapped = segments.map { nearestStandardRate($0.rate) }
        guard snapped.contains(where: { $0 != headerRate }) else { return false }

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".rate-fix-\(UUID().uuidString).wav")
        let output = try AVAudioFile(
            forWriting: tempURL,
            settings: source.fileFormat.settings,
            commonFormat: source.processingFormat.commonFormat,
            interleaved: source.processingFormat.isInterleaved
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }

        for (index, segment) in segments.enumerated() {
            let start = max(0, min(segment.startFrame, totalFrames))
            let end = index + 1 < segments.count
                ? max(start, min(segments[index + 1].startFrame, totalFrames))
                : totalFrames
            guard end > start else { continue }

            let rate = snapped[index]
            if rate == headerRate {
                try copyFrames(from: source, to: output, start: start, count: end - start)
            } else {
                try resampleFrames(
                    from: source, to: output, start: start, count: end - start,
                    actualRate: rate
                )
            }
        }

        let correctedFrames = output.length
        // Release file handles before swapping files on disk.
        // (AVAudioFile finalizes the header on deallocation; both locals go out
        // of scope after _ = consume below.)
        _ = consume source
        _ = consume output

        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        Log.info(
            "Rate correction rewrote \(url.lastPathComponent): \(totalFrames) → \(correctedFrames) frames "
                + "(\(String(format: "%.1f", Double(totalFrames) / headerRate))s → "
                + "\(String(format: "%.1f", Double(correctedFrames) / headerRate))s at \(Int(headerRate)) Hz)"
        )
        return true
    }

    // MARK: - Segment processing

    private static let chunkFrames: AVAudioFrameCount = 65_536

    private static func copyFrames(
        from source: AVAudioFile, to output: AVAudioFile, start: Int64, count: Int64
    ) throws {
        source.framePosition = start
        var remaining = count
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: source.processingFormat, frameCapacity: chunkFrames
        ) else { throw CorrectorError.cannotCreateBuffer }

        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(Int64(chunkFrames), remaining))
            try source.read(into: buffer, frameCount: toRead)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
            remaining -= Int64(buffer.frameLength)
        }
    }

    private static func resampleFrames(
        from source: AVAudioFile, to output: AVAudioFile,
        start: Int64, count: Int64, actualRate: Double
    ) throws {
        let processing = source.processingFormat
        // Same layout as the file, but labeled with the rate the device
        // actually delivered — the raw samples are reinterpreted, not modified.
        guard let inputFormat = AVAudioFormat(
            commonFormat: processing.commonFormat,
            sampleRate: actualRate,
            channels: processing.channelCount,
            interleaved: processing.isInterleaved
        ) else { throw CorrectorError.cannotCreateFormat }

        guard let converter = AVAudioConverter(from: inputFormat, to: processing) else {
            throw CorrectorError.cannotCreateConverter
        }

        source.framePosition = start

        guard let readBuffer = AVAudioPCMBuffer(
            pcmFormat: processing, frameCapacity: chunkFrames
        ) else { throw CorrectorError.cannotCreateBuffer }

        let outputCapacity = AVAudioFrameCount(
            (Double(chunkFrames) * processing.sampleRate / actualRate).rounded(.up)
        ) + 4096
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: processing, frameCapacity: outputCapacity
        ) else { throw CorrectorError.cannotCreateBuffer }

        // The input block is @Sendable, so mutable streaming state lives in a
        // box. The block only ever runs synchronously inside convert().
        let stream = StreamState(source: source, readBuffer: readBuffer, remaining: count)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if stream.remaining <= 0 {
                outStatus.pointee = .endOfStream
                stream.reachedEnd = true
                return nil
            }
            let toRead = AVAudioFrameCount(min(Int64(chunkFrames), stream.remaining))
            do {
                try stream.source.read(into: stream.readBuffer, frameCount: toRead)
            } catch {
                stream.readError = error
                outStatus.pointee = .endOfStream
                stream.reachedEnd = true
                return nil
            }
            if stream.readBuffer.frameLength == 0 {
                outStatus.pointee = .endOfStream
                stream.reachedEnd = true
                return nil
            }
            stream.remaining -= Int64(stream.readBuffer.frameLength)
            outStatus.pointee = .haveData
            // Relabel: wrap the same PCM bytes in the actual-rate format.
            return Self.relabel(stream.readBuffer, to: inputFormat)
        }

        while !stream.reachedEnd {
            var conversionError: NSError?
            outBuffer.frameLength = 0
            let status = converter.convert(to: outBuffer, error: &conversionError, withInputFrom: inputBlock)
            if let readError = stream.readError { throw readError }
            if let conversionError { throw conversionError }
            if outBuffer.frameLength > 0 {
                try output.write(from: outBuffer)
            }
            if status == .endOfStream || status == .error { break }
        }
    }

    /// Mutable state shared with the @Sendable converter input block. Access
    /// is strictly sequential: convert() invokes the block on the calling thread.
    private final class StreamState: @unchecked Sendable {
        let source: AVAudioFile
        let readBuffer: AVAudioPCMBuffer
        var remaining: Int64
        var reachedEnd = false
        var readError: Error?

        init(source: AVAudioFile, readBuffer: AVAudioPCMBuffer, remaining: Int64) {
            self.source = source
            self.readBuffer = readBuffer
            self.remaining = remaining
        }
    }

    /// Copy a buffer's PCM bytes into a buffer of the same layout labeled with
    /// a different sample rate.
    private static func relabel(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let relabeled = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: buffer.frameLength
        ) else { return nil }
        relabeled.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(relabeled.mutableAudioBufferList)
        for i in 0 ..< min(src.count, dst.count) {
            guard let srcData = src[i].mData, let dstData = dst[i].mData else { continue }
            let bytes = min(src[i].mDataByteSize, dst[i].mDataByteSize)
            memcpy(dstData, srcData, Int(bytes))
            dst[i].mDataByteSize = bytes
        }
        return relabeled
    }
}
