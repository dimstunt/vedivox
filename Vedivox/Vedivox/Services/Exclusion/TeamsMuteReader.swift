import AppKit
import ApplicationServices
import Foundation

/// The attributes of one AX element the Teams rules look at.
struct AXNodeInfo: Equatable, Sendable {
    var role: String?
    /// HTML `id` of a web element (`AXDOMIdentifier`, WebKit and Chromium alike).
    var domId: String?
    var title: String?
    /// `aria-label` lands here in both web engines.
    var description: String?
    /// `AXIdentifier`: a native control's id (a Qt `objectName`, an AppKit identifier).
    var identifier: String? = nil
}

/// Which element of a Teams window is the call's mic button, and what its
/// label says. Pure, so synthetic trees test it.
///
/// shortcut: rules come from the web client's markup (`#microphone-button`,
/// "Mute mic"/"Unmute mic"), not from a live call yet; `vedivox mute-debug` prints
/// the real tree to correct them.
enum TeamsMuteRules {
    static let micButtonId = "microphone-button"
    private static let buttonRoles: Set<String> = ["AXButton", "AXCheckBox"]

    /// nil when the element is not the mic button; `.unknown` when it is but
    /// its label names neither action.
    static func state(of node: AXNodeInfo) -> MuteState? {
        let labels = [node.description, node.title].compactMap {
            $0?.trimmingCharacters(in: .whitespaces).lowercased()
        }
        // Without the id, a button whose label is a mic action: "Mute all" or a
        // participant's "Mute <name>" in the roster must not match.
        let isMicAction = labels.contains { label in
            (starts(label, "mute") || starts(label, "unmute")) && (label.contains("mic") || label.contains("shift+m"))
        }
        guard node.domId == micButtonId || (buttonRoles.contains(node.role ?? "") && isMicAction) else { return nil }
        // The label names the action, as in Zoom: "Unmute" while muted.
        for label in labels {
            if starts(label, "unmute") { return .muted }
            if starts(label, "mute") { return .unmuted }
        }
        return .unknown
    }

    /// The first mic button in document order, with the attributes of its
    /// ancestors and its own (outermost first).
    static func find<Node>(
        in roots: [Node],
        limit: Int,
        read: (Node) -> (info: AXNodeInfo, children: [Node])?
    ) -> (state: MuteState, path: [(node: Node, info: AXNodeInfo)])? {
        var found: (MuteState, [(node: Node, info: AXNodeInfo)])?
        AXTreeWalk.walk(roots, limit: limit, read: read) { node, info, ancestors in
            guard let state = state(of: info) else { return false }
            found = (state, ancestors + [(node, info)])
            return true
        }
        return found
    }

    /// `label` is `word` alone or followed by a non-letter: "muted" is not "mute".
    private static func starts(_ label: String, _ word: String) -> Bool {
        guard label.hasPrefix(word) else { return false }
        return label.dropFirst(word.count).first.map { !$0.isLetter } ?? true
    }
}

enum AXTreeWalk {
    /// Depth-first in document order over at most `limit` elements. `visit`
    /// gets each element, its attributes and its ancestors (outermost first)
    /// and returns true to stop. Returns how many elements were read.
    @discardableResult
    static func walk<Node>(
        _ roots: [Node],
        limit: Int,
        read: (Node) -> (info: AXNodeInfo, children: [Node])?,
        visit: (Node, AXNodeInfo, [(node: Node, info: AXNodeInfo)]) -> Bool
    ) -> Int {
        var stack: [(Node, Int)] = roots.reversed().map { ($0, 0) }
        var ancestors: [(node: Node, info: AXNodeInfo)] = []
        var visited = 0
        while visited < limit, let (node, depth) = stack.popLast() {
            visited += 1
            guard let element = read(node) else { continue }
            ancestors.removeLast(ancestors.count - depth)
            if visit(node, element.info, ancestors) { break }
            ancestors.append((node, element.info))
            stack += element.children.reversed().map { ($0, depth + 1) }
        }
        return visited
    }
}

