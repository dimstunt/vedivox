import Foundation

/// MCP tool: merge_speakers — Merges duplicate speakers into one.
package enum MergeSpeakersTool {
    package static let definition: AnyCodable = .object([
        "name": .string("merge_speakers"),
        "description": .string(
            "Merge duplicate speakers into a target speaker. " +
            "All transcript segments and meeting associations from source speakers " +
            "are reassigned to the target. Source speakers are deleted."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "target_id": .object([
                    "type": .string("string"),
                    "description": .string("Speaker ID to keep (merge target)"),
                ]),
                "source_ids": .object([
                    "type": .string("array"),
                    "description": .string("Speaker IDs to merge into target (will be deleted)"),
                    "items": .object([
                        "type": .string("string"),
                    ]),
                ]),
            ]),
            "required": .array([.string("target_id"), .string("source_ids")]),
        ]),
    ])

    package static func run(params: [String: AnyCodable]) throws -> String {
        guard let targetId = params["target_id"]?.value as? String, !targetId.isEmpty else {
            return "Error: target_id is required"
        }

        let sourceIds: [String]
        if let arr = params["source_ids"]?.value as? [AnyCodable] {
            sourceIds = arr.compactMap { $0.value as? String }
        } else {
            return "Error: source_ids is required (array of speaker IDs)"
        }

        // Validation lives in the shared builder (used by the CLI too).
        let request: AppCommandRequest
        do {
            request = try AppCommandBuilders.mergeSpeakers(targetId: targetId, sourceIds: sourceIds)
        } catch AppCommandBuilders.BuildError.emptySources {
            return "Error: source_ids must not be empty"
        } catch AppCommandBuilders.BuildError.targetInSources {
            return "Error: target_id must not be in source_ids"
        }

        do {
            let response = try AppCommandDispatch.run(request)
            return AppCommandDispatch.describe(response)
        } catch {
            return "Error: \(error)"
        }
    }
}
