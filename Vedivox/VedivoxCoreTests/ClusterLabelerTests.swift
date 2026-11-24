import XCTest

/// Regression tests for the micro-cluster persona policy in
/// `ClusterLabeler`: an unmatched cluster below the mass floor must never
/// mint a `speaker_N` persona — it folds into the nearest resolved cluster
/// or demotes to UNKNOWN. Synthetic 4-dim embeddings, same convention as
/// `SpeakerMatcherTests`.
final class ClusterLabelerTests: XCTestCase {

    /// Absolute 30s floor, no relative component — keeps the mass-gate cases
    /// independent of track length. The relative floor has its own tests below.
    private let config = ClusterLabeler.Config(
        minNewSpeakerMassSeconds: 30,
        minNewSpeakerMassFraction: 0,
        mergeSimilarityThreshold: 0.70
    )

    /// `count` segments of `duration` seconds each, laid out from `startingAt`
    /// so (start, end) keys never collide across clusters.
    private func segments(
        cluster: String,
        count: Int,
        duration: Double,
        embedding: [Float],
        startingAt: Double
    ) -> [DiarizationService.DiarizationSegment] {
        (0 ..< count).map { i in
            DiarizationService.DiarizationSegment(
                start: startingAt + Double(i) * duration,
                end: startingAt + Double(i + 1) * duration,
                speaker: cluster,
                embedding: embedding
            )
        }
    }

    private func labels(_ output: ClusterLabeler.Output) -> Set<String> {
        Set(output.segments.map(\.speaker))
    }

    // MARK: - Mass gate

    /// A 6s unmatched cluster orthogonal to everything must not become a
    /// persona: its segments demote to UNKNOWN and labelToDbId stays clean.
    func testMicroClusterWithoutNearMatchDemotesToUnknown() {
        let alice = segments(cluster: "1", count: 10, duration: 10, embedding: [1, 0, 0, 0], startingAt: 0)
        let junk = segments(cluster: "2", count: 3, duration: 2, embedding: [0, 0, 0, 1], startingAt: 1000)

        let output = ClusterLabeler(config: config).apply(
            alice + junk,
            speakerEmbeddings: ["1": [1, 0, 0, 0], "2": [0, 0, 0, 1]],
            matchResults: [
                "1": .matched(speakerId: "alice-id", displayName: "Alice", confidence: 0.9),
                "2": .unmatched(reason: .lowSimilarity(topSim: 0.42, topName: "Alice")),
            ]
        )

        XCTAssertEqual(labels(output), ["Alice", "UNKNOWN"])
        XCTAssertEqual(output.labelToDbId, ["Alice": "alice-id"])
    }

    /// A micro-cluster acoustically close to a resolved cluster folds into
    /// that cluster's label instead of UNKNOWN (over-clustered fragment of
    /// the same voice).
    func testMicroClusterFoldsIntoNearestResolvedCluster() {
        let alice = segments(cluster: "1", count: 10, duration: 10, embedding: [1, 0, 0, 0], startingAt: 0)
        let fragment = segments(cluster: "2", count: 3, duration: 2, embedding: [0.95, 0.31, 0, 0], startingAt: 1000)

        let output = ClusterLabeler(config: config).apply(
            alice + fragment,
            speakerEmbeddings: ["1": [1, 0, 0, 0], "2": [0.95, 0.31, 0, 0]],
            matchResults: [
                "1": .matched(speakerId: "alice-id", displayName: "Alice", confidence: 0.9),
                "2": .unmatched(reason: .lowSimilarity(topSim: 0.48, topName: "Alice")),
            ]
        )

        XCTAssertEqual(labels(output), ["Alice"])
    }

    /// An unmatched cluster with enough mass is a genuinely new voice —
    /// it still mints a fresh speaker_N, same as before
    func testBigUnmatchedClusterStillMintsSpeakerN() {
        let alice = segments(cluster: "1", count: 10, duration: 10, embedding: [1, 0, 0, 0], startingAt: 0)
        let newVoice = segments(cluster: "2", count: 6, duration: 10, embedding: [0, 0, 0, 1], startingAt: 1000)

        let output = ClusterLabeler(config: config).apply(
            alice + newVoice,
            speakerEmbeddings: ["1": [1, 0, 0, 0], "2": [0, 0, 0, 1]],
            matchResults: [
                "1": .matched(speakerId: "alice-id", displayName: "Alice", confidence: 0.9),
                "2": .unmatched(reason: .lowSimilarity(topSim: 0.30, topName: "Alice")),
            ]
        )

        XCTAssertEqual(labels(output), ["Alice", "speaker_1"])
    }

