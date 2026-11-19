import AppKit
import SwiftUI

/// Run-level row for Smart transcript layout.
/// Header: speaker name (clickable for rename) + from–to range.
/// Body: prose with inline `[MM:SS]` anchors — one per ≥15 s display chunk, not per segment.
/// Supports search-highlight, seek-on-anchor-tap (via vediseek:// URL), run-level context menu.
struct SmartRunRow: View {
    let run: SegmentRun
    let activeSegmentId: Int64?
    let searchText: String
    let onSeek: (TimeInterval) -> Void
    let onRenameSpeaker: (String, String?) -> Void // displayName, speakerId?
    let onMarkAsMe: () -> Void
    let onSplitHere: () -> Void
    /// «Не в транскрипт» / «Вернуть в транскрипт» for the whole run.
    let onExclude: () -> Void
    let onInclude: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var showSpeakerRename = false

    /// Index of the display chunk that contains the currently-playing segment, if any.
    private func activeChunkIndex(in chunks: [DisplayChunk]) -> Int? {
        guard let aid = activeSegmentId else { return nil }
        return chunks.firstIndex { chunk in
            chunk.segments.contains { $0.id == aid }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: VedivoxSpace.xl) {
            VStack(alignment: .trailing, spacing: VedivoxSpace.m) {
                Button {
                    showSpeakerRename = true
                } label: {
                    Text(run.speakerLabel.map(Speaker.windowLabel) ?? "Speaker")
                        .vedivoxFont(.overline)
                        .foregroundStyle(Color.speakerLabel(
                            run.speakerLabel,
                            key: run.speakerId ?? run.speakerLabel ?? "",
                            scheme: scheme
                        ))
                        .padding(.vertical, VedivoxSpace.xxs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .popover(isPresented: $showSpeakerRename) {
                    SpeakerRenamePopover(
                        currentLabel: run.speakerLabel ?? "Speaker",
                        onRename: { name, speakerId in
                            showSpeakerRename = false
                            onRenameSpeaker(name, speakerId)
                        },
                        onDismiss: { showSpeakerRename = false },
                        onMarkAsMe: {
                            showSpeakerRename = false
                            onMarkAsMe()
                        }
                    )
                }

                Button {
                    onSeek(run.startTime)
                } label: {
                    Text(TranscriptSegment.windowTimeRange(run.startTime, run.endTime))
                        .vedivoxFont(.timecode)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                        .padding(.vertical, VedivoxSpace.xxs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
            .frame(width: 120, alignment: .trailing)
            // Full run menu lives on the left column: the body Text has
            // textSelection enabled, so AppKit's text menu swallows right
            // clicks anywhere inside the bubble.
            .contentShape(Rectangle())
            .contextMenu { runContextMenu }

            Text(inlineBody)
                .vedivoxFont(.body)
                .lineSpacing(2)
                .textSelection(.enabled)
                .foregroundStyle(Color.Vedivox.fg)
                .tint(Color.Vedivox.fgSecondary)
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "vediseek",
                       let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                       let value = comps.queryItems?.first(where: { $0.name == "t" })?.value,
                       let t = Double(value) {
                        if NSEvent.modifierFlags.contains(.command) {
                            copyChunkText(startingAt: t)
                        } else {
                            onSeek(t)
                        }
                        return .handled
                    }
                    return .systemAction
                })
                .transcriptBubble(scheme)
                .contextMenu { runContextMenu }
        }
        .transcriptColumn()
    }

    @ViewBuilder
    private var runContextMenu: some View {
        Button {
            showSpeakerRename = true
        } label: {
            Label("Rename Speaker…", systemImage: "person.text.rectangle")
        }
        Button {
            onMarkAsMe()
        } label: {
            Label("Mark as Me", systemImage: "person.circle.fill")
        }
        Divider()
        if run.isExcluded {
            Button {
                onInclude()
            } label: {
                Label("Restore to Transcript", systemImage: "eye")
            }
        } else {
            Button {
                onExclude()
            } label: {
                Label("Exclude from Transcript", systemImage: "eye.slash")
            }
        }
        Divider()
        Button {
            copyRunText()
        } label: {
            Label("Copy Text", systemImage: "doc.on.doc")
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(formatTime(run.startTime), forType: .string)
        } label: {
            Label("Copy Timecode", systemImage: "clock")
        }
        Button {
            copyDeepLink()
        } label: {
            Label("Copy Link to Moment", systemImage: "link")
        }
        Divider()
        Button {
            onSeek(run.startTime)
        } label: {
            Label("Jump Here", systemImage: "play.circle")
        }
        Button {
            onSplitHere()
        } label: {
            Label("Split Here", systemImage: "scissors")
        }
    }

    /// ⌘-click: the chunk's plain text, no timecode.
    private func copyChunkText(startingAt time: TimeInterval) {
        guard let chunk = run.displayChunks(minDuration: 15).first(where: { $0.startTime == time }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(chunk.joinedText, forType: .string)
    }

    /// `[MM:SS] text  [MM:SS] text  …` — chunked (≥15 s) inline timecodes.
    /// The whole chunk (chip + text + trailing separator) is linked to `vediseek://seek?t=<chunkStart>`,
    /// so clicking anywhere inside a chunk seeks to its start and ⌘-click copies its text. The price:
    /// a link is one unit for text selection, so single words cannot be selected — dropping the
    /// links while ⌥ is held selected only within one line.
    private var inlineBody: AttributedString {
        var result = AttributedString()
        let chunks = run.displayChunks(minDuration: 15)
        let activeIdx = activeChunkIndex(in: chunks)

        for (i, chunk) in chunks.enumerated() {
            let isActiveChunk = (i == activeIdx)
            let url = URL(string: "vediseek://seek?t=\(chunk.startTime)")

            // First chunk's anchor is the clickable gutter time range; skip the inline chip.
            if i > 0 {
                var chip = AttributedString("[\(formatTime(chunk.startTime))] ")
                chip.foregroundColor = isActiveChunk ? Color.Vedivox.accentText : Color.Vedivox.fgSecondary
                chip.font = .caption2.monospacedDigit()
                chip.underlineStyle = nil
                chip.link = url
                result.append(chip)
            }

            var text = highlighted(chunk.joinedText)
            text.foregroundColor = Color.Vedivox.fg
            text.underlineStyle = nil
            if isActiveChunk {
                text.backgroundColor = Color.Vedivox.selection
            }
            text.link = url
            result.append(text)

            if i < chunks.count - 1 {
                var sep = AttributedString(" ")
                sep.link = url
                result.append(sep)
            }
        }
        return result
    }

    /// Build an AttributedString with search matches highlighted; returns plain text when search is empty.
    private func highlighted(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return attr }

        let lowerText = text.lowercased()
        let lowerSearch = search.lowercased()
        var cursor = lowerText.startIndex
        while let range = lowerText.range(of: lowerSearch, range: cursor ..< lowerText.endIndex) {
            if let aStart = AttributedString.Index(range.lowerBound, within: attr),
               let aEnd = AttributedString.Index(range.upperBound, within: attr) {
                attr[aStart ..< aEnd].backgroundColor = Color.Vedivox.highlight
                attr[aStart ..< aEnd].foregroundColor = Color.Vedivox.fg
            }
            cursor = range.upperBound
        }
        return attr
    }

    private func copyRunText() {
        let text = run.segments.map { seg in
            "[\(formatTime(seg.startTime))] \(seg.text)"
        }.joined(separator: " ")
        let header = "\(run.speakerLabel ?? "Speaker") \(formatTime(run.startTime))—\(formatTime(run.endTime)):\n"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(header + text, forType: .string)
    }

    private func copyDeepLink() {
        guard let meetingId = run.segments.first?.meetingId else { return }
        let link = "vedivox://meeting/\(meetingId)?t=\(Int(run.startTime))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    private func formatTime(_ seconds: TimeInterval) -> String { TranscriptSegment.windowTime(seconds) }
}

/// What a run of the transcript looks like, shared with the live text of a
/// recording: its hand-made copy of this layout had lost both (design D9 of
/// `live-transcript` promises the same layout).
extension View {
    /// The card under the text. Always neutral: the playing chunk is marked
    /// inside the text, not by the card.
    func transcriptBubble(_ scheme: ColorScheme) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, VedivoxSpace.s)
            .padding(.horizontal, VedivoxSpace.l)
            .background(
                // In light theme bgCard is pure white on a near-white
                // page — a hairline keeps the bubble readable.
                RoundedRectangle(cornerRadius: VedivoxRadius.s)
                    .fill(Color.Vedivox.bgCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: VedivoxRadius.s)
                            .strokeBorder(scheme == .light ? Color.Vedivox.lineSoft : .clear)
                    )
            )
    }

    /// The reading column: no wider than 820 pt, centred in the pane.
    func transcriptColumn() -> some View {
        frame(maxWidth: 820)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
