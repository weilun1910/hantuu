import AppKit
import GhosttyKit

/// What the bottom of reader mode shows for the selected chat, worked out from its status and
/// what's on its terminal screen. Pure, so the self test can check every case.
enum ComposerMode: Equatable {
    /// No message box: the agent has ended, or the chat has no live terminal.
    case none
    /// The agent hasn't drawn its prompt yet. Typing works, sending waits.
    case starting
    /// Its prompt is waiting.
    case ready
    /// Running a turn. Sending still works: the agent takes it the way it would from its own box.
    case working(detail: String)
    /// It ended its turn on a question. The answer goes in the message box.
    case asked(question: String)
    /// A menu is waiting in the terminal (permission, a question with options, trust, an
    /// update). Return would pick that menu's default, so nothing is sent until it's answered
    /// in the terminal.
    case blocked(title: String, detail: String)

    var canSend: Bool {
        switch self {
        case .ready, .working, .asked: return true
        case .none, .starting, .blocked: return false
        }
    }

    var isWorking: Bool { if case .working = self { return true }; return false }
    var isBlocked: Bool { if case .blocked = self { return true }; return false }

    struct Input {
        var agentName: String
        var ended: Bool
        var live: Bool
        var activity: AgentActivity
        var detail: String
        /// A permission prompt or question menu is open (StatusState.waits), as opposed to a
        /// question asked in the agent's final message.
        var waiting: Bool
        /// The agent has drawn its prompt at least once.
        var ready: Bool
        /// A menu found on the terminal screen.
        var screenMenu: ScreenMenu?
    }

    static func resolve(_ i: Input) -> ComposerMode {
        if i.ended || !i.live || i.activity == .ended { return .none }
        if i.activity.isNeeds && i.waiting {
            let title = i.activity == .needsPermission ? "\(i.agentName) needs your permission" : "\(i.agentName) is asking you"
            return .blocked(title: title, detail: i.detail.isEmpty ? "Waiting in the terminal" : i.detail)
        }
        if let m = i.screenMenu { return .blocked(title: m.title(agent: i.agentName), detail: m.line) }
        if !i.ready { return .starting }
        if i.activity == .working { return .working(detail: i.detail.isEmpty ? "Working" : i.detail) }
        if i.activity == .needsAnswer {
            let q = i.detail.hasPrefix("Asks: ") ? String(i.detail.dropFirst(6)) : i.detail
            return .asked(question: q)
        }
        return .ready
    }
}

/// A menu on the agent's screen that reader mode can't answer. Found by text, from the last
/// lines of the terminal. Permission prompts and AskUserQuestion come from the agent's own
/// status signals instead; this catches the rest (trusting a folder, an update offer, a picker
/// opened by a slash command).
struct ScreenMenu: Equatable {
    enum Kind: Equatable { case trust, update, menu }
    var kind: Kind
    var line: String

    func title(agent: String) -> String {
        switch kind {
        case .trust: return "\(agent) asks whether to trust this folder"
        case .update: return "\(agent) is offering an update"
        case .menu: return "\(agent) is showing a menu"
        }
    }
}

enum TerminalScreen {
    /// Lines in an agent's idle prompt footer. Claude Code and Codex both show one of these
    /// once their message box is up.
    static let readyMarks = ["for shortcuts", "context left"]

    static let trustMarks = ["do you trust", "trust the files", "trust this folder", "trust the contents",
                             "allow codex to work in this folder", "one you trust"]
    static let updateMarks = ["update available", "update now", "skip until"]
    static let menuMarks = ["enter to confirm", "enter to select", "press enter to continue", "to navigate", "(y/n)"]

    /// Looks at the bottom of the screen only, where agents draw their menus, so a phrase in
    /// earlier output doesn't count.
    static func analyze(_ screen: String, lines tail: Int = 16) -> (ready: Bool, menu: ScreenMenu?) {
        let lines = screen.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(tail)
        let lower = lines.map { $0.lowercased() }
        let ready = lower.contains { l in readyMarks.contains { l.contains($0) } }
        func find(_ marks: [String]) -> String? {
            for (i, l) in lower.enumerated() where marks.contains(where: { l.contains($0) }) {
                return clean(lines[lines.startIndex + i])
            }
            return nil
        }
        if let l = find(trustMarks) { return (ready, ScreenMenu(kind: .trust, line: l)) }
        if let l = find(updateMarks) { return (ready, ScreenMenu(kind: .update, line: l)) }
        if find(menuMarks) != nil {
            // The footer only says how to pick; the first line of the box says what it's about.
            return (ready, ScreenMenu(kind: .menu, line: "Answer it in the terminal."))
        }
        return (ready, nil)
    }

    /// Box-drawing borders and bullets around a TUI line, stripped.
    static func clean(_ s: String) -> String {
        let junk = CharacterSet(charactersIn: "│┃║╭╮╰╯─━═┌┐└┘|>›❯●○◯•·*✻✳ ")
        let t = s.trimmingCharacters(in: junk)
        return t.count > 140 ? String(t.prefix(139)) + "…" : t
    }
}

enum ComposerMessage {
    /// What gets typed into the agent: line endings made plain, blank lines and trailing
    /// spaces at either end dropped. Nil if there's nothing to send.
    static func prepare(_ raw: String) -> String? {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Dropped files as the shell-escaped paths a terminal drop would type, space separated.
    static func paths(_ urls: [URL]) -> String {
        urls.filter(\.isFileURL).map { ShellEscape.escape($0.path) }.joined(separator: " ")
    }
}

extension TerminalView {
    /// Presses Esc in the terminal as a real key event. Claude Code and Codex both stop the
    /// running turn on Esc.
    func pressEscape() {
        guard let surface else { return }
        var ev = ghostty_input_key_s()
        ev.action = GHOSTTY_ACTION_PRESS
        ev.keycode = 53            // kVK_Escape
        ev.mods = GHOSTTY_MODS_NONE
        ev.consumed_mods = GHOSTTY_MODS_NONE
        ev.text = nil
        ev.unshifted_codepoint = 0x1B
        ev.composing = false
        _ = ghostty_surface_key(surface, ev)
        ev.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, ev)
    }

    /// The text of the visible screen, without scrollback.
    func activeScreenText() -> String {
        guard let surface else { return "" }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }
}