/// Reads the mute state of a Microsoft Teams call (new client) from the mic
/// button in the call toolbar, read only. Teams' UI is a web view,
/// so unlike Zoom there is no menu item to read: the button is found by
/// walking the windows' AX tree, then cached until it stops answering.
final class TeamsMuteReader: MuteReader {
    static let bundleId = "com.microsoft.teams2"
    /// A chat window's tree runs to thousands of elements; the toolbar comes early.
    static let searchLimit = 3000
    /// shortcut: a fixed pause between searches while no call is found; make it adaptive if the walk shows up in CPU.
    private static let searchPause: TimeInterval = 10

    let appName = "Teams"
    let markSource = MarkSource.teamsMute

    private var button: AXUIElement?
    private var pid: pid_t?
    private var nextSearch = Date.distantPast
    private(set) var unknownLabel: String?

    func read() -> MuteState {
        guard AXIsProcessTrusted(), let app = Self.runningApp() else {
            button = nil
            return .unknown
        }
        if pid != app.processIdentifier {
            pid = app.processIdentifier
            button = nil
            nextSearch = .distantPast
            Self.exposeWebContent(pid: app.processIdentifier)
        }
        if let button, let info = Self.read(button)?.info, let state = TeamsMuteRules.state(of: info) {
            return remember(state, info)
        }
        button = nil
        guard Date() >= nextSearch else { return .unknown }
        nextSearch = Date().addingTimeInterval(Self.searchPause)
        guard let found = TeamsMuteRules.find(in: Self.windows(pid: app.processIdentifier), limit: Self.searchLimit, read: Self.read)
        else { return .unknown }
        guard let match = found.path.last else { return .unknown }
        button = match.node
        return remember(found.state, match.info)
    }

    private func remember(_ state: MuteState, _ info: AXNodeInfo) -> MuteState {
        if state == .unknown { unknownLabel = info.description ?? info.title ?? "" }
        return state
    }

    static func runningApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
    }

    /// Chromium-based shells build their web AX tree only when asked; WebKit
    /// ones refuse the attribute, which is fine. Returns the AX error for the
    /// diagnostics.
    @discardableResult
    static func exposeWebContent(pid: pid_t) -> AXError {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, ZoomMuteReader.timeout)
        return AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func windows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, ZoomMuteReader.timeout)
        return ZoomMuteReader.value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    private static let attributes = [kAXRoleAttribute, "AXDOMIdentifier", kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute, "AXIdentifier"]

    /// One round trip per element: the walk is IPC-bound.
    static func read(_ element: AXUIElement) -> (info: AXNodeInfo, children: [AXUIElement])? {
        AXUIElementSetMessagingTimeout(element, ZoomMuteReader.timeout)
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &values) == .success,
              let values = values as? [Any], values.count == attributes.count
        else { return nil }
        // A missing attribute comes back as an AXValue error, not a string.
        let info = AXNodeInfo(
            role: values[0] as? String,
            domId: values[1] as? String,
            title: values[2] as? String,
            description: values[3] as? String,
            identifier: values[5] as? String
        )
        return (info, values[4] as? [AXUIElement] ?? [])
    }
}

/// `vedivox mute-debug`: what each reader sees now, the Teams tree around the
/// mic button — for correcting `TeamsMuteRules` from a live call — and the
/// Telemost trees a reader for it would be written from (telemost-support D4).
enum MuteDiagnostics {
    static func report() -> String {
        var out = ["accessibility trusted: \(AXIsProcessTrusted() ? "yes" : "NO — nothing can be read")"]
        out.append("Zoom: \(ZoomMuteReader().read())")
        out += teams()
        out += telemost()
        return out.joined(separator: "\n")
    }