    /// The diarizer split one person in two and only one half matched the
    /// canonical: a big rejected cluster that sounds like that half here is
    /// the same person, not a new `speaker_N`.
    func testBigRejectedClusterLikeAMatchedOneJoinsIt() {
        let alice = segments(cluster: "1", count: 10, duration: 10, embedding: [1, 0, 0, 0], startingAt: 0)
        let half = segments(cluster: "2", count: 6, duration: 10, embedding: [0.87, 0.49, 0, 0], startingAt: 1000)

        let output = ClusterLabeler(config: config).apply(
            alice + half,
            speakerEmbeddings: ["1": [1, 0, 0, 0], "2": [0.87, 0.49, 0, 0]],
            matchResults: [
                "1": .matched(speakerId: "alice-id", displayName: "Alice", confidence: 0.85),
                "2": .unmatched(reason: .lowSimilarity(topSim: 0.6, topName: "Alice")),
            ]
        )

        XCTAssertEqual(labels(output), ["Alice"])
    }

    /// The mic track turns the rule off: with only the owner matched there is
    /// no second person to lead, and a voice in the room would become them.
    func testJoinSameVoiceOffKeepsTheClusterApart() {
        var micConfig = config
        micConfig.joinSameVoice = false
        let owner = segments(cluster: "1", count: 10, duration: 10, embedding: [1, 0, 0, 0], startingAt: 0)
        let visitor = segments(cluster: "2", count: 6, duration: 10, embedding: [0.87, 0.49, 0, 0], startingAt: 1000)

        let output = ClusterLabeler(config: micConfig).apply(
            owner + visitor,
            speakerEmbeddings: ["1": [1, 0, 0, 0], "2": [0.87, 0.49, 0, 0]],
            matchResults: [
                "1": .matched(speakerId: "me-id", displayName: "Me", confidence: 0.85),
                "2": .unmatched(reason: .lowSimilarity(topSim: 0.6, topName: "Me")),
            ]
        )

        XCTAssertEqual(labels(output), ["Me", "speaker_1"])
    }

    /// Close to two matched people at once, or not close enough: a new voice.
    func testBigRejectedClusterWithoutAClearSameVoiceStillMints() {
        let alice = segments(cluster: "1", count: 10, duration: 10, embedding: [1, 0, 0, 0], startingAt: 0)
        let bob = segments(cluster: "2", count: 10, duration: 10, embedding: [0.9, 0.436, 0, 0], startingAt: 500)
        let between = segments(cluster: "3", count: 6, duration: 10, embedding: [0.97, 0.24, 0, 0], startingAt: 1000)
        let farther = segments(cluster: "4", count: 6, duration: 10, embedding: [0.75, 0, 0.66, 0], startingAt: 2000)

        let output = ClusterLabeler(config: config).apply(
            alice + bob + between + farther,
            speakerEmbeddings: ["1": [1, 0, 0, 0], "2": [0.9, 0.436, 0, 0], "3": [0.97, 0.24, 0, 0], "4": [0.75, 0, 0.66, 0]],
            matchResults: [
                "1": .matched(speakerId: "alice-id", displayName: "Alice", confidence: 0.9),
                "2": .matched(speakerId: "bob-id", displayName: "Bob", confidence: 0.9),
                "3": .unmatched(reason: .lowSimilarity(topSim: 0.5, topName: "Alice")),
                "4": .unmatched(reason: .lowSimilarity(topSim: 0.5, topName: "Alice")),
            ]
        )

        XCTAssertEqual(labels(output), ["Alice", "Bob", "speaker_1", "speaker_2"], "0.97 к Алисе и 0.98 к Бобу — нет отрыва; 0.75 — ниже 0.80")
    }

