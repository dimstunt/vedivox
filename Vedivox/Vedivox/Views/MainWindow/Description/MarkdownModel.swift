import Foundation
import SwiftUI

/// Block-level markdown AST for meeting descriptions.
/// Intentionally small — covers only what we render in preview.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case list(items: [AttributedString])
    case checklist(items: [ChecklistItem])
    /// `---`, `***` or `___` on a line of its own: a horizontal rule.
    case rule

    struct ChecklistItem: Equatable {
        let done: Bool
        let text: AttributedString
        /// Index of this checkbox among all `- [ ]`/`- [x]` occurrences in source (0-based, top-down).
        let checkboxIndex: Int
    }
}

struct MarkdownInlineHooks {
    let scheme: ColorScheme
}

private enum InlineReplacement {
    case timecode(label: String, time: TimeInterval)
    case mention(name: String, id: String)
}

/// Parse `source` markdown into block-level nodes.
/// - Blank lines flush in-progress list/checklist/paragraph groups.
/// - Plain text without any markdown → single `.paragraph` block.
/// - Checklist items are numbered globally (top-down in source).
func parseMarkdown(_ source: String, hooks: MarkdownInlineHooks) -> [MarkdownBlock] {
    let started = Date()
    Log.debug("[Markdown] parse start: \(source.count) chars")
    var blocks: [MarkdownBlock] = []
    // Raw, rendered on flush: an indented line continues the item above it.
    var listBuffer: [String] = []
    var checkBuffer: [MarkdownBlock.ChecklistItem] = []
    var paraBuffer: [String] = []
    var checkboxCounter = 0

    func flushPara() {
        guard !paraBuffer.isEmpty else { return }
        // A single newline is a soft break, as in CommonMark: hard-wrapped
        // prose (GUIDE.md) reads as one paragraph, not as ragged lines.
        let joined = paraBuffer.joined(separator: " ")
        blocks.append(.paragraph(renderInline(joined, hooks: hooks)))
        paraBuffer.removeAll()
    }
    func flushList() {
        guard !listBuffer.isEmpty else { return }
        blocks.append(.list(items: listBuffer.map { renderInline($0, hooks: hooks) }))
        listBuffer.removeAll()
    }
    func flushCheck() {
        guard !checkBuffer.isEmpty else { return }
        blocks.append(.checklist(items: checkBuffer))
        checkBuffer.removeAll()
    }
    func flushAll() { flushPara()
    flushList()
    flushCheck() }

    let headingRegex = #/^(#{1,6})\s+(.*)$/#
    let checkRegex = #/^(\s*)-\s+\[([ xX])\]\s+(.*)$/#
    let listRegex = #/^(\s*)-\s+(.*)$/#
    // Before the list regex: `---` would otherwise read as an item "--".
    let ruleRegex = #/^ {0,3}(-{3,}|\*{3,}|_{3,})\s*$/#

    var inFence = false

    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = String(line)
        if s.hasPrefix("```") {
            flushAll()
            inFence.toggle()
            continue
        }
        if inFence {
            // One paragraph per code line, set as inline code.
            if !s.isEmpty { blocks.append(.paragraph(renderInline("`\(s)`", hooks: hooks))) }
            continue
        }
        if s.trimmingCharacters(in: .whitespaces).isEmpty {
            flushAll()
            continue
        }
        if (try? ruleRegex.wholeMatch(in: s)) != nil {
            flushAll()
            blocks.append(.rule)
            continue
        }
        if let m = try? headingRegex.wholeMatch(in: s) {
            flushAll()
            let level = m.output.1.count
            let text = String(m.output.2)
            blocks.append(.heading(level: level, text: renderInline(text, hooks: hooks)))
            continue
        }
        if let m = try? checkRegex.wholeMatch(in: s) {
            flushPara()
            flushList()
            let done = (String(m.output.2).lowercased() == "x")
            let text = String(m.output.3)
            checkBuffer.append(.init(done: done, text: renderInline(text, hooks: hooks), checkboxIndex: checkboxCounter))
            checkboxCounter += 1
            continue
        }
        if let m = try? listRegex.wholeMatch(in: s) {
            flushPara()
            flushCheck()
            let text = String(m.output.2)
            listBuffer.append(text)
            continue
        }
        if !listBuffer.isEmpty, s.first?.isWhitespace == true {
            listBuffer[listBuffer.count - 1] += " " + s.trimmingCharacters(in: .whitespaces)
            continue
        }
        flushList()
        flushCheck()
        paraBuffer.append(s)
    }
    flushAll()
    let ms = Int(Date().timeIntervalSince(started) * 1000)
    Log.debug("[Markdown] parse done: \(blocks.count) blocks, \(checkboxCounter) checkboxes, \(ms)ms")
    return blocks
}

