import Foundation

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
    struct Tail: Equatable {
        /// Where the copied stretch starts, in seconds from the start of the file.
        let from: TimeInterval
        let duration: TimeInterval
    }

    enum Failure: Error, Equatable {
        case notAWAVFile
        /// The header is there, the first frame of audio is not.
        case noAudioYet
    }

    /// Copies the last `seconds` of the audio in `url`, in whole frames and in
    /// its own format, into a finished WAV at `output`.
    ///
    /// shortcut: the tail is copied as recorded (48 kHz, every channel) and the
    /// pipeline converts it after — 115 MB for five minutes of the system
    /// track; convert while reading if the copy shows up in the time of a pass.
    static func copy(last seconds: TimeInterval, of url: URL, to output: URL) throws -> Tail {
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
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
        let audioBytes = wanted * frameBytes

        func bytes(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var header = Data("RIFF".utf8)
        header += bytes(UInt32(clamping: 4 + 8 + UInt64(format.count + format.count % 2) + 8 + audioBytes))
        header += Data("WAVE".utf8) + Data("fmt ".utf8) + bytes(UInt32(format.count)) + format
        if format.count % 2 == 1 { header.append(0) }
        header += Data("data".utf8) + bytes(UInt32(clamping: audioBytes))

        try? FileManager.default.removeItem(at: output)
        guard FileManager.default.createFile(atPath: output.path, contents: header) else { throw CocoaError(.fileWriteUnknown) }
        let destination = try FileHandle(forWritingTo: output)
        defer { try? destination.close() }
        try destination.seekToEnd()
        try source.seek(toOffset: audioStart + first * frameBytes)
        var left = audioBytes
        while left > 0 {
            // A megabyte at a time: five minutes of a stereo track is not held in memory.
            guard let block = try source.read(upToCount: Int(min(left, 1 << 20))), !block.isEmpty else { break }
            try destination.write(contentsOf: block)
            left -= UInt64(block.count)
        }
        return Tail(from: Double(first) / sampleRate, duration: Double(wanted) / sampleRate)
    }
}
