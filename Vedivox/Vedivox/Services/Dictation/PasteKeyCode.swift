import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Finds the virtual key code that ⌘V has to press on the layout in use.
///
/// Both simple answers are wrong somewhere:
///
/// - **Hard-coded 9** (`kVK_ANSI_V`) is a *position*, not a letter. On Dvorak
///   that position is «.», so the paste silently does nothing.
/// - **Plain layout lookup** breaks on «Dvorak — QWERTY ⌘», a layout that
///   deliberately reverts to QWERTY while Command is held — which is exactly
///   the moment we care about.
///
/// So the lookup is done *under the same Command modifier the `CGEvent` will
/// carry*, and 9 stays only as the fallback for layouts that report nothing
/// (input methods, and the case where Text Input Services hands back no
/// Unicode layout at all).
enum PasteKeyCode {

    /// The ANSI position of V. Correct for the majority of layouts and the only
    /// sane guess when the layout cannot be read.
    static let fallback = CGKeyCode(kVK_ANSI_V)

    /// Virtual key codes are a byte, and only the low 128 are real keys.
    private static let keyCodeRange = CGKeyCode(0) ... CGKeyCode(127)

    /// Pure scan over the keyboard: the lowest key code whose output matches.
    ///
    /// Lowest rather than any: two keys can produce the same character, and
    /// which one gets pressed must not depend on iteration order.
    static func scan(for character: Character, translate: (CGKeyCode) -> String?) -> CGKeyCode? {
        let wanted = String(character).lowercased()
        for code in keyCodeRange {
            guard let produced = translate(code)?.lowercased(), produced == wanted else { continue }
            return code
        }
        return nil
    }

    /// Resolves the key against the layout the user is typing with right now.
    ///
    /// Not cached: switching layout mid-session is normal, and 128 in-memory
    /// translations cost microseconds against a paste that already waits on the
    /// pasteboard.
    static func resolve() -> CGKeyCode {
        guard let layoutData = currentLayoutData() else {
            Log.debug("Dictation: no Unicode layout data, falling back to keycode \(fallback) for ⌘V")
            return fallback
        }

        let keyboardType = UInt32(LMGetKbdType())
        // The modifier byte UCKeyTranslate expects — the same Command the
        // synthetic event will carry, which is what makes the hybrid
        // Dvorak-QWERTY layouts answer correctly.
        let commandModifiers = UInt32((cmdKey >> 8) & 0xFF)

        let resolved: CGKeyCode? = (layoutData as Data).withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            return scan(for: "v") { code in
                translate(code, layout: layout, modifiers: commandModifiers, keyboardType: keyboardType)
            }
        }

        if resolved == nil {
            Log.debug("Dictation: layout produced no \"v\", falling back to keycode \(fallback) for ⌘V")
        }
        return resolved ?? fallback
    }

    // MARK: - Text Input Services

    /// `TISCopyCurrentKeyboardLayoutInputSource` rather than
    /// `TISCopyCurrentKeyboardInputSource`: with an input method active (Japanese,
    /// Pinyin) the latter returns the input method, which carries no Unicode
    /// layout at all.
    private static func currentLayoutData() -> CFData? {
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        guard
            let source,
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
    }

    private static func translate(
        _ code: CGKeyCode,
        layout: UnsafePointer<UCKeyboardLayout>,
        modifiers: UInt32,
        keyboardType: UInt32
    ) -> String? {
        // Fresh per key: a shared state would let one dead key change what the
        // next one reports.
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0

        let status = UCKeyTranslate(
            layout,
            UInt16(code),
            UInt16(kUCKeyActionDisplay),
            modifiers,
            keyboardType,
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )

        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