/// Render a single inline line: resolves `[label](vediseek://seek?t=N)` and
/// `[name](vedispeaker://<id>)` into styled runs, then lets Foundation handle
/// bold/italic/code/generic links.
func renderInline(_ line: String, hooks: MarkdownInlineHooks) -> AttributedString {
    var replacements: [InlineReplacement] = []
    var processed = line

    // Descriptions written before the rename carry the old schemes. Both are
    // read here; what is rendered below is always in today's form.
    let timecodeRegex = #/\[([^\]]+)\]\((?:vediseek|voxseek)://seek\?t=([0-9]+(?:\.[0-9]+)?)\)/# // rename:keep
    while let m = processed.firstMatch(of: timecodeRegex) {
        let label = String(m.output.1)
        let time = Double(m.output.2) ?? 0
        let idx = replacements.count
        replacements.append(.timecode(label: label, time: time))
        processed.replaceSubrange(m.range, with: "\u{E100}\(idx)\u{E100}")
    }

    let mentionRegex = #/\[([^\]]+)\]\((?:vedispeaker|voxspeaker)://([^\)]+)\)/# // rename:keep
    while let m = processed.firstMatch(of: mentionRegex) {
        let name = String(m.output.1)
        let id = String(m.output.2)
        let idx = replacements.count
        replacements.append(.mention(name: name, id: id))
        processed.replaceSubrange(m.range, with: "\u{E101}\(idx)\u{E101}")
    }

    let result: AttributedString
    do {
        result = try AttributedString(
            markdown: processed,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    } catch {
        result = AttributedString(processed)
    }

    return substituteTokens(in: result, replacements: replacements, hooks: hooks)
}

/// Replace `\u{E100}<idx>\u{E100}` / `\u{E101}<idx>\u{E101}` tokens in the rendered
/// AttributedString with styled timecode / mention spans.
/// Hard iteration cap protects against any Index-conversion quirk becoming an infinite loop —
/// if the cap is hit we log and break so the UI never hangs.
private func substituteTokens(
    in source: AttributedString,
    replacements: [InlineReplacement],
    hooks: MarkdownInlineHooks
) -> AttributedString {
    var result = source
    let tokenChars: [Character] = ["\u{E100}", "\u{E101}"]
    var iterations = 0
    let maxIterations = replacements.count + 8
    var substituted = 0
    var aborted = false

    while iterations < maxIterations {
        iterations += 1
        let str = String(result.characters)
        guard let firstIdx = str.firstIndex(where: { tokenChars.contains($0) }) else { break }
        let token = str[firstIdx]
        let afterFirst = str.index(after: firstIdx)
        guard afterFirst < str.endIndex,
              let secondIdx = str[afterFirst...].firstIndex(of: token) else {
            Log.error("[Markdown] substitute: unmatched token at \(str.distance(from: str.startIndex, to: firstIdx))")
            aborted = true
            break
        }
        let innerRange = afterFirst ..< secondIdx
        guard let idx = Int(str[innerRange]), idx < replacements.count else {
            Log.error("[Markdown] substitute: bad token payload '\(str[innerRange])'")
            aborted = true
            break
        }

        let endAfterSecond = str.index(after: secondIdx)
        guard let attrStart = AttributedString.Index(firstIdx, within: result),
              let attrEnd = AttributedString.Index(endAfterSecond, within: result) else {
            Log.error("[Markdown] substitute: index conversion failed")
            aborted = true
            break
        }

        let chunk: AttributedString
        switch replacements[idx] {
        case .timecode(let label, let time):
            var t = AttributedString(label)
            t.foregroundColor = Color.Vedivox.accentText
            t.font = .caption.monospacedDigit()
            t.backgroundColor = Color.Vedivox.selection
            t.underlineStyle = nil
            t.link = URL(string: "vediseek://seek?t=\(time)")
            chunk = t
        case .mention(let name, let id):
            var m = AttributedString(name)
            let hue = SpeakerHue.for(id)
            m.foregroundColor = Color.speaker(hue: hue, scheme: hooks.scheme)
            m.font = .body.weight(.semibold)
            m.underlineStyle = nil
            m.link = URL(string: "vedispeaker://\(id)")
            chunk = m
        }
        result.replaceSubrange(attrStart ..< attrEnd, with: chunk)
        substituted += 1
    }

    if iterations >= maxIterations, !aborted {
        Log.error("[Markdown] substitute: iteration cap hit (\(iterations)) — potential runaway, leaving remaining tokens in place")
    }

    // Strip any orphan PUA-token chars so they never reach the renderer as invisible glyphs.
    let stripped = String(result.characters).filter { !tokenChars.contains($0) }
    if stripped != String(result.characters) {
        Log.debug("[Markdown] substitute: stripped orphan tokens")
        return AttributedString(stripped)
    }
    if substituted != replacements.count {
        Log.debug("[Markdown] substitute: \(substituted)/\(replacements.count) replacements applied")
    }
    return result
}
