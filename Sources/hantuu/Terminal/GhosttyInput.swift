// Keyboard, mouse and pasteboard helpers for hosting a libghostty surface.
//
// Adapted from Ghostty's macOS app: macos/Sources/Ghostty/Ghostty.Input.swift,
// NSEvent+Extension.swift, Ghostty.Shell.swift, Helpers/KeyboardLayout.swift and
// Helpers/Extensions/NSPasteboard+Extension.swift (Ghostty v1.4.0).
// MIT License, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors.
import AppKit
import Carbon
import GhosttyKit
import UniformTypeIdentifiers

enum GhosttyInput {
    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var f = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { f.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { f.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { f.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { f.insert(.command) }
        return f
    }

    static func mouseButton(_ number: Int) -> ghostty_input_mouse_button_e {
        switch number {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_FOUR
        case 4: return GHOSTTY_MOUSE_FIVE
        case 5: return GHOSTTY_MOUSE_SIX
        case 6: return GHOSTTY_MOUSE_SEVEN
        case 7: return GHOSTTY_MOUSE_EIGHT
        case 8: return GHOSTTY_MOUSE_NINE
        case 9: return GHOSTTY_MOUSE_TEN
        case 10: return GHOSTTY_MOUSE_ELEVEN
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    /// Packed scroll mods: bit 0 precision, bits 1-3 momentum phase (matches Zig ScrollMods).
    static func scrollMods(precision: Bool, phase: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        var value: Int32 = precision ? 1 : 0
        let momentum: Int32
        switch phase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        value |= momentum << 1
        return value
    }

    static var keyboardLayoutID: String? {
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            return unsafeBitCast(ptr, to: CFString.self) as String
        }
        return nil
    }
}

/// A physical key passed through Ghostty, which chooses the negotiated terminal encoding.
struct TerminalKeyStroke: Equatable {
    var keyCode: UInt32
    var codepoint: UInt32
    var modifiers: NSEvent.ModifierFlags = []
}

extension TerminalView {
    func pressKeys(_ keys: [TerminalKeyStroke]) {
        guard let surface else { return }
        for key in keys {
            var event = ghostty_input_key_s()
            event.keycode = key.keyCode
            event.unshifted_codepoint = key.codepoint
            event.mods = GhosttyInput.mods(key.modifiers)
            event.consumed_mods = GHOSTTY_MODS_NONE
            event.text = nil
            event.composing = false
            event.action = GHOSTTY_ACTION_PRESS
            _ = ghostty_surface_key(surface, event)
            event.action = GHOSTTY_ACTION_RELEASE
            _ = ghostty_surface_key(surface, event)
        }
    }
}

extension NSEvent {
    /// A Ghostty key event for this NSEvent, without text (the caller owns the C string).
    func ghosttyKeyEvent(_ action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(keyCode)
        ev.text = nil
        ev.composing = false
        ev.mods = GhosttyInput.mods(modifierFlags)
        // Control and command never contribute to text translation; assume the rest did.
        ev.consumed_mods = GhosttyInput.mods((translationMods ?? modifierFlags).subtracting([.control, .command]))
        ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp,
           let chars = characters(byApplyingModifiers: []),
           let cp = chars.unicodeScalars.first {
            ev.unshifted_codepoint = cp.value
        }
        return ev
    }

    /// Text to send with a key event. Control characters are left to Ghostty's encoder and
    /// function keys (private use area) send no text.
    var ghosttyCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }
}

extension String {
    /// The string as key-event text, or nil when empty or starting with a control character.
    var keyEventText: String? {
        guard let first = unicodeScalars.first, !isEmpty else { return nil }
        if first.value < 0x20 || first.value == 0x7F { return nil }
        return self
    }
}

enum ShellEscape {
    private static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    /// Backslash-escape shell-sensitive characters, for typing a path at a live prompt.
    static func escape(_ s: String) -> String {
        var result = s
        for ch in escapeCharacters {
            result = result.replacingOccurrences(of: String(ch), with: "\\\(ch)")
        }
        return result
    }

    /// Single-quote a string so a shell reads it as one literal argument (like shlex.quote).
    static func quote(_ s: String) -> String {
        if !s.isEmpty, s.range(of: #"[^\w@%+=:,./-]"#, options: .regularExpression) == nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
    }
}

extension NSPasteboard.PasteboardType {
    init?(hantuuMime mime: String) {
        if mime == "text/plain" { self = .string; return }
        if let ut = UTType(mimeType: mime) { self.init(ut.identifier) } else { self.init(mime) }
    }
}

extension NSPasteboard {
    /// File URLs become shell-escaped absolute paths; otherwise plain strings.
    func hantuuStringContents() -> String? {
        let strings = (pasteboardItems ?? []).compactMap { item -> String? in
            if let plist = item.propertyList(forType: .fileURL),
               let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?, url.isFileURL {
                return ShellEscape.escape(url.path)
            }
            return item.string(forType: .string)
        }
        return strings.isEmpty ? nil : strings.joined(separator: " ")
    }

    func hantuuData(forMime mime: String) -> Data? {
        switch mime {
        case "text/plain":
            return hantuuStringContents().map { Data($0.utf8) }
        case "text/uri-list":
            let urls = (pasteboardItems ?? []).compactMap { item -> URL? in
                guard let plist = item.propertyList(forType: .fileURL) else { return nil }
                return NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?
            }
            return urls.isEmpty ? nil : Data(urls.map { $0.absoluteString + "\r\n" }.joined().utf8)
        default:
            guard let t = NSPasteboard.PasteboardType(hantuuMime: mime) else { return nil }
            return data(forType: t)
        }
    }

    func hantuuAvailableMimes() -> [String] {
        var result: [String] = []
        let types = self.types ?? []
        if types.contains(.fileURL) || types.contains(.string) { result.append("text/plain") }
        if types.contains(.fileURL) { result.append("text/uri-list") }
        for t in types {
            if let mime = UTType(t.rawValue)?.preferredMIMEType, !result.contains(mime), mime != "text/plain;charset=utf-8" {
                result.append(mime)
            }
        }
        return result
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// Mix toward white (positive) or black (negative) by `amount` (0...1).
    func adjusted(_ amount: CGFloat) -> NSColor {
        guard let c = usingColorSpace(.sRGB) else { return self }
        let target: CGFloat = amount >= 0 ? 1 : 0
        let a = abs(amount)
        return NSColor(srgbRed: c.redComponent + (target - c.redComponent) * a,
                       green: c.greenComponent + (target - c.greenComponent) * a,
                       blue: c.blueComponent + (target - c.blueComponent) * a,
                       alpha: c.alphaComponent)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#161616" }
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
