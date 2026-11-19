import Foundation

/// A run of consecutive segments by one speaker — the unit both interfaces
/// render (scriptable-cli, group 2). Assembly lives here so CLI and MCP show
/// the same blocks; only the text around them differs.
package struct TranscriptBlock: Sendable, Equatable {
    package var speaker: String
    package var startTime: Double
    package var endTime: Double
    package var text: String
    /// Ids of the merged segments, in order — what `update_segment` / `vedivox segment set` address.
    package var segmentIds: [Int64] = []
}

/// Merges consecutive segments from the same resolved speaker when the gap
/// between them is at most `mergeGap` seconds.
package func assembleTranscriptBlocks(
    segments: [TranscriptSegment],
    mergeGap: Double = 20.0,
    resolveSpeaker: (TranscriptSegment) throws -> String
) rethrows -> [TranscriptBlock] {
    var blocks: [TranscriptBlock] = []
    var i = 0
    while i < segments.count {
        let first = segments[i]
        let speaker = try resolveSpeaker(first)
        var endTime = first.endTime
        var texts = [first.text]
        var ids = [first.id].compactMap { $0 }
        var j = i + 1
        while j < segments.count {
            let next = segments[j]
            let nextSpeaker = try resolveSpeaker(next)
            if nextSpeaker == speaker, (next.startTime - endTime) <= mergeGap {
                texts.append(next.text)
                if let id = next.id { ids.append(id) }
                endTime = next.endTime
                j += 1
            } else {
                break
            }
        }
        blocks.append(TranscriptBlock(
            speaker: speaker,
            startTime: first.startTime,
            endTime: endTime,
            text: texts.joined(separator: " "),
            segmentIds: ids
        ))
        i = j
    }
    return blocks
}

/// Resolves a display name for a segment the way both interfaces do: speaker
/// row name first, then the segment label, with the `[excluded]` tag doubling
/// as a merge barrier. The cache saves one DB hit per segment.
package func makeSpeakerResolver(db: DatabaseReader) -> (TranscriptSegment) throws -> String {
    var cache: [String: String] = [:]
    return { segment in
        let name: String
        if let speakerId = segment.speakerId {
            if let cached = cache[speakerId] {
                name = cached
            } else {
                name = try db.speakerName(forId: speakerId) ?? segment.speakerLabel ?? "Unknown"
                cache[speakerId] = name
            }
        } else {
            name = segment.speakerLabel ?? "Unknown"
        }
        return segment.isExcluded ? "\(name) [excluded]" : name
    }
}
