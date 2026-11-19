import AppKit

/// Markdown export of a meeting transcript. Extracted from
/// `MeetingDetailViewModel.exportMarkdown` so the sidebar
/// context menu can export meetings that are not currently open.
enum TranscriptExporter {

    static func markdown(meeting: Meeting, segments: [TranscriptSegment]) -> String {
        // The exclusion predicate applies at every read surface (design D4):
        // filtering here, not at call sites, means no future caller can leak
        // excluded speech into an export.
        let segments = segments.filter { !$0.isExcluded }
        let speakerNames = Set(segments.compactMap(\.speakerLabel)).sorted()
        let durationStr: String = {
            guard let d = meeting.durationSeconds else { return "N/A" }
            let mins = Int(d) / 60
            let secs = Int(d) % 60
            return "\(mins)m \(secs)s"
        }()

        var md = """
            # \(meeting.title)
            **Date:** \(meeting.startTime.formatted(date: .long, time: .shortened))
            **Duration:** \(durationStr)
            **Speakers:** \(speakerNames.joined(separator: ", "))

            ---


            """
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.drop(while: { $0 == " " }) }
            .joined(separator: "\n")

        // Same turns the transcript view shows (SegmentGrouping), not raw ASR
        // fragments: a sentence split across two segments reads as one turn.
        for run in SegmentGrouping.groupRuns(segments) {
            md += "[\(run.formattedTimeRange)] **\(run.speakerLabel ?? "Speaker"):** \(run.joinedText)\n\n"
        }
        return md
    }

    /// Clipboard form of the transcript: one line per turn, excluded speech left out.
    static func plainText(segments: [TranscriptSegment]) -> String {
        SegmentGrouping.groupRuns(segments.filter { !$0.isExcluded })
            .map { "[\($0.formattedTimeRange)] \($0.speakerLabel ?? "Speaker"): \($0.joinedText)" }
            .joined(separator: "\n")
    }

    /// Ask for a destination and write the transcript. Must run on the main
    /// thread (NSSavePanel).
    /// Returns the written file, or nil when the user cancelled.
    @MainActor
    static func exportViaSavePanel(meeting: Meeting, segments: [TranscriptSegment]) throws -> URL? {
        let md = markdown(meeting: meeting, segments: segments)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(meeting.title).md"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try md.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
