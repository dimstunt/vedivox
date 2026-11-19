import SwiftUI

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let isActive: Bool
    let onTextUpdate: (String) -> Void
    let onTimecodeTap: (Double) -> Void
    let onEditStart: () -> Void
    var searchText: String = ""
    let onSpeakerRename: (String, String?) -> Void // (displayName, speakerId?)
    var onSpeakerReassign: ((String, String) -> Void)? // (speakerId, speakerName)
    var onSpeakerReassignNew: ((String) -> Void)?
    var onMarkAsMe: (() -> Void)?
    var isSelected: Bool = false
    var onSelect: ((NSEvent.ModifierFlags) -> Void)?

    @Environment(\.colorScheme) private var scheme
    @State private var isEditing = false
    @State private var editText = ""
    @State private var showSpeakerRename = false

    var body: some View {
        HStack(alignment: .top, spacing: VedivoxSpace.xl) {
            // Left column: speaker + timecode (matches Smart layout)
            VStack(alignment: .trailing, spacing: VedivoxSpace.xxs) {
                Button {
                    showSpeakerRename = true
                } label: {
                    Text(segment.speakerLabel.map(Speaker.windowLabel) ?? "Speaker")
                        .vedivoxFont(.overline)
                        .foregroundStyle(speakerColor)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
                .popover(isPresented: $showSpeakerRename) {
                    SpeakerRenamePopover(
                        currentLabel: segment.speakerLabel ?? "Speaker",
                        onRename: { name, speakerId in
                            showSpeakerRename = false
                            onSpeakerRename(name, speakerId)
                        },
                        onDismiss: { showSpeakerRename = false },
                        onReassign: onSpeakerReassign.map { callback in
                            { speakerId, speakerName in
                                showSpeakerRename = false
                                callback(speakerId, speakerName)
                            }
                        },
                        onReassignNew: onSpeakerReassignNew.map { callback in
                            { name in
                                showSpeakerRename = false
                                callback(name)
                            }
                        },
                        onMarkAsMe: onMarkAsMe.map { callback in
                            {
                                showSpeakerRename = false
                                callback()
                            }
                        }
                    )
                }

                Button {
                    onTimecodeTap(segment.startTime)
                } label: {
                    Text(TranscriptSegment.windowTimeRange(segment.startTime, segment.endTime))
                        .vedivoxFont(.timecode)
                        .foregroundStyle(Color.Vedivox.fgSecondary)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
                .contextMenu {
                    Button("Copy Timecode") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(segment.formattedTimeRange, forType: .string)
                    }
                    Button("Copy Link to Moment") {
                        let link = "vedivox://meeting/\(segment.meetingId)?t=\(Int(segment.startTime))"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                    }
                    Divider()
                    Button("Copy Text") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(segment.text, forType: .string)
                    }
                    Button("Jump Here") {
                        onTimecodeTap(segment.startTime)
                    }
                }
            }
            .frame(width: 120, alignment: .trailing)

            // Right column: text in panel + edit/confidence controls
            VStack(alignment: .leading, spacing: VedivoxSpace.xs) {
                if isEditing {
                    TextField("Segment text", text: $editText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .vedivoxFont(.body)
                        .onSubmit {
                            if editText != segment.text {
                                onTextUpdate(editText)
                            }
                            isEditing = false
                        }
                        .onExitCommand {
                            isEditing = false
                        }
                } else if searchText.isEmpty {
                    Text(segment.text)
                        .vedivoxFont(.body)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                } else {
                    Text(highlightedText(segment.text, search: searchText))
                        .vedivoxFont(.body)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }

                HStack(spacing: VedivoxSpace.m) {
                    if segment.isEdited {
                        Text("edited")
                            .vedivoxFont(.caption)
                            .foregroundStyle(Color.Vedivox.fgSecondary)
                    }
                    Spacer()
                    Button {
                        editText = segment.text
                        isEditing = true
                        onEditStart()
                    } label: {
                        Circle()
                            .fill(segment.confidence.map { confidenceColor($0) } ?? Color.Vedivox.fgQuaternary)
                            .frame(width: VedivoxSize.dot, height: VedivoxSize.dot)
                    }
                    .buttonStyle(.plain)
                    .help(segment.confidence.map { "Confidence: \(Int($0 * 100))% — click to edit" } ?? "Click to edit")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, VedivoxSpace.s)
            .padding(.horizontal, VedivoxSpace.l)
            .background(
                RoundedRectangle(cornerRadius: VedivoxRadius.s)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VedivoxRadius.s)
                    // Light theme: the same line-soft hairline as SmartRunRow.
                    .strokeBorder(
                        isSelected ? Color.Vedivox.selectionLine : scheme == .light ? Color.Vedivox.lineSoft : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .onTapGesture {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.command) || flags.contains(.shift) {
                onSelect?(flags)
            }
        }
    }

    private var backgroundFill: Color {
        if isSelected {
            return Color.Vedivox.selection
        }
        if isEditing {
            return Color.Vedivox.bgHover
        }
        if isActive {
            return Color.Vedivox.bgActive
        }
        return Color.Vedivox.bgCard
    }

    private var speakerColor: Color {
        guard segment.speakerLabel != nil else { return Color.Vedivox.fg }
        let key = segment.speakerId ?? segment.speakerLabel ?? ""
        return Color.speakerLabel(segment.speakerLabel, key: key, scheme: scheme)
    }

    private func highlightedText(_ text: String, search: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !search.isEmpty else { return attributed }

        // Searched in `text` itself: indices of a lowercased copy are not
        // indices of the original (İ, ẞ and others change length), and the
        // force-unwrapped conversion crashed the row on such a transcript.
        var searchStart = text.startIndex
        while let range = text.range(of: search, options: .caseInsensitive, range: searchStart ..< text.endIndex),
              !range.isEmpty {
            if let attrStart = AttributedString.Index(range.lowerBound, within: attributed),
               let attrEnd = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[attrStart ..< attrEnd].backgroundColor = Color.Vedivox.highlight
                attributed[attrStart ..< attrEnd].foregroundColor = Color.Vedivox.fg
            }
            searchStart = range.upperBound
        }
        return attributed
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.9 { return Color.Vedivox.success }
        if confidence >= 0.7 { return Color.Vedivox.warning }
        return Color.Vedivox.danger
    }
}