    /// A micro-cluster can fold into a speaker_N minted this run (big
    /// unmatched cluster) — fold targets include second-pass labels.
    func testMicroClusterFoldsIntoMintedSpeakerN() {
        let newVoice = segments(cluster: "1", count: 6, duration: 10, embedding: [0, 1, 0, 0], startingAt: 0)
        let fragment = segments(cluster: "2", count: 2, duration: 3, embedding: [0.31, 0.95, 0, 0], startingAt: 1000)

        let output = ClusterLabeler(config: config).apply(
            newVoice + fragment,
            speakerEmbeddings: ["1": [0, 1, 0, 0], "2": [0.31, 0.95, 0, 0]],
            matchResults: [
                "1": .unmatched(reason: .lowSimilarity(topSim: 0.35, topName: "Alice")),
                "2": .unmatched(reason: .lowSimilarity(topSim: 0.41, topName: "Alice")),
            ]
        )

        XCTAssertEqual(labels(output), ["speaker_1"])
    }

    /// Two orthogonal micro-clusters: neither folds into the other, both
    /// demote to UNKNOWN — junk must not chain onto junk.
    func testMicroClustersDoNotChainOntoEachOther() {
        let junkA = segments(cluster: "1", count: 3, duration: 2, embedding: [0, 0, 1, 0], startingAt: 0)
        let junkB = segments(cluster: "2", count: 3, duration: 2, embedding: [0, 0, 0, 1], startingAt: 1000)

        let output = ClusterLabeler(config: config).apply(
            junkA + junkB,
            speakerEmbeddings: ["1": [0, 0, 1, 0], "2": [0, 0, 0, 1]],
            matchResults: [
                "1": .unmatched(reason: .lowSimilarity(topSim: 0.44, topName: "Alice")),
                "2": .unmatched(reason: .lowSimilarity(topSim: 0.40, topName: "Alice")),
            ]
        )

        XCTAssertEqual(labels(output), ["UNKNOWN"])
        XCTAssertTrue(output.labelToDbId.isEmpty)
    }

    /// With an empty enrolled pool (unenrolled import, stage-1 bench) the mass
    /// gate is bypassed: speaker_N labels are the entire output there and
    /// demoting them would erase real speakers.
    func testEmptyPoolBypassesMassGate() {
        let tiny = segments(cluster: "1", count: 3, duration: 2, embedding: [0, 0, 1, 0], startingAt: 0)

        let output = ClusterLabeler(config: config).apply(
            tiny,
            speakerEmbeddings: ["1": [0, 0, 1, 0]],
            matchResults: ["1": .unmatched(reason: .emptyPool)]
        )

        XCTAssertEqual(labels(output), ["speaker_1"])
    }

    /// The relative floor scales with track mass: the same 20s cluster is
    /// junk inside a 1020s track (floor 25.5s) but a real speaker inside a
    /// 200s track (floor 10s).
    func testRelativeFloorScalesWithTrackMass() {
        let relConfig = ClusterLabeler.Config(
            minNewSpeakerMassSeconds: 10,
            minNewSpeakerMassFraction: 0.025,
            mergeSimilarityThreshold: 0.70
        )
        let quiet = segments(cluster: "2", count: 10, duration: 2, embedding: [0, 0, 0, 1], startingAt: 5000)
        let matchResults: [String: SpeakerMatcher.Resolution] = [
            "1": .matched(speakerId: "alice-id", displayName: "Alice", confidence: 0.9),
            "2": .unmatched(reason: .lowSimilarity(topSim: 0.45, topName: "Alice")),
        ]
        let embeddings: [String: [Float]] = ["1": [1, 0, 0, 0], "2": [0, 0, 0, 1]]

        let longTrack = ClusterLabeler(config: relConfig).apply(
            segments(cluster: "1", count: 100, duration: 10, embedding: [1, 0, 0, 0], startingAt: 0) + quiet,
            speakerEmbeddings: embeddings,
            matchResults: matchResults
        )
        XCTAssertEqual(labels(longTrack), ["Alice", "UNKNOWN"])

        let shortTrack = ClusterLabeler(config: relConfig).apply(
            segments(cluster: "1", count: 18, duration: 10, embedding: [1, 0, 0, 0], startingAt: 0) + quiet,
            speakerEmbeddings: embeddings,
            matchResults: matchResults
        )
        XCTAssertEqual(labels(shortTrack), ["Alice", "speaker_1"])
    }

