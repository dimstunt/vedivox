import AVFoundation

/// The last seconds of a WAV that is still being written (change
/// `live-speakers`, design D3).
///
/// A recording's writer puts the real sizes into the header only when it
/// stops; until then a reader that trusts the header sees an empty or a short
/// file. The format is right from the first byte, so the audio is found by
/// walking the chunks to `data` — as `AudioConverter.repairWAVHeaderIfNeeded`
/// does after a crash — and its length is taken from the length of the file.
///
/// Read-only: the file is the one copy of the meeting, and it is being written.
enum RecordingTail {
    struct Tail: Equatable, Sendable {
        /// Where the stretch starts, in seconds from the start of the file.
        let from: TimeInterval
        let duration: TimeInterval
    }

    enum Failure: Error, Equatable {
        case notAWAVFile
        /// The header is there, the first frame of audio is not.
        case noAudioYet
        /// Not the Float32 the captures write.
        case notFloat32
    }

    /// Converts the last `seconds` of the audio in `url`, in whole frames, to a
    /// recognition file at `output` (`AudioConverter.convertTo16kHzMonoWAV`).
    /// Straight from the recording: copying the tail out first cost 104 MB of
    /// writes a minute, all through every meeting.
    static func convert(last seconds: TimeInterval, of url: URL, to output: URL) throws -> Tail {
        let reader = try Reader(last: seconds, of: url)
        let tail = reader.tail
        try AudioConverter.convertTo16kHzMonoWAV(name: url.lastPathComponent, output: output) {
            // The same frames again, however far the recording has got.
            reader.rewind()
            return reader
        }
        return tail
    }

    /// A fixed stretch of a WAV as deinterleaved Float32, read from its bytes.
    final class Reader: PCMSource {
        let tail: Tail
        let processingFormat: AVAudioFormat
        let length: AVAudioFramePosition
        private(set) var framePosition: AVAudioFramePosition = 0
        private let source: FileHandle
        private let start: UInt64
        private let channels: Int

        init(last seconds: TimeInterval, of url: URL) throws {
            source = try FileHandle(forReadingFrom: url)
            let fileSize = try source.seekToEnd()
            try source.seek(toOffset: 0)
            // The chunks before the audio fit in the first kilobytes (AVAudioFile
            // pads its header to 4 KB).
            let head = try source.read(upToCount: 64 * 1024) ?? Data()
            guard head.count >= 12, head.prefix(4) == Data("RIFF".utf8), head.subdata(in: 8 ..< 12) == Data("WAVE".utf8) else {
                throw Failure.notAWAVFile
            }
            func number<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
                head.subdata(in: offset ..< offset + MemoryLayout<T>.size).withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
            }

            var format: Data?
            var offset = 12
            while offset + 8 <= head.count, head.subdata(in: offset ..< offset + 4) != Data("data".utf8) {
                let size = Int(number(UInt32.self, at: offset + 4))
                if head.subdata(in: offset ..< offset + 4) == Data("fmt ".utf8), offset + 8 + size <= head.count {
                    format = head.subdata(in: offset + 8 ..< offset + 8 + size)
                }
                offset += 8 + size + size % 2
            }
            guard let format, format.count >= 16, offset + 8 <= head.count else { throw Failure.notAWAVFile }
            // WAVE_FORMAT_EXTENSIBLE names the real format at the start of its GUID.
            var tag = format.subdata(in: 0 ..< 2).withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) }
            if tag == 0xFFFE, format.count >= 26 {
                tag = format.subdata(in: 24 ..< 26).withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) }
            }
            let channelCount = format.subdata(in: 2 ..< 4).withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) }
            let sampleRate = Double(format.subdata(in: 4 ..< 8).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
            let frameBytes = UInt64(format.subdata(in: 12 ..< 14).withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) })
            guard sampleRate > 0, frameBytes > 0 else { throw Failure.notAWAVFile }

            // The size in the `data` header is whatever the writer put there at
            // the start: the audio is everything up to the end of the file.
            let audioStart = UInt64(offset + 8)
            let frames = fileSize > audioStart ? (fileSize - audioStart) / frameBytes : 0
            guard frames > 0 else { throw Failure.noAudioYet }
            let wanted = min(frames, UInt64(max(0, seconds) * sampleRate))
            guard wanted > 0 else { throw Failure.noAudioYet }
            let first = frames - wanted
            guard tag == 3, frameBytes == UInt64(channelCount) * 4,
                  let processingFormat = AudioConverter.float32Format(channels: AVAudioChannelCount(channelCount), sampleRate: sampleRate)
            else { throw Failure.notFloat32 }

            self.processingFormat = processingFormat
            channels = Int(channelCount)
            length = AVAudioFramePosition(wanted)
            start = audioStart + first * frameBytes
            tail = Tail(from: Double(first) / sampleRate, duration: Double(wanted) / sampleRate)
        }

        func rewind() { framePosition = 0 }

        func read(into buffer: AVAudioPCMBuffer) throws {
            buffer.frameLength = 0
            let frameBytes = channels * 4
            let wanted = min(Int(buffer.frameCapacity), Int(length - framePosition))
            guard wanted > 0, let output = buffer.floatChannelData else { return }
            // The blocks are autoreleased: ten minutes of them must not pile up.
            try autoreleasepool {
                try source.seek(toOffset: start + UInt64(framePosition) * UInt64(frameBytes))
                guard let block = try source.read(upToCount: wanted * frameBytes) else { return }
                let frames = block.count / frameBytes
                block.withUnsafeBytes { bytes in
                    for channel in 0 ..< channels {
                        for frame in 0 ..< frames {
                            output[channel][frame] = bytes.loadUnaligned(fromByteOffset: (frame * channels + channel) * 4, as: Float.self)
                        }
                    }
                }
                buffer.frameLength = AVAudioFrameCount(frames)
                framePosition += AVAudioFramePosition(frames)
            }
        }
    }
}
