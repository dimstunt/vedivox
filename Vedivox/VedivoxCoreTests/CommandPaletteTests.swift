import AppKit
import XCTest

@MainActor
final class CommandPaletteTests: XCTestCase {

    private func item(_ title: String, aliases: [String] = []) -> PaletteItem {
        PaletteItem(id: title, kind: .meeting, title: title, aliases: aliases, icon: "") {}
    }

    /// Every word must match; a title starting with the query beats a word
    /// starting with it, which beats a match inside a word; ties keep input order.
    func testFilterRanksPrefixFirstAndKeepsOrder() {
        let items = [
            item("Weekly sync with design"),
            item("Design review"),
            item("Redesign kickoff"),
            item("Sync — design"),
            item("Budget"),
        ]
        XCTAssertEqual(
            CommandPalette.filter(items, query: "design").map(\.title),
            ["Design review", "Weekly sync with design", "Sync — design", "Redesign kickoff"]
        )
        XCTAssertEqual(CommandPalette.filter(items, query: "sync DESIGN").map(\.title),
                       ["Sync — design", "Weekly sync with design"])
        XCTAssertEqual(CommandPalette.filter(items, query: "  ").count, items.count, "empty query keeps everything")
    }

    /// Accents fold away, and a speaker answers to every spelling of the name.
    func testFilterIsAccentBlindAndSearchesAliases() {
        let items = [item("Нина", aliases: ["Nina"]), item("Café")]
        XCTAssertEqual(CommandPalette.filter(items, query: "nin").map(\.title), ["Нина"])
        XCTAssertEqual(CommandPalette.filter(items, query: "cafe").map(\.title), ["Café"])
    }

    /// Enabled commands of the menu tree, minus text editing, disabled items,
    /// skipped submenus and excluded titles; Enter goes through the menu.
    func testCommandsComeFromTheMenuTree() {
        _ = NSApplication.shared // performActionForItem sends through NSApp
        final class Target: NSObject {
            var fired: [String] = []
            @objc func run(_ sender: NSMenuItem) { fired.append(sender.title) }
        }
        let target = Target()
        func command(_ title: String, key: String = "", enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(Target.run(_:)), keyEquivalent: key)
            item.target = target
            item.isEnabled = enabled
            return item
        }
        let root = NSMenu()
        root.autoenablesItems = false
        let file = NSMenu()
        file.autoenablesItems = false
        file.addItem(command("Import Recording…", key: "i"))
        file.addItem(.separator())
        file.addItem(command("Export to Markdown", key: "E"))
        file.addItem(command("Delete Meeting", enabled: false))
        file.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        file.addItem(command("Quick Search…"))
        let services = NSMenu()
        services.addItem(command("Some Service"))
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        root.addItem(fileItem)
        root.addItem(servicesItem)

        let commands = CommandPalette.commands(in: root, skipping: [services], excludingTitles: ["Quick Search…"])
        XCTAssertEqual(commands.map(\.title), ["Import Recording…", "Export to Markdown"])
        XCTAssertEqual(commands.map(\.shortcut), ["⌘I", "⇧⌘E"])

        commands[1].perform()
        XCTAssertEqual(target.fired, ["Export to Markdown"])
    }

    /// The status menu is rebuilt every second while recording: a command
    /// picked after that must still run (Stop Recording did nothing).
    func testCommandFiresAfterItsMenuIsReplaced() {
        _ = NSApplication.shared
        final class Target: NSObject {
            var fired = 0
            @objc func stop(_ sender: Any?) { fired += 1 }
        }
        let target = Target()
        var commands: [PaletteItem] = []
        autoreleasepool {
            let menu = NSMenu()
            let item = NSMenuItem(title: "Stop Recording", action: #selector(Target.stop(_:)), keyEquivalent: "")
            item.target = target
            menu.addItem(item)
            commands = CommandPalette.commands(in: menu)
        }
        commands[0].perform()
        XCTAssertEqual(target.fired, 1)
    }
}