    // MARK: - Split unknown sub-groups

    /// The unknown tail of a split cluster obeys the same mass gate:
    /// below the floor it demotes to UNKNOWN per-segment.
    func testSplitUnknownSubGroupBelowFloorDemotesToUnknown() {
        let cluster = segments(cluster: "1", count: 10, duration: 10, embedding: [1, 0, 0, 0], startingAt: 0)
            + segments(cluster: "1", count: 3, duration: 2, embedding: [0, 0, 0, 1], startingAt: 1000)
        let aliceKeys = cluster.prefix(10).map { SubClusterSplitter.SegmentKey(start: $0.start, end: $0.end) }
        let unknownKeys = cluster.suffix(3).map { SubClusterSplitter.SegmentKey(start: $0.start, end: $0.end) }

        let output = ClusterLabeler(config: config).apply(
            cluster,
            speakerEmbeddings: ["1": [1, 0, 0, 0]],
            matchResults: [
                "1": .splitMatches([
                    SubClusterSplitter.SubGroup(
                        speakerId: "alice-id", displayName: "Alice",
                        segmentKeys: aliceKeys, avgConfidence: 0.8
                    ),
                    SubClusterSplitter.SubGroup(
                        speakerId: nil, displayName: nil,
                        segmentKeys: unknownKeys, avgConfidence: nil
                    ),
                ]),
            ]
        )

        XCTAssertEqual(labels(output), ["Alice", "UNKNOWN"])
        XCTAssertEqual(output.labelToDbId, ["Alice": "alice-id"])
    }

    /// Above the floor the unknown tail still mints a speaker_N.
    func testSplitUnknownSubGroupAboveFloorMintsSpeakerN() {
        let cluster = segments(cluster: "1", count: 10, duration: 10, embedding: [1, 0, 0, 0], startingAt: 0)
            + segments(cluster: "1", count: 5, duration: 10, embedding: [0, 0, 0, 1], startingAt: 2000)
        let aliceKeys = cluster.prefix(10).map { SubClusterSplitter.SegmentKey(start: $0.start, end: $0.end) }
        let unknownKeys = cluster.suffix(5).map { SubClusterSplitter.SegmentKey(start: $0.start, end: $0.end) }

        let output = ClusterLabeler(config: config).apply(
            cluster,
            speakerEmbeddings: ["1": [1, 0, 0, 0]],
            matchResults: [
                "1": .splitMatches([
                    SubClusterSplitter.SubGroup(
                        speakerId: "alice-id", displayName: "Alice",
                        segmentKeys: aliceKeys, avgConfidence: 0.8
                    ),
                    SubClusterSplitter.SubGroup(
                        speakerId: nil, displayName: nil,
                        segmentKeys: unknownKeys, avgConfidence: nil
                    ),
                ]),
            ]
        )

        XCTAssertEqual(labels(output), ["Alice", "speaker_1"])
    }

    /// Mic-track mode (`mintNewSpeakers: false`): even a big unmatched cluster
    /// never mints a persona — echo or bystanders demote to UNKNOWN (or fold).
    func testNoMintModeDemotesRegardlessOfMass() {
        var noMint = config
        noMint.mintNewSpeakers = false
        let echo = segments(cluster: "1", count: 8, duration: 10, embedding: [0, 0, 0, 1], startingAt: 0)

        let output = ClusterLabeler(config: noMint).apply(
            echo,
            speakerEmbeddings: ["1": [0, 0, 0, 1]],
            matchResults: [
                "1": .unmatched(reason: .lowSimilarity(topSim: 0.45, topName: "Alice")),
            ]
        )

        XCTAssertEqual(labels(output), ["UNKNOWN"])
        XCTAssertTrue(output.labelToDbId.isEmpty)
    }

    // MARK: - Numbering

