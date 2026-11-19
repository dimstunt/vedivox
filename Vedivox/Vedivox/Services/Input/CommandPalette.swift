import AppKit

/// One row of the ⌘K palette: a meeting, speaker, series, screen
/// or menu command, and what Enter does with it.
struct PaletteItem: Identifiable {
    enum Kind: String {
        case meeting = "Meeting"
        case series = "Series"
        case speaker = "Speaker"
        case command = "Command"
    }

    let id: String
    let kind: Kind
    let title: String
    var subtitle: String?
    /// Other names the row answers to: a speaker's other spellings.
    var aliases: [String] = []
    /// Menu text of the item's key equivalent (`⌘⇧E`).
    var shortcut: String?
    var icon: String
    let perform: @MainActor () -> Void
}

enum CommandPalette {
    /// The items whose title or aliases contain every word of `query`,
    /// case- and accent-blind. A title starting with the first word comes
    /// first, then one with a word starting with it, then the rest; within a
    /// rank the input order stands, so the caller's order is the tiebreak.
    static func filter(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        let words = words(of: query)
        guard let first = words.first else { return items }
        let ranked = items.enumerated().compactMap { index, item -> (rank: Int, index: Int, item: PaletteItem)? in
            let title = fold(item.title)
            let haystack = ([title] + item.aliases.map(fold)).joined(separator: " ")
            guard words.allSatisfy({ haystack.contains($0) }) else { return nil }
            let rank = title.hasPrefix(first) ? 0 : Self.words(of: title).contains { $0.hasPrefix(first) } ? 1 : 2
            return (rank, index, item)
        }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.item)
    }

    /// The enabled commands of `menu` and its submenus. Leaves out the
    /// `skipping` submenus and text editing — Cut, Copy, Spelling, Speech act
    /// on a text field, and the palette's own field is the one focused.
    @MainActor static func commands(in menu: NSMenu, skipping: [NSMenu] = [], excludingTitles: Set<String> = []) -> [PaletteItem] {
        // Validation runs when a menu opens; a menu never opened holds stale states.
        menu.update()
        return menu.items.flatMap { item -> [PaletteItem] in
            if let submenu = item.submenu {
                guard !skipping.contains(where: { $0 === submenu }) else { return [] }
                return commands(in: submenu, skipping: skipping, excludingTitles: excludingTitles)
            }
            guard let action = item.action, item.isEnabled, !item.isHidden, !item.isAlternate,
                  !item.title.isEmpty, !excludingTitles.contains(item.title),
                  !NSTextView.instancesRespond(to: action) else { return [] }
            return [PaletteItem(
                id: "command:\(item.title)", kind: .command, title: item.title,
                shortcut: shortcutText(item), icon: "command"
            ) {
                // Through the menu, as a click would: SwiftUI's command items
                // find their button by the sender.
                if let menu = item.menu, let index = menu.items.firstIndex(of: item) {
                    menu.performActionForItem(at: index)
                } else {
                    // The status menu is rebuilt every second while recording; its old items keep their target.
                    NSApp.sendAction(action, to: item.target, from: item)
                }
            }]
        }
    }

    static func shortcutText(_ item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        let mask = item.keyEquivalentModifierMask
        // An uppercase key equivalent carries Shift without the flag.
        let shift = mask.contains(.shift) || key != key.lowercased()
        let named = ["\u{8}": "⌫", "\u{7f}": "⌫", "\r": "↩", "\u{1b}": "⎋", " ": "Space", "\t": "⇥"]
        return (mask.contains(.control) ? "⌃" : "") + (mask.contains(.option) ? "⌥" : "")
            + (shift ? "⇧" : "") + (mask.contains(.command) ? "⌘" : "") + (named[key] ?? key.uppercased())
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func words(of text: String) -> [String] {
        fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
