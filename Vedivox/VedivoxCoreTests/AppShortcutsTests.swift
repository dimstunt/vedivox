import KeyboardShortcuts
import XCTest

final class AppShortcutsTests: XCTestCase {

    /// A future default that collides with another command would ship two
    /// actions on one key — and the conflict check could not tell them apart.
    func testDefaultsAreDistinct() {
        let defaults = AppShortcuts.catalog.compactMap(\.name.initialShortcut)
        XCTAssertEqual(defaults.count, AppShortcuts.catalog.count, "every catalog command has a default")
        XCTAssertEqual(Set(defaults).count, defaults.count, "two catalog commands share a default")
    }

    func testConflictNamesTheOwner() {
        let dictation = KeyboardShortcuts.Shortcut(.two, modifiers: [.command, .shift])
        let free = KeyboardShortcuts.Shortcut(.nine, modifiers: [.command, .control, .option])
        let current: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [.toggleDictation: dictation]

        XCTAssertEqual(
            AppShortcuts.conflictingTitle(for: dictation, excluding: .toggleRecording, current: current),
            "Dictation"
        )
        XCTAssertNil(AppShortcuts.conflictingTitle(for: free, excluding: .toggleRecording, current: current))
        XCTAssertNil(
            AppShortcuts.conflictingTitle(for: dictation, excluding: .toggleDictation, current: current),
            "re-recording a command's own shortcut is not a conflict"
        )
    }

    /// a changed single-character rate key becomes ⌥ + the same key.
    func testLegacyRateKeyBecomesOptionShortcut() {
        XCTAssertEqual(AppShortcuts.legacyShortcut(for: "p"), KeyboardShortcuts.Shortcut(.p, modifiers: [.option]))
        XCTAssertEqual(AppShortcuts.legacyShortcut(for: "P"), KeyboardShortcuts.Shortcut(.p, modifiers: [.option]))
        XCTAssertEqual(AppShortcuts.legacyShortcut(for: ","), KeyboardShortcuts.Shortcut(.comma, modifiers: [.option]))
        XCTAssertEqual(AppShortcuts.legacyShortcut(for: "\\"), KeyboardShortcuts.Shortcut(.backslash, modifiers: [.option]))
        XCTAssertNil(AppShortcuts.legacyShortcut(for: "х"), "no key on the US layout")
        XCTAssertNil(AppShortcuts.legacyShortcut(for: "ab"))
        XCTAssertEqual(
            AppShortcuts.legacyShortcut(for: "["), KeyboardShortcuts.Name.playerSlower.initialShortcut,
            "the old default maps onto the new one"
        )
    }

    /// Old defaults and unmappable characters only clear the old keys; nothing is set.
    @MainActor func testMigrationClearsTheOldKeys() throws {
        let suite = "AppShortcutsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("[", forKey: "shortcutSlowerKey")
        defaults.set("х", forKey: "shortcutFasterKey")

        AppShortcuts.migrateLegacyRateKeys(defaults)

        XCTAssertNil(defaults.object(forKey: "shortcutSlowerKey"))
        XCTAssertNil(defaults.object(forKey: "shortcutFasterKey"))
    }
}
