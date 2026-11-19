import SwiftUI

/// Renders meeting-description markdown in preview mode.
///
/// Clickable:
/// - `[label](vediseek://seek?t=<sec>)` → `onSeek(sec)`
/// - `- [ ]` / `- [x]` checkboxes → `onCheckboxToggle(globalIndex)`
///
/// Styled-only (no action in v1):
/// - `[name](vedispeaker://<id>)` — coloured by speaker hue; click returns `.handled` but does nothing.
///
/// Generic markdown links (http/https/…) go through the default system URL action.
struct DescriptionMarkdownView: View {
    let source: String
    let onSeek: (TimeInterval) -> Void
    let onCheckboxToggle: (Int) -> Void
    /// Extra room above level 1–2 headings: the Guide and What's New read as
    /// sections; a meeting description keeps its compact look.
    var sectionGap: CGFloat = 0

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let blocks = parseMarkdown(source, hooks: .init(scheme: scheme))
        let _ = Log.debug("[Markdown] render: source=\(source.count) chars → \(blocks.count) blocks")
        return VStack(alignment: .leading, spacing: VedivoxSpace.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            switch url.scheme {
            case "vediseek":
                if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let value = comps.queryItems?.first(where: { $0.name == "t" })?.value,
                   let t = Double(value) {
                    onSeek(t)
                    return .handled
                }
                return .handled
            case "vedispeaker":
                return .handled
            default:
                return .systemAction
            }
        })
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(fontForHeading(level))
                .padding(.top, (level == 1 ? 8 : 4) + (level <= 2 ? sectionGap : 0))
        case .rule:
            Divider().overlay(Color.Vedivox.line).padding(.vertical, VedivoxSpace.m)
        case .paragraph(let text):
            Text(text)
                .vedivoxFont(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .list(let items):
            VStack(alignment: .leading, spacing: VedivoxSpace.xxs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: VedivoxSpace.s) {
                        Text("•").foregroundStyle(Color.Vedivox.fgSecondary)
                        Text(item).textSelection(.enabled)
                    }
                }
            }
        case .checklist(let items):
            VStack(alignment: .leading, spacing: VedivoxSpace.xxs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: VedivoxSpace.s) {
                        Button {
                            onCheckboxToggle(entry.checkboxIndex)
                        } label: {
                            Image(systemName: entry.done ? "checkmark.square.fill" : "square")
                                .foregroundStyle(entry.done ? Color.Vedivox.success : Color.Vedivox.fgSecondary)
                        }
                        .buttonStyle(.plain)
                        Text(entry.text)
                            .strikethrough(entry.done)
                            .foregroundStyle(entry.done ? Color.Vedivox.fgSecondary : Color.Vedivox.fg)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func fontForHeading(_ level: Int) -> Font {
        switch level {
        case 1, 2: return VedivoxFont.title.swiftUIFont
        default: return VedivoxFont.bodyStrong.swiftUIFont
        }
    }
}

#Preview("Markdown sample") {
    DescriptionMarkdownView(
        source: """
        ## Этапы

        - **Старт** [0:05](vediseek://seek?t=5) — обсудили повестку
        - Разбор задач по релизу [1:20](vediseek://seek?t=80)
        - Вопросы от [Яков](vedispeaker://test-id) про деплой

        ## Экшн-айтемы

        - [ ] Собрать требования *к пятнице* [2:30](vediseek://seek?t=150)
        - [x] Закрыть прошлую задачу
        - [ ] Подготовить мониторинг
        """,
        onSeek: { _ in },
        onCheckboxToggle: { _ in }
    )
    .padding()
    .frame(width: 520)
}

#Preview("Plain text fallback") {
    DescriptionMarkdownView(
        source: "Просто обычный текст без разметки — должен стать одним параграфом.",
        onSeek: { _ in },
        onCheckboxToggle: { _ in }
    )
    .padding()
    .frame(width: 520)
}

#Preview("Empty") {
    DescriptionMarkdownView(
        source: "",
        onSeek: { _ in },
        onCheckboxToggle: { _ in }
    )
    .padding()
    .frame(width: 520, height: 60)
}
