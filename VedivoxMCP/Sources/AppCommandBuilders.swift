import Foundation

/// Request builders shared by MCP tools and the CLI (scriptable-cli, group 2):
/// the validation that guards a data change lives once, next to the wire
/// format it produces.
package enum AppCommandBuilders {
    package enum BuildError: Error, CustomStringConvertible {
        case targetInSources
        case emptySources

        package var description: String {
            switch self {
            case .targetInSources: return "target_id must not be in source_ids"
            case .emptySources: return "source_ids must not be empty"
            }
        }
    }

    /// merge_speakers: sources are folded into the target and deleted.
    package static func mergeSpeakers(targetId: String, sourceIds: [String]) throws -> AppCommandRequest {
        guard !sourceIds.isEmpty else { throw BuildError.emptySources }
        guard !sourceIds.contains(targetId) else { throw BuildError.targetInSources }
        return AppCommandRequest(
            command: AppCommandName.mergeSpeakers,
            params: [
                "target_id": targetId,
                // Speaker ids are UUIDs, so a comma cannot occur inside one.
                "source_ids": sourceIds.joined(separator: ","),
            ]
        )
    }
}

extension AppCommandName {
    /// Mirrors the app's `AppCommandName.detachMeetings` (apply-anon-identification).
    package static let detachMeetings = "detach_meetings"
    /// Mirrors the app's `AppCommandName.deleteSpeaker`.
    package static let deleteSpeaker = "delete_speaker"
    /// Mirrors the app's `AppCommandName.applySeriesRules`.
    package static let applySeriesRules = "apply_series_rules"
    /// Mirrors the app's `AppCommandName.mergeSeries`.
    package static let mergeSeries = "merge_series"
}
