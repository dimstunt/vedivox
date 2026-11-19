import Foundation

/// Pure function: find the `index`-th `- [ ]` / `- [x]` line in `source`
/// and flip its state. Returns the mutated source. If `index` is out of
/// bounds — returns source unchanged.
///
/// Used by the inspector's description section after a checkbox tap,
/// then passed to `MeetingDetailViewModel.updateDescription(_:meetingId:)` for save.
func toggleMarkdownCheckbox(_ source: String, at index: Int) -> String {
    let regex = #/^(\s*-\s+\[)([ xX])(\]\s+.*)$/#.anchorsMatchLineEndings()
    let matches = Array(source.matches(of: regex))
    guard index >= 0, index < matches.count else { return source }
    let match = matches[index]
    let current = String(match.output.2)
    let replacementChar: String = (current == " ") ? "x" : " "
    var result = source
    let captureRange = match.output.2.startIndex ..< match.output.2.endIndex
    result.replaceSubrange(captureRange, with: replacementChar)
    return result
}