    /// Minted numbers skip past enrolled names that already look like
    /// speaker_N so labels never collide.
    func testMintedNumberSkipsMatchedSpeakerNName() {
        let known = segments(cluster: "1", count: 10, duration: 10, embedding: [1, 0, 0, 0], startingAt: 0)
        let newVoice = segments(cluster: "2", count: 6, duration: 10, embedding: [0, 0, 0, 1], startingAt: 1000)

        let output = ClusterLabeler(config: config).apply(
            known + newVoice,
            speakerEmbeddings: ["1": [1, 0, 0, 0], "2": [0, 0, 0, 1]],
            matchResults: [
                "1": .matched(speakerId: "old-id", displayName: "speaker_3", confidence: 0.9),
                "2": .unmatched(reason: .emptyPool),
            ]
        )

        XCTAssertEqual(labels(output), ["speaker_3", "speaker_4"])
    }

    // MARK: - Reserved labels (speaker-row-per-mint)

    /// Подписи, занятые другой дорожкой этой встречи, двигают нумерацию —
    /// speaker_1 не выдаётся второй раз в одной встрече. Не-числовые подписи
    /// ("me") на нумерацию не влияют.
    func testMintNumbersAfterReservedLabels() {
        let newVoice = segments(cluster: "1", count: 6, duration: 10, embedding: [0, 0, 0, 1], startingAt: 0)

        let output = ClusterLabeler(config: config).apply(
            newVoice,
            speakerEmbeddings: ["1": [0, 0, 0, 1]],
            matchResults: ["1": .unmatched(reason: .lowSimilarity(topSim: 0.2, topName: "Alice"))],
            reservedLabels: ["speaker_1", "speaker_2", "me"]
        )

        XCTAssertEqual(labels(output), ["speaker_3"])
    }


    // MARK: - Invariant: every cluster has a centroid

    /// A cluster present in the segments but absent from `speakerEmbeddings`
    /// (and so from the match results) has nothing to resolve against. Its raw
    /// id must not survive as a label — downstream that mints a persona "3".
    func testClusterWithoutCentroidDemotesToUnknown() {
        let alice = segments(cluster: "1", count: 10, duration: 10, embedding: [1, 0, 0, 0], startingAt: 0)
        let orphan = segments(cluster: "3", count: 5, duration: 10, embedding: [0, 1, 0, 0], startingAt: 1000)

        let output = ClusterLabeler(config: config).apply(
            alice + orphan,
            speakerEmbeddings: ["1": [1, 0, 0, 0]],
            matchResults: ["1": .matched(speakerId: "alice-id", displayName: "Alice", confidence: 0.9)]
        )

        XCTAssertEqual(labels(output), ["Alice", "UNKNOWN"])
        XCTAssertEqual(output.labelToDbId, ["Alice": "alice-id"])
    }

    // MARK: - One label, one record (stage2-out-of-pool)

    /// Bench M4: Нина and Глеб are both confirmed `speaker_1` records. Keyed
    /// by display name they collapsed into one speakerId; the second must get
    /// the next free auto number, and a stranger in the same meeting the one after.
    func testConfirmedAutoLabelCollisionGetsNextFreeNumber() {
        let nina = segments(cluster: "1", count: 5, duration: 10, embedding: [1, 0, 0, 0], startingAt: 0)
        let gleb = segments(cluster: "2", count: 5, duration: 10, embedding: [0, 1, 0, 0], startingAt: 100)
        let stranger = segments(cluster: "3", count: 5, duration: 10, embedding: [0, 0, 1, 0], startingAt: 200)

        let output = ClusterLabeler(config: config).apply(
            nina + gleb + stranger,
            speakerEmbeddings: ["1": [1, 0, 0, 0], "2": [0, 1, 0, 0], "3": [0, 0, 1, 0]],
            matchResults: [
                "1": .matched(speakerId: "nina-id", displayName: "speaker_1", confidence: 0.91),
                "2": .matched(speakerId: "gleb-id", displayName: "speaker_1", confidence: 0.90),
                "3": .unmatched(reason: .lowSimilarity(topSim: 0.40, topName: "speaker_1")),
            ]
        )

        let byStart = Dictionary(uniqueKeysWithValues: output.segments.map { ($0.start, $0.speaker) })
        XCTAssertEqual(byStart[0], "speaker_1")
        XCTAssertEqual(byStart[100], "speaker_2")
        XCTAssertEqual(byStart[200], "speaker_3")
        XCTAssertEqual(output.labelToDbId, ["speaker_1": "nina-id", "speaker_2": "gleb-id"])
    }

