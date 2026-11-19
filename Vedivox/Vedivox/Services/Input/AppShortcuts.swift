import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// ⌃⇧⌘1 by default — the recording key with ⌃ added: it only matters
    /// while a recording runs. Global so the toggle works mid-call without
    /// switching to Vedivox (transcript-exclusion-marks, D6).
    static let toggleExclusion = Self("toggleExclusion", initial: .init(.one, modifiers: [.command, .control, .shift]))
    /// ⌘⇧1 — next to dictation's ⌘⇧2, and the only free digit there:
    /// ⌘⇧3/4/5 belong to macOS screenshots. Global: starts a meeting
    /// mid-call from any app.
    static let toggleRecording = Self("toggleRecording", initial: .init(.one, modifiers: [.command, .shift]))

    // Window commands. Without an `onKeyUp` handler a name registers nothing
    // with Carbon — it is only where the user's choice is stored.
    /// ⌘K, as in Slack, Linear and most apps with a palette.
    static let commandPalette = Self("commandPalette", initial: .init(.k, modifiers: [.command]))
    static let findInView = Self("findInView", initial: .init(.f, modifiers: [.command]))
    static let importRecording = Self("importRecording", initial: .init(.i, modifiers: [.command]))
    static let exportMarkdown = Self("exportMarkdown", initial: .init(.e, modifiers: [.command, .shift]))
    /// ⌘⇧J, as Reveal in Project Navigator in Xcode.
    static let revealInSidebar = Self("revealInSidebar", initial: .init(.j, modifiers: [.command, .shift]))
    static let toggleInspector = Self("toggleInspector", initial: .init(.i, modifiers: [.command, .option]))
    static let navigateBack = Self("navigateBack", initial: .init(.leftBracket, modifiers: [.command]))
    static let navigateForward = Self("navigateForward", initial: .init(.rightBracket, modifiers: [.command]))

    // Player rate. Matched by the transcript's own key handler, so a
    // text field keeps the keystroke (⌥[ types “); never registered with Carbon.
    static let playerSlower = Self("playerSlower", initial: .init(.leftBracket, modifiers: [.option]))
    static let playerFaster = Self("playerFaster", initial: .init(.rightBracket, modifiers: [.option]))
}

/// The shortcuts a user can reassign in Settings → Shortcuts. Keys without
/// modifiers (Space, arrows, Esc) and ⌘⌫ Delete Meeting stay fixed.
enum AppShortcuts {
    enum Group: String, CaseIterable {
        case global = "Global"
        case window = "In the window"
        case player = "Player"
    }

    struct Entry {
        let name: KeyboardShortcuts.Name
        let title: String
        let group: Group
    }

    static let catalog: [Entry] = [
        Entry(name: .toggleRecording, title: "Start / Stop Recording", group: .global),
        Entry(name: .toggleDictation, title: "Dictation", group: .global),
        Entry(name: .toggleExclusion, title: "Exclude from Transcript", group: .global),
        Entry(name: .commandPalette, title: "Quick Search", group: .window),
        Entry(name: .findInView, title: "Find", group: .window),
        Entry(name: .importRecording, title: "Import Recording", group: .window),
        Entry(name: .exportMarkdown, title: "Export to Markdown", group: .window),
        Entry(name: .revealInSidebar, title: "Reveal in Sidebar", group: .window),
        Entry(name: .toggleInspector, title: "Inspector", group: .window),
        Entry(name: .navigateBack, title: "Back", group: .window),
        Entry(name: .navigateForward, title: "Forward", group: .window),
        Entry(name: .playerSlower, title: "Slower", group: .player),
        Entry(name: .playerFaster, title: "Faster", group: .player),
    ]

    /// Until the rate keys were single characters without a modifier
    /// (`shortcutSlowerKey`, `shortcutFasterKey`, defaults «[» and «]»). A changed
    /// one becomes ⌥ + the same key; the old defaults and characters with no
    /// key on the US layout are dropped, leaving ⌥[ and ⌥]. Once per install.
    @MainActor static func migrateLegacyRateKeys(_ defaults: UserDefaults = .standard) {
        for (key, name, old) in [
            ("shortcutSlowerKey", KeyboardShortcuts.Name.playerSlower, "["),
            ("shortcutFasterKey", KeyboardShortcuts.Name.playerFaster, "]"),
        ] {
            guard let character = defaults.string(forKey: key) else { continue }
            defaults.removeObject(forKey: key)
            guard character != old else { continue }
            guard let shortcut = legacyShortcut(for: character) else {
                Log.info("Player key “\(character)” has no ⌥ shortcut; \(name.rawValue) stays at its default")
                continue
            }
            KeyboardShortcuts.setShortcut(shortcut, for: name)
        }
    }

    /// ⌥ + the key that types `character` on the US layout, nil for anything else.
    static func legacyShortcut(for character: String) -> KeyboardShortcuts.Shortcut? {
        let keys: [Character: KeyboardShortcuts.Key] = [
            "a": .a, "b": .b, "c": .c, "d": .d, "e": .e, "f": .f, "g": .g, "h": .h, "i": .i,
            "j": .j, "k": .k, "l": .l, "m": .m, "n": .n, "o": .o, "p": .p, "q": .q, "r": .r,
            "s": .s, "t": .t, "u": .u, "v": .v, "w": .w, "x": .x, "y": .y, "z": .z,
            "0": .zero, "1": .one, "2": .two, "3": .three, "4": .four,
            "5": .five, "6": .six, "7": .seven, "8": .eight, "9": .nine,
            "[": .leftBracket, "]": .rightBracket, "-": .minus, "=": .equal, ";": .semicolon,
            "'": .quote, ",": .comma, ".": .period, "/": .slash, "\\": .backslash, "`": .backtick,
        ]
        guard character.count == 1, let key = keys[Character(character.lowercased())] else { return nil }
        return KeyboardShortcuts.Shortcut(key, modifiers: [.option])
    }

    /// The title of the other Vedivox command that already owns `shortcut`, nil
    /// when it is free. The package checks the system and the menu, not our
    /// own names against each other.
    static func conflictingTitle(
        for shortcut: KeyboardShortcuts.Shortcut,
        excluding name: KeyboardShortcuts.Name,
        current: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut]
    ) -> String? {
        catalog.first { $0.name != name && current[$0.name] == shortcut }?.title
    }

    @MainActor static var currentShortcuts: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] {
        var result: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [:]
        for entry in catalog {
            result[entry.name] = KeyboardShortcuts.getShortcut(for: entry.name)
        }
        return result
    }
}
