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
    /// Lines in an agent's prompt footer. Claude Code and Codex show one of these once their
    /// message box is up (a permission mode replaces Claude Code's "? for shortcuts" with
    /// "shift+tab to cycle"), and "esc to interrupt" while a turn runs.
    static let readyMarks = ["for shortcuts", "context left", "shift+tab to cycle", "esc to interrupt"]

    static let trustMarks = ["do you trust", "trust the files", "trust this folder", "trust the contents",
                             "allow codex to work in this folder", "one you trust"]
    static let updateMarks = ["update available", "update now", "skip until"]
    static let menuMarks = ["enter to confirm", "enter to select", "press enter to continue", "to navigate", "(y/n)",
                            "esc to cancel", "esc to close", "esc to go back", "escape to close", "press any key to continue"]

    /// Claude Code and Codex both show this while a turn runs.
    static let busyMark = "esc to interrupt"

    struct State: Equatable {
        /// The agent has drawn its prompt.
        var ready = false
        /// A turn is running on screen.
        var busy = false
        var menu: ScreenMenu?
    }

    enum CodexPicker: Equatable { case model, reasoning }

    /// Codex omits "to" in these picker hints. Match the title and selected numbered
    /// list as well as the footer, so model names in an answer are not treated as a menu.
    static func codexPicker(_ screen: String) -> CodexPicker? {
        let rows = screen.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }.filter { !$0.isEmpty }
        guard let title = rows.lastIndex(where: {
            $0 == "select model and effort" || $0 == "select model" || $0.hasPrefix("select reasoning level for ")
        }) else { return nil }
        let body = Array(rows.dropFirst(title + 1))
        let footer = body.suffix(3).joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let kind: CodexPicker = rows[title].hasPrefix("select reasoning") ? .reasoning : .model
        guard footer.contains("esc back"),
              footer.contains(kind == .model ? "enter select" : "enter default"),
              body.contains(where: { $0.range(of: #"^›\s*\d+\.\s+\S"#, options: .regularExpression) != nil }),
              !body.suffix(3).contains(where: { line in readyMarks.contains(where: line.contains) }) else { return nil }
        return kind
    }

    /// Looks at the bottom of the screen only, where agents draw their menus, so a phrase in
    /// earlier output doesn't count.
    static func analyze(_ screen: String, lines tail: Int = 16) -> State {
        let lines = screen.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(tail)
        let lower = lines.map { $0.lowercased() }
        let ready = lower.contains { l in readyMarks.contains { l.contains($0) } }
        let busy = lower.contains { $0.contains(busyMark) }
        func find(_ marks: [String]) -> String? {
            for (i, l) in lower.enumerated() where marks.contains(where: { l.contains($0) }) {
                return clean(lines[lines.startIndex + i])
            }
            return nil
        }
        var menu: ScreenMenu?
        if let l = find(trustMarks) {
            menu = ScreenMenu(kind: .trust, line: l)
        } else if let l = find(updateMarks) {
            menu = ScreenMenu(kind: .update, line: l)
        } else if codexPicker(screen) != nil {
            menu = ScreenMenu(kind: .menu, line: "Choose a model or reasoning level in the terminal.")
        } else if find(menuMarks) != nil {
            // The footer only says how to pick; the first line of the box says what it's about.
            menu = ScreenMenu(kind: .menu, line: "Answer it in the terminal.")
        }
        return State(ready: ready, busy: busy, menu: menu)
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

    /// How many Backspaces clear what a stopped turn put back in the agent's input box, or 0
    /// when the box doesn't show any of `sent`. Claude Code draws its box between the last two
    /// rules at the bottom of the screen; elsewhere the last few lines count. It errs long,
    /// since a Backspace in an empty box does nothing.
    static func restoredLength(screen: String, sent: [String]) -> Int {
        guard !sent.isEmpty else { return 0 }
        let lines = screen.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(14)
        func isRule(_ l: String) -> Bool {
            let t = l.trimmingCharacters(in: .whitespaces)
            return t.count >= 10 && Double(t.filter { "─━═".contains($0) }.count) >= Double(t.count) * 0.8
        }
        let rules = lines.indices.filter { isRule(lines[$0]) }
        let box: [String]
        if rules.count >= 2, let last = rules.last, let prev = rules.dropLast().last, last - prev > 1 {
            box = Array(lines[(prev + 1)..<last])
        } else {
            box = Array(lines.suffix(6))
        }
        let text = box.joined(separator: " ").lowercased()
        let shows = text.contains("[pasted text") || sent.contains { s in
            let first = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
            let key = String(first.trimmingCharacters(in: .whitespaces).prefix(24)).lowercased()
            return !key.isEmpty && text.contains(key)
        }
        guard shows else { return 0 }
        let total = sent.reduce(0) { $0 + $1.unicodeScalars.count } + sent.count + 4
        return min(total, 4000)
    }

    /// Files as the shell-escaped paths a terminal drop would type, space separated.
    static func paths(_ urls: [URL]) -> String {
        urls.filter(\.isFileURL).map { ShellEscape.escape($0.path) }.joined(separator: " ")
    }

    // MARK: Attachments

    /// Agents that turn a pasted image path into an "[Image #N]" attachment. Both need the path
    /// pasted on its own: a path inside other text stays text. Codex also wants one path per
    /// paste, and neither takes a TIFF or HEIC, so those are converted to PNG first.
    static let imageAgents: Set<String> = ["claude", "codex"]

    struct OutgoingFile: Equatable, Codable {
        var path: String
        /// Pasted on its own so the agent attaches it as an image.
        var image: Bool
    }

    /// The files to send for a chat's agent. Pictures the agents can't read as images are
    /// converted to PNG (PastedImages.convert); everything else goes as its path.
    static func outgoingFiles(_ attachments: [ComposerAttachment], agentID: String, convert: (URL) -> URL? = { PastedImages.convert($0) }) -> [OutgoingFile] {
        let aware = imageAgents.contains(agentID)
        return attachments.map { a in
            guard aware, !a.isFolder else { return OutgoingFile(path: a.url.path, image: false) }
            if a.isImage { return OutgoingFile(path: a.url.path, image: true) }
            if a.isPicture, let png = convert(a.url) { return OutgoingFile(path: png.path, image: true) }
            return OutgoingFile(path: a.url.path, image: false)
        }
    }

    /// What reader mode types into the agent for a message: each image's path as a paste of its
    /// own (the agent shows it as "[Image #N]"), then the text with any other files' paths after
    /// it, then Return.
    static func steps(text: String?, files: [OutgoingFile], agentID: String) -> [SendStep] {
        let images = files.filter(\.image)
        let others = files.filter { !$0.image }.map { ShellEscape.escape($0.path) }
        var body = text ?? ""
        if !others.isEmpty {
            let list = others.joined(separator: " ")
            body = body.isEmpty ? list : body + (body.contains("\n") ? "\n\n" : " ") + list
        }
        // Claude Code puts nothing between its image chip and pasted text after it.
        if !images.isEmpty && !body.isEmpty && agentID == "claude", ComposerCommandTransport.invocation(body) == nil { body = " " + body }
        // A message that starts with a path isn't a slash command.
        if text == nil && body.hasPrefix("/") { body = " " + body }
        var out = images.map { SendStep.image(ShellEscape.escape($0.path)) }
        if !body.isEmpty {
            if text != nil, ComposerCommandTransport.invocation(body) != nil,
               ["claude", "codex"].contains(agentID) { out.append(.command(body)) }
            else { out.append(.paste(body)) }
        }
        if !out.isEmpty { out.append(.pressReturn) }
        return out
    }

    /// How many "[Image #N]" chips the bottom of the agent's screen shows. Reader mode waits for
    /// this to go up after pasting an image, so the agent has read it before anything follows.
    static func imageMarks(_ screen: String) -> Int {
        let tail = screen.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(12)
        return tail.reduce(0) { $0 + $1.components(separatedBy: "[Image #").count - 1 }
    }
}

/// One thing reader mode types into the agent's terminal when a message goes out.
enum SendStep: Equatable {
    /// Slash commands stay literal input, never a pasted-text placeholder.
    case command(String)
    /// Text, as one bracketed paste.
    case paste(String)
    /// An image's escaped path as a paste of its own. The next step waits until the agent
    /// shows one more image chip. Timeout must fail the transaction without sending Return.
    case image(String)
    /// A real Return key, a moment after the last paste.
    case pressReturn
}

extension TerminalView {
    /// Encodes one printable key at a time. A multi-character key event has no physical
    /// key identity and can be encoded differently when the CLI enables the Kitty protocol.
    func typeCommandText(_ text: String) {
        guard let surface else { return }
        for scalar in text.unicodeScalars {
            guard scalar.value >= 0x20, scalar.value != 0x7F else { continue }
            var event = ghostty_input_key_s()
            event.action = GHOSTTY_ACTION_PRESS
            let key = GhosttyInput.commandKey(scalar)
            event.keycode = key.code
            event.mods = key.shift ? GHOSTTY_MODS_SHIFT : GHOSTTY_MODS_NONE
            event.consumed_mods = event.mods
            event.unshifted_codepoint = key.unshifted
            event.composing = false
            String(scalar).withCString {
                event.text = $0
                _ = ghostty_surface_key(surface, event)
                event.action = GHOSTTY_ACTION_RELEASE
                _ = ghostty_surface_key(surface, event)
            }
        }
    }

    /// Paces the literal command token beyond Codex's paste-burst threshold. Cancellation
    /// is checked before every key, including when a chat ends during the sequence.
    func typeCommandToken(_ text: String, while allowed: @escaping () -> Bool, completion: @escaping () -> Void) {
        let keys = text.unicodeScalars.map(String.init)
        func send(_ index: Int) {
            guard allowed() else { completion(); return }
            guard index < keys.count else { completion(); return }
            self.typeCommandText(keys[index])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { send(index + 1) }
        }
        send(0)
    }

    func pressCommandMenuDown() {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.keycode = 125
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.composing = false
        key.action = GHOSTTY_ACTION_PRESS
        _ = ghostty_surface_key(surface, key)
        key.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, key)
    }

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

    /// Presses Backspace `times` times as real key events.
    func pressBackspace(times: Int) {
        guard let surface, times > 0 else { return }
        var ev = ghostty_input_key_s()
        ev.keycode = 51            // kVK_Delete, the Backspace key
        ev.mods = GHOSTTY_MODS_NONE
        ev.consumed_mods = GHOSTTY_MODS_NONE
        ev.text = nil
        ev.unshifted_codepoint = 0x7F
        ev.composing = false
        for _ in 0..<times {
            ev.action = GHOSTTY_ACTION_PRESS
            _ = ghostty_surface_key(surface, ev)
            ev.action = GHOSTTY_ACTION_RELEASE
            _ = ghostty_surface_key(surface, ev)
        }
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
