import AppKit
import GhosttyKit

extension TerminalView {
    /// Presses Return in the terminal as a real key event, so the program sees Enter rather
    /// than a pasted newline (which a bracketed paste would keep inside the input box).
    func pressReturn() {
        guard let surface else { return }
        var ev = ghostty_input_key_s()
        ev.action = GHOSTTY_ACTION_PRESS
        ev.keycode = 36            // kVK_Return
        ev.mods = GHOSTTY_MODS_NONE
        ev.consumed_mods = GHOSTTY_MODS_NONE
        ev.text = nil
        ev.unshifted_codepoint = 13
        ev.composing = false
        _ = ghostty_surface_key(surface, ev)
        ev.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, ev)
    }

    /// Types a message the way a person would paste it, then presses Return once the
    /// program has taken the paste in. Text with newlines arrives as one bracketed paste in
    /// agents that ask for it (Claude Code, Codex); Ghostty's paste protection asks first in
    /// programs that don't.
    func submit(_ text: String, returnDelay: TimeInterval = 0.3) {
        pasteText(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + returnDelay) { [weak self] in self?.pressReturn() }
    }
}

enum ReviewFormat {
    /// "~/Desktop/project" for paths under the home folder, and "iCloud Drive/..." for iCloud
    /// Drive, the way Finder names it.
    static func tilde(_ path: String) -> String {
        let home = Paths.home.path
        let icloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if path == icloud { return "iCloud Drive" }
        if path.hasPrefix(icloud + "/") { return "iCloud Drive" + path.dropFirst(icloud.count) }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: n % 1_000_000 == 0 ? "%.0fM" : "%.1fM", Double(n) / 1_000_000) }
        if n >= 1000 { return "\(Int((Double(n) / 1000).rounded()))k" }
        return "\(n)"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "under a minute" }
        let m = s / 60, h = m / 60, d = h / 24
        if d > 0 { return "\(d)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m % 60)m" }
        return "\(m)m"
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "d MMM HH:mm"
        return f.string(from: date)
    }

    static func statusColor(_ s: Character) -> NSColor {
        switch s {
        case "A", "?": return ReviewColors.added
        case "D": return ReviewColors.removed
        case "R": return NSColor(hex: 0x8FB4F0)
        case "U": return Theme.error
        default: return NSColor(hex: 0xD9B36C)
        }
    }
}

/// Muted diff colours: readable on the neutral darks without glowing.
enum ReviewColors {
    static let added = NSColor(hex: 0x7DB88F)
    static let removed = NSColor(hex: 0xD88A8A)
    static let pending = NSColor(hex: 0xD9B36C)
    static let card = NSColor(white: 1, alpha: 0.025)
}
