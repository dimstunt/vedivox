// Lists the main-window controls Vedivox names for accessibility.
// Build: swiftc -O -o "$TMPDIR/ax_probe" scripts/ax_probe.swift — needs Accessibility permission for the terminal.
// System Events' `entire contents` walks the same tree in minutes and reports
// SwiftUI buttons as description="button"; the AX API below sees the labels.
import AppKit
import ApplicationServices

func attr(_ el: AXUIElement, _ name: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    if let s = v as? String { return s }
    return nil
}
func children(_ el: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
          let arr = v as? [AXUIElement] else { return [] }
    return arr
}
var found = 0, buttons = 0
func walk(_ el: AXUIElement, depth: Int) {
    if depth > 40 { return }
    let role = attr(el, kAXRoleAttribute) ?? ""
    let id = attr(el, "AXIdentifier") ?? ""
    let title = attr(el, kAXTitleAttribute) ?? ""
    let desc = attr(el, kAXDescriptionAttribute) ?? ""
    if role == "AXButton" { buttons += 1 }
    if id.hasPrefix("recording.") || id.hasPrefix("sidebar.") || id.hasPrefix("toolbar.") {
        found += 1
        print("\(role) id=\(id) title='\(title)' desc='\(desc)' help='\(attr(el, kAXHelpAttribute) ?? "")'")
    }
    for c in children(el) { walk(c, depth: depth + 1) }
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.dimstunt.Vedivox").first else {
    print("Vedivox not running"); exit(1)
}
let ax = AXUIElementCreateApplication(app.processIdentifier)
walk(ax, depth: 0)
print("buttons=\(buttons) matched=\(found)")
