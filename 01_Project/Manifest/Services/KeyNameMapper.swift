import CoreGraphics
import Carbon.HIToolbox

/// Maps a `CGKeyCode` + active modifier flags to a human-readable label like
/// "Cmd+S" or "Return". Pure, side-effect-free — safe to call from the
/// CGEventTap callback on the main run loop.
enum KeyNameMapper {
    /// Produce a labelled key string. Always includes any held modifiers as
    /// `Cmd+`, `Shift+`, etc. prefixes, ordered like macOS menu shortcuts.
    static func label(forKeyCode keyCode: UInt16, modifiers: CGEventFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.maskControl)   { parts.append("Ctrl") }
        if modifiers.contains(.maskAlternate) { parts.append("Opt") }
        if modifiers.contains(.maskShift)     { parts.append("Shift") }
        if modifiers.contains(.maskCommand)   { parts.append("Cmd") }
        parts.append(named(keyCode))
        return parts.joined(separator: "+")
    }

    /// Label used when the user holds and releases a modifier alone (no other
    /// key in the chord). Returns nil for non-modifier flags.
    static func modifierOnlyLabel(for flag: CGEventFlags) -> String? {
        switch flag {
        case .maskCommand:     return "Cmd"
        case .maskShift:       return "Shift"
        case .maskControl:     return "Ctrl"
        case .maskAlternate:   return "Opt"
        case .maskSecondaryFn: return "Fn"
        default:               return nil
        }
    }

    /// Best-effort mapping from virtual keycode → display name. Letters,
    /// digits, and common punctuation come from the active keyboard layout
    /// via `UCKeyTranslate`; named keys (Return, Tab, arrows, etc.) come from
    /// a hard-coded table because their printable representations are useless
    /// in a HUD.
    static func named(_ keyCode: UInt16) -> String {
        if let named = namedKeys[Int(keyCode)] { return named }
        if let translated = translate(keyCode), !translated.isEmpty {
            return translated.uppercased()
        }
        return "Key \(keyCode)"
    }

    private static let namedKeys: [Int: String] = [
        kVK_Return: "Return",
        kVK_Tab: "Tab",
        kVK_Space: "Space",
        kVK_Delete: "Delete",
        kVK_Escape: "Esc",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_DownArrow: "↓",
        kVK_UpArrow: "↑",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_Home: "Home",
        kVK_End: "End",
        kVK_PageUp: "PgUp",
        kVK_PageDown: "PgDn",
        kVK_ForwardDelete: "Fwd Del",
        kVK_Help: "Help",
        kVK_CapsLock: "Caps",
    ]

    private static func translate(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        guard let layoutDataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue()
        let keyLayoutPtr = CFDataGetBytePtr(layoutData)
        return keyLayoutPtr?.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout -> String? in
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