    private static func teams() -> [String] {
        var out: [String] = []
        guard let app = TeamsMuteReader.runningApp() else {
            return ["Teams: not running (\(TeamsMuteReader.bundleId))"]
        }
        let pid = app.processIdentifier
        out.append("Teams: pid \(pid), state via reader: \(TeamsMuteReader().read())")
        out.append("AXManualAccessibility: \(TeamsMuteReader.exposeWebContent(pid: pid).rawValue) (0 = accepted)")
        let windows = TeamsMuteReader.windows(pid: pid)
        out.append("windows: \(windows.count)")
        for window in windows {
            out.append("  " + line(TeamsMuteReader.read(window)?.info))
        }
        let limit = 50000
        var visited = 0
        let found = TeamsMuteRules.find(in: windows, limit: limit) { element in
            visited += 1
            return TeamsMuteReader.read(element)
        }
        out.append("searched \(visited) elements (limit \(limit))")
        if let found {
            out.append("mic button: \(found.state)")
            out.append("path:")
            for (depth, step) in found.path.enumerated() {
                out.append(String(repeating: "  ", count: depth + 1) + line(step.info))
            }
            // The toolbar around the button: its parent's subtree, three levels down.
            if let parent = found.path.dropLast().last?.node {
                out.append("around it (parent's subtree):")
                out += subtree(parent, depth: 3)
            }
        } else {
            out.append("no mic button found; every button and checkbox seen (first 300):")
            var buttons: [String] = []
            AXTreeWalk.walk(windows, limit: limit, read: TeamsMuteReader.read) { _, info, ancestors in
                if ["AXButton", "AXCheckBox", "AXMenuButton", "AXRadioButton"].contains(info.role ?? "") {
                    buttons.append("  [depth \(ancestors.count)] " + line(info))
                }
                return buttons.count >= 300
            }
            out += buttons
        }
        return out
    }

    static let telemostBundleId = "ru.yandex.desktop.telemost"

    /// No reader yet: the app's windows and any browser window titled Telemost,
    /// every element that has a label or an id. The call tab must be the active
    /// one in its window — only that tab's page is in the window's tree.
    private static func telemost() -> [String] {
        var out: [String] = []
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: telemostBundleId).first {
            let pid = app.processIdentifier
            out.append("Telemost app: pid \(pid), no mute reader yet; labelled elements of its windows:")
            out += labelled(TeamsMuteReader.windows(pid: pid))
        } else {
            out.append("Telemost app: not running (\(telemostBundleId))")
        }
        for browser in BrowserTabDetector.browsers {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleId).first
            else { continue }
            let pid = app.processIdentifier
            let windows = TeamsMuteReader.windows(pid: pid).map { ($0, ZoomMuteReader.string($0, kAXTitleAttribute) ?? "") }
            let calls = windows.filter { ["telemost", "телемост"].contains(where: $0.1.lowercased().contains) }
            guard !calls.isEmpty else {
                out.append("\(browser.name): no window titled Telemost; titles: \(windows.map { "\"\($0.1)\"" }.joined(separator: ", "))")
                continue
            }
            out.append("\(browser.name): AXManualAccessibility \(TeamsMuteReader.exposeWebContent(pid: pid).rawValue) (0 = accepted)")
            for (window, title) in calls {
                out.append("\(browser.name) window \"\(title)\", labelled elements:")
                out += labelled([window])
            }
        }
        return out
    }

    /// Indented by depth; only elements with a label or an id, so the toolbar
    /// is not lost among thousands of anonymous groups.
    private static func labelled(_ roots: [AXUIElement]) -> [String] {
        var lines: [String] = []
        let limit = 50000
        let visited = AXTreeWalk.walk(roots, limit: limit, read: TeamsMuteReader.read) { _, info, ancestors in
            let labels = [info.title, info.description, info.domId, info.identifier].compactMap { $0 }
            if labels.contains(where: { !$0.isEmpty }) {
                lines.append(String(repeating: "  ", count: ancestors.count + 1) + line(info))
            }
            return lines.count >= 2000
        }
        return lines + ["  (\(visited) elements read, limit \(limit), first 2000 labelled shown)"]
    }

    private static func subtree(_ root: AXUIElement, depth maxDepth: Int) -> [String] {
        var lines: [String] = []
        AXTreeWalk.walk([root], limit: 500, read: TeamsMuteReader.read) { _, info, ancestors in
            if ancestors.count <= maxDepth {
                lines.append(String(repeating: "  ", count: ancestors.count + 1) + line(info))
            }
            return false
        }
        return lines
    }

    private static func line(_ info: AXNodeInfo?) -> String {
        guard let info else { return "(no answer)" }
        var parts = [info.role ?? "?"]
        if let id = info.domId, !id.isEmpty { parts.append("id=\(id)") }
        if let id = info.identifier, !id.isEmpty { parts.append("ident=\(id)") }
        if let title = info.title, !title.isEmpty { parts.append("title=\"\(title)\"") }
        if let description = info.description, !description.isEmpty { parts.append("desc=\"\(description)\"") }
        if let state = TeamsMuteRules.state(of: info) { parts.append("→ \(state)") }
        return parts.joined(separator: " ")
    }
}