    /// Two different records the user named the same: the second keeps the
    /// name with a visible suffix instead of swallowing the first one's speech.
    func testSameGivenNameDifferentSpeakersGetSuffix() {
        let first = segments(cluster: "1", count: 5, duration: 10, embedding: [1, 0, 0, 0], startingAt: 0)
        let second = segments(cluster: "2", count: 5, duration: 10, embedding: [0, 1, 0, 0], startingAt: 100)

        let output = ClusterLabeler(config: config).apply(
            first + second,
            speakerEmbeddings: ["1": [1, 0, 0, 0], "2": [0, 1, 0, 0]],
            matchResults: [
                "1": .matched(speakerId: "katya-a", displayName: "Катя", confidence: 0.9),
                "2": .matched(speakerId: "katya-b", displayName: "Катя", confidence: 0.9),
            ]
        )

        XCTAssertEqual(labels(output), ["Катя", "Катя (2)"])
        XCTAssertEqual(output.labelToDbId, ["Катя": "katya-a", "Катя (2)": "katya-b"])
    }

    /// Mic track: the system track already bound «Катя» to record a. The same
    /// record keeps the label; a namesake gets a distinct one.
    func testBoundLabelsFromOtherTrackAreRespected() {
        let same = segments(cluster: "1", count: 5, duration: 10, embedding: [1, 0, 0, 0], startingAt: 0)
        let namesake = segments(cluster: "2", count: 5, duration: 10, embedding: [0, 1, 0, 0], startingAt: 100)

        let output = ClusterLabeler(config: config).apply(
            same + namesake,
            speakerEmbeddings: ["1": [1, 0, 0, 0], "2": [0, 1, 0, 0]],
            matchResults: [
                "1": .matched(speakerId: "katya-a", displayName: "Катя", confidence: 0.9),
                "2": .matched(speakerId: "katya-b", displayName: "Катя", confidence: 0.9),
            ],
            reservedLabels: ["Катя"],
            boundLabels: ["Катя": "katya-a"]
        )

        let byStart = Dictionary(uniqueKeysWithValues: output.segments.map { ($0.start, $0.speaker) })
        XCTAssertEqual(byStart[0], "Катя")
        XCTAssertEqual(byStart[100], "Катя (2)")
        XCTAssertEqual(output.labelToDbId["Катя (2)"], "katya-b")
    }

    /// A too-short cluster is a micro-cluster: it folds into a resolved
    /// cluster it resembles, else UNKNOWN — it never mints or names.
    func testTooShortClusterFollowsMicroClusterRules() {
        let gleb = segments(cluster: "1", count: 5, duration: 10, embedding: [1, 0, 0, 0], startingAt: 0)
        let near = segments(cluster: "2", count: 1, duration: 3, embedding: [0.9, 0.44, 0, 0], startingAt: 100)
        let far = segments(cluster: "3", count: 1, duration: 3, embedding: [0.58, 0.81, 0, 0], startingAt: 200)

        let output = ClusterLabeler(config: config).apply(
            gleb + near + far,
            speakerEmbeddings: ["1": [1, 0, 0, 0], "2": [0.9, 0.44, 0, 0], "3": [0.58, 0.81, 0, 0]],
            matchResults: [
                "1": .matched(speakerId: "gleb-id", displayName: "Глеб", confidence: 0.9),
                "2": .unmatched(reason: .tooShort(massSeconds: 3, topSim: 0.9, topName: "Глеб")),
                "3": .unmatched(reason: .tooShort(massSeconds: 3, topSim: 0.58, topName: "Глеб")),
            ]
        )
        let byStart = Dictionary(uniqueKeysWithValues: output.segments.map { ($0.start, $0.speaker) })
        XCTAssertEqual(byStart[100], "Глеб")
        XCTAssertEqual(byStart[200], "UNKNOWN")
        XCTAssertEqual(output.labelToDbId, ["Глеб": "gleb-id"])
    }
}
