import Foundation
import XCTest

/// Replay of the separability invariant
/// on a SNAPSHOT of the real database: for every confirmed speaker with a v2
/// canonical, what the new check would decide — nothing is written. Each
/// speaker is judged twice, against the shortlisted neighbours and against
/// every confirmed speaker; the two verdicts must agree (design § 2).
///
/// The live database is never opened — take a snapshot first:
///
///     sqlite3 ~/Library/Application\ Support/Vedivox/Vedivox.sqlite ".backup '/path/to/replay.sqlite'"
///     TEST_RUNNER_VEDIVOX_REPLAY_DB=/path/to/replay.sqlite xcodebuild test \
///       -project Vedivox/Vedivox.xcodeproj -scheme VedivoxBench \
///       -only-testing:VedivoxBench/SeparabilityReplay -destination 'platform=macOS' \
///       -derivedDataPath build
///
/// The table carries real speaker names: it goes to the test output only.
final class SeparabilityReplay: XCTestCase {

    func testReplaySeparability() async throws {
        guard let path = ProcessInfo.processInfo.environment["VEDIVOX_REPLAY_DB"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_VEDIVOX_REPLAY_DB to a snapshot of Vedivox.sqlite")
        }
        let snapshot = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        XCTAssertFalse(
            snapshot.contains("/Application Support/Vedivox/"),
            "VEDIVOX_REPLAY_DB must be a snapshot outside the Vedivox data directory, not the live database"
        )
        guard !snapshot.contains("/Application Support/Vedivox/") else { return }

        let repo = SpeakerRepository(db: try DatabaseManager(readOnlySnapshot: snapshot))
        let config = SpeakerRepository.RecalcConfig.default
        let speakers = try await repo.confirmedSpeakersWithEmbeddings(space: .v2)

        // Voices and live canonicals once per speaker: the "everyone" pass
        // would otherwise rebuild all of them for each speaker.
        var selections: [String: SpeakerRepository.CanonicalSelection] = [:]
        var voiceCounts: [String: Int] = [:]
        for speaker in speakers {
            let voices = try await repo.perMeetingVoices(speakerId: speaker.id, space: .v2)
            voiceCounts[speaker.id] = voices.count
            selections[speaker.id] = SpeakerRepository.canonicalSelection(voices, config: config)
        }
        let columns = speakers.map { SeparabilityCheck.Neighbor(id: $0.id, name: $0.name, canonical: $0.canonical) }
        // Same rule as `SpeakerRepository.separability`: live canonical, stored when no voices.
        func live(_ neighbors: [SeparabilityCheck.Neighbor]) -> [SeparabilityCheck.Neighbor] {
            neighbors.map {
                SeparabilityCheck.Neighbor(id: $0.id, name: $0.name,
                                           canonical: selections[$0.id]?.canonical ?? $0.canonical)
            }
        }

        var lines = ["speaker | id | voices | negative | mass | median gap | verdict | neighbour | sim | offending meetings→nearest | all neighbours"]
        var disagreements = 0
        for speaker in speakers {
            guard let selection = selections[speaker.id] else {
                lines.append("\(speaker.name) | \(speaker.id.prefix(8)) | 0 | – | – | – | no voices | | | |")
                continue
            }
            let others = columns.filter { $0.id != speaker.id }
            let shortlisted = SeparabilityCheck.evaluate(
                selection,
                neighbors: live(SeparabilityCheck.shortlist(selection, columns: others, config: config.separability)),
                config: config, space: .v2
            )
            let everyone = SeparabilityCheck.evaluate(selection, neighbors: live(others), config: config, space: .v2)
            let agree = Self.kind(shortlisted.verdict) == Self.kind(everyone.verdict)
            if !agree { disagreements += 1 }
            let (verdict, neighbour, sim, _) = Self.describe(shortlisted.verdict)
            let negatives = shortlisted.gaps.filter { $0.gap < 0 }.sorted { $0.seconds > $1.seconds }
            lines.append([
                speaker.name, String(speaker.id.prefix(8)),
                "\(selection.voices.count)+\(selection.dropped.count)/\(voiceCounts[speaker.id] ?? 0)",
                "\(negatives.count)/\(shortlisted.gaps.count)",
                String(format: "%.0f%%", shortlisted.negativeMass * 100),
                shortlisted.medianGap.map { String(format: "%.3f", $0) } ?? "–",
                verdict, neighbour, sim,
                negatives.map { "\($0.meetingId.prefix(8))→\(shortlisted.neighbors[$0.neighbor].name)" }
                    .joined(separator: ","),
                agree ? "same" : "DIFFERS: \(Self.describe(everyone.verdict))",
            ].joined(separator: " | "))
        }
        print("SEPARABILITY REPLAY (v2, \(speakers.count) confirmed speakers)")
        print(lines.joined(separator: "\n"))
        print("SEPARABILITY REPLAY: \(disagreements) verdict(s) differ between shortlisted and all neighbours")
    }

    private static func kind(_ verdict: SeparabilityCheck.Verdict) -> String {
        describe(verdict).0 + describe(verdict).1
    }

    private static func describe(_ verdict: SeparabilityCheck.Verdict) -> (String, String, String, String) {
        switch verdict {
        case .separable:
            ("accepted", "", "", "")
        case .tooSimilar(_, let name, let sim):
            ("REJECTED similar", name, String(format: "%.3f", sim), "")
        case .inseparable(_, let name, let sim, _, let meetings):
            ("REJECTED inseparable", name, String(format: "%.3f", sim),
             meetings.map { String($0.prefix(8)) }.joined(separator: ","))
        }
    }
}
