import AVFoundation
import XCTest

/// What an IOProc hands over, turned into the buffers the capture is built
/// around — the part of the direct HAL input that needs no device.
final class HALInputTests: XCTestCase {

    /// An AudioBufferList the way the HAL passes one: a buffer per stream,
    /// each with its channels interleaved. `nil` samples: a stream that is off.
    private func withList<T>(
        _ streams: [(channels: Int, samples: [Float32]?)], _ body: (UnsafePointer<AudioBufferList>) throws -> T
    ) rethrows -> T {
        let list = AudioBufferList.allocate(maximumBuffers: streams.count)
        defer {
            for buffer in list { buffer.mData?.deallocate() }
            free(list.unsafeMutablePointer)
        }
        for (index, stream) in streams.enumerated() {
            var data: UnsafeMutablePointer<Float32>?
            if let samples = stream.samples {
                data = .allocate(capacity: max(samples.count, 1))
                data?.initialize(from: samples, count: samples.count)
            }
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(stream.channels),
                mDataByteSize: UInt32((stream.samples?.count ?? 8) * MemoryLayout<Float32>.size),
                mData: UnsafeMutableRawPointer(data)
            )
        }
        return try body(UnsafePointer(list.unsafeMutablePointer))
    }

    private func format(_ channels: AVAudioChannelCount) throws -> AVAudioFormat {
        try XCTUnwrap(AudioConverter.float32Format(channels: channels, sampleRate: 48_000))
    }

    private func channel(_ buffer: AVAudioPCMBuffer, _ index: Int) throws -> [Float32] {
        let data = try XCTUnwrap(buffer.floatChannelData?[index])
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    func testMonoStreamIsCopiedAsItIs() throws {
        let buffer = try XCTUnwrap(withList([(1, [0.1, 0.2, 0.3])]) { HALInput.deinterleaved($0, format: try format(1)) })
        XCTAssertEqual(buffer.frameLength, 3)
        XCTAssertFalse(buffer.format.isInterleaved)
        XCTAssertEqual(try channel(buffer, 0), [0.1, 0.2, 0.3])
    }

    /// One stereo stream: L R L R in one buffer.
    func testInterleavedStreamIsSplitIntoChannels() throws {
        let buffer = try XCTUnwrap(withList([(2, [1, -1, 2, -2, 3, -3])]) { HALInput.deinterleaved($0, format: try format(2)) })
        XCTAssertEqual(buffer.frameLength, 3)
        XCTAssertEqual(try channel(buffer, 0), [1, 2, 3])
        XCTAssertEqual(try channel(buffer, 1), [-1, -2, -3])
    }

    /// Two streams — a stereo one and a mono one — are three channels in order.
    func testSeveralStreamsFillTheChannelsInOrder() throws {
        let buffer = try XCTUnwrap(
            withList([(2, [1, -1, 2, -2]), (1, [7, 8])]) { HALInput.deinterleaved($0, format: try format(3)) }
        )
        XCTAssertEqual(buffer.frameLength, 2)
        XCTAssertEqual(try channel(buffer, 0), [1, 2])
        XCTAssertEqual(try channel(buffer, 1), [-1, -2])
        XCTAssertEqual(try channel(buffer, 2), [7, 8])
    }

    /// The device changed under the IOProc: the cycle is dropped, not written
    /// with channels that are not there.
    func testAListThatIsNotTheFormatIsDropped() throws {
        XCTAssertNil(try withList([(1, [0.1, 0.2])]) { HALInput.deinterleaved($0, format: try format(2)) })
        XCTAssertNil(try withList([(2, [1, -1, 2, -2])]) { HALInput.deinterleaved($0, format: try format(1)) })
        XCTAssertNil(try withList([(1, [])]) { HALInput.deinterleaved($0, format: try format(1)) }, "an empty cycle")
    }

    /// Cycles the device skipped for us are counted by its sample counter:
    /// whole cycles only, and not the long breaks the capture fills by the clock.
    func testSkippedCyclesAreCountedByTheSampleCounter() {
        let limit = 12_000 // 0.25 s at 48 kHz
        func missed(_ expected: Double?, _ actual: Double) -> Int {
            HALInput.missedFrames(expected: expected, actual: actual, cycle: 512, limit: limit)
        }
        XCTAssertEqual(missed(nil, 10_000), 0, "the first cycle: nothing to compare with")
        XCTAssertEqual(missed(10_512, 10_512), 0, "contiguous")
        XCTAssertEqual(missed(10_512, 11_024), 512, "one cycle skipped")
        XCTAssertEqual(missed(10_512, 12_048), 1_536, "three cycles skipped")
        XCTAssertEqual(missed(10_512, 10_513), 0, "a frame of wobble is not a skipped cycle")
        XCTAssertEqual(missed(10_512, 512), 0, "the counter went back: a restart, not a skip")
        XCTAssertEqual(missed(10_512, 10_512 + 12_000), 0, "a long break is the capture's to fill")
        XCTAssertEqual(missed(10_512, 10_512 + 11_776), 11_776, "just under the limit")
    }

    /// A stream that is switched off comes with no memory behind it.
    func testAStreamThatIsOffIsDropped() throws {
        XCTAssertNil(try withList([(1, nil)]) { HALInput.deinterleaved($0, format: try format(1)) })
        // The second stream is shorter than the first says a cycle is.
        XCTAssertNil(try withList([(1, [1, 2, 3]), (1, [1])]) { HALInput.deinterleaved($0, format: try format(2)) })
    }
}
