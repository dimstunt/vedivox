import FluidAudio
import XCTest

/// segment-own-voice § 1: a diarization segment carries the mean of its own
/// cluster's chunk windows, not the cluster centroid.
final class SegmentVoiceTests: XCTestCase {
    private let centroid: [Float] = [1, 1, 0, 0]
    private let voiceA: [Float] = [1, 0, 0, 0]
    private let voiceB: [Float] = [0, 1, 0, 0]

    private func seg(_ start: Double, _ end: Double, _ cluster: String = "S1") -> DiarizationService.DiarizationSegment {
        DiarizationService.DiarizationSegment(start: start, end: end, speaker: cluster, embedding: centroid)
    }

    private func window(_ start: Double, _ end: Double, _ v: [Float], _ cluster: String = "S1") -> ChunkEmbedding {
        ChunkEmbedding(
            speakerId: cluster, chunkIndex: 0, speakerIndex: 0,
            startTimeSeconds: start, endTimeSeconds: end, embedding256: v
        )
    }

    /// Two halves of one merged cluster get the voices of their own windows;
    /// the centroid stays on the segment as `clusterEmbedding`.
    func testHalvesOfMergedClusterGetDifferentVectors() {
        let out = SegmentVoice.ownVectors(
            [seg(0, 10), seg(10, 20)],
            chunks: [window(0, 10, voiceA), window(10, 20, voiceB)]
        )
        XCTAssertEqual(out.segments[0].embedding, voiceA)
        XCTAssertEqual(out.segments[1].embedding, voiceB)
        XCTAssertEqual(out.segments[0].clusterEmbedding, centroid)
        XCTAssertEqual(out.nearestWindow, 0)
        XCTAssertEqual(out.centroid, 0)
    }

    /// Overlap-weighted: 6 s of A against 2 s of B leans to A, and is unit-length.
    func testMeanIsWeightedByOverlap() {
        let out = SegmentVoice.ownVectors(
            [seg(0, 8)],
            chunks: [window(0, 6, voiceA), window(6, 10, voiceB)]
        )
        let v = out.segments[0].embedding
        XCTAssertEqual(v[0] / v[1], 3, accuracy: 1e-5)
        XCTAssertEqual(v.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-5)
    }

    /// A short segment with no window of its own takes the nearest window of
    /// its cluster — never another cluster's, and never a window under 2 s.
    func testSegmentWithoutWindowTakesNearestOfOwnCluster() {
        let out = SegmentVoice.ownVectors(
            [seg(30, 31)],
            chunks: [
                window(0, 10, voiceA),
                window(20, 25, voiceB),
                window(29, 30.5, voiceA), // overlaps, but < 2 s
                window(30, 31, voiceA, "S2"), // other cluster
            ]
        )
        XCTAssertEqual(out.segments[0].embedding, voiceB)
        XCTAssertEqual(out.nearestWindow, 1)
    }

    /// A cluster with no usable window keeps the centroid.
    func testClusterWithoutWindowsKeepsCentroid() {
        let out = SegmentVoice.ownVectors(
            [seg(0, 5, "S3")],
            chunks: [window(0, 5, voiceA, "S1"), window(0, 1, voiceB, "S3")]
        )
        XCTAssertEqual(out.segments[0].embedding, centroid)
        XCTAssertEqual(out.centroid, 1)
    }
}
