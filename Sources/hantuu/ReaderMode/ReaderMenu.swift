import Foundation

/// A visible TUI menu. Labels and context remain verbatim so an approval cannot silently
/// become a different command with the same Yes button.
struct ReaderMenu: Equatable {
    enum Kind: String { case choice, permission, question, multiSelect, model, effort, search, settings, trust, update, freeText }
    struct Option: Equatable {
        var label: String
        var number: Int?
        var checked: Bool? = nil
        var detail: String = ""
    }
    struct Input: Equatable {
        var value: String
        var placeholder: String
    }
    var input: Input? = nil
    let agent: String
    var kind: Kind
    var title: String
    var context: String
    var options: [Option]
    var selected: String?
    var footer: String
    var tabs: String? = nil
    var horizontalSelection = false
    var allowsHorizontal = false
    var allowsTab = false
    var allowsText = false
    var cancelKey = ReaderMenuKey.escape
    var refusal: String? = nil

    var actionable: Bool { refusal == nil && (input != nil || selected != nil && !options.isEmpty) }
    var isCodexHookTrust: Bool { agent == "codex" && kind == .trust && title == "Hooks need review" }
    var allowsSessionConfirm: Bool {
        [.model, .effort].contains(kind) && (footer.lowercased().contains("s session") || footer.lowercased().contains("s for this session only"))
    }
    var identity: String { [agent, kind.rawValue, title, context, tabs ?? "", footer].joined(separator: "\n") }
    func sameForm(as other: ReaderMenu) -> Bool {
        identity == other.identity && options == other.options
    }
}

enum ReaderMenuKey: Equatable {
    case up, down, left, right, tab, notes, escape, enter, space, session
}

/// Screen text has no color attributes. A color-only highlight is deliberately not guessed.
/// Footer evidence must be at the bottom, and a real pointer must identify one unique row.
enum ReaderMenuParser {
    static func parse(_ screen: String, agent: String) -> ReaderMenu? {
        guard ["claude", "codex"].contains(agent), screen.utf8.count < 131_072 else { return nil }
        let lines = screen.components(separatedBy: .newlines).map(trim).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        if let trust = codexHookTrust(lines, agent: agent) { return trust }
        if let input = codexInput(lines, agent: agent) { return input }
        if let effort = claudeEffort(lines, agent: agent) { return effort }
        let tail = lines.suffix(4).joined(separator: " ").lowercased()
        let confirms = ["enter to confirm", "enter to select", "enter select", "enter default", "enter to submit", "enter to resume", "enter to toggle", "enter to continue", "enter confirm", "enter select", "space to select", "space to toggle", "switch questions", "tab/arrow keys to navigate"]
        let cancels = ["esc to cancel", "esc to close", "esc to go back", "esc back", "esc to interrupt", "escape to cancel", "esc to exit", "esc cancel", "esc close", "escape cancel", "esc to save"]
        guard confirms.contains(where: tail.contains), cancels.contains(where: tail.contains),
              !TerminalScreen.readyMarks.filter({ $0 != TerminalScreen.busyMark }).contains(where: tail.contains) else { return nil }
        guard let footerIndex = lines.lastIndex(where: { line in
            let lower = line.lowercased()
            return cancels.contains(where: lower.contains)
        }), footerIndex >= lines.count - 4 else { return nil }
        let footer = lines[footerIndex...].joined(separator: "\n")
        let rowPattern = #"^(?:(❯|›|>)\s*)?(?:(\d+)\.\s+)?(?:(☒|☐|\[×\]|\[x\]|\[ \]|◉|◯|\(\*\)|\( \))\s*)?(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: rowPattern) else { return nil }
        struct Row { var index: Int; var label: String; var number: Int?; var checked: Bool?; var focused: Bool }
        var rows: [Row] = []
        let lastHeading = (0..<footerIndex).last(where: { isHeading(lines[$0]) })
        for index in (lastHeading.map { $0 + 1 } ?? 0)..<footerIndex {
            let line = lines[index], ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            func group(_ n: Int) -> String { match.range(at: n).location == NSNotFound ? "" : ns.substring(with: match.range(at: n)) }
            let pointer = !group(1).isEmpty, number = Int(group(2)), mark = group(3)
            guard pointer || number != nil || !mark.isEmpty else { continue }
            let label = group(4).trimmingCharacters(in: .whitespaces)
            // A bare composer or free-text placeholder is not an option to confirm.
            guard !label.isEmpty, !label.hasPrefix("/"), !label.hasPrefix("Type your answer"),
                  !label.hasPrefix("Type something") else { continue }
            let checked: Bool? = mark.isEmpty ? nil : ["☒", "[×]", "[x]", "◉", "(*)"].contains(mark)
            rows.append(Row(index: index, label: label, number: number, checked: checked, focused: pointer))
        }
        if agent == "claude", rows.contains(where: { $0.checked != nil }),
           let submit = (0..<footerIndex).last(where: { lines[$0] == "Submit" }),
           submit > (rows.last?.index ?? footerIndex) {
            rows.append(Row(index: submit, label: "Submit", number: nil, checked: nil, focused: false))
        }
        guard !rows.isEmpty, rows.count >= 2 else { return nil }
        // Never turn numbered conversation prose above a picker into actionable rows.
        // A recognized heading bounds the list; unknown forms use the nearest separator.
        let headingIndex = lastHeading
        if let headingIndex { rows.removeAll { $0.index <= headingIndex } }
        guard let start = rows.first, rows.count >= 2, start.index > 0 else { return nil }
        let headerStart = headingIndex ?? (lines[..<start.index].lastIndex(where: isRule).map { $0 + 1 } ?? max(0, start.index - 8))
        let header = Array(lines[headerStart..<start.index].filter { !isRule($0) })
        guard let title = header.first, !title.isEmpty else { return nil }
        let lower = header.joined(separator: " ").lowercased()
        let kind: ReaderMenu.Kind
        if TerminalScreen.trustMarks.contains(where: lower.contains) { kind = .trust }
        else if TerminalScreen.updateMarks.contains(where: lower.contains) { kind = .update }
        else if ["would you like to run", "would you like to make", "do you want to proceed", "allow this", "permission", "approve", "ready to code", "implement this plan"].contains(where: lower.contains) { kind = .permission }
        else if lower.contains("reasoning") || lower.contains("effort") && !lower.contains("model") { kind = .effort }
        else if lower.contains("select model") { kind = .model }
        else if lower.contains("resume") || lower.contains("search sessions") { kind = .search }
        else if lower.contains("config") || lower.contains("settings") { kind = .settings }
        else if rows.contains(where: { $0.checked != nil }) { kind = .multiSelect }
        else if lower.contains("question") || tail.contains("switch questions") || tail.contains("submit answer") { kind = .question }
        else { kind = .choice }
        let securityContext: String
        if [.permission, .trust, .update].contains(kind), headerStart > 0 {
            securityContext = lines[..<start.index].filter { !isRule($0) && $0 != title }.joined(separator: "\n")
        } else { securityContext = header.dropFirst().joined(separator: "\n") }
        let labels = rows.map(\.label)
        let focus = rows.filter(\.focused)
        var refusal: String?
        if focus.count != 1 { refusal = "The terminal does not expose one highlighted option. Use Show Terminal." }
        if Set(labels).count != labels.count { refusal = "Two options have the same label. Use Show Terminal." }
        if labels.contains(where: { $0.contains("…") || $0.hasSuffix("...") }) { refusal = "An option is truncated. Use Show Terminal to read it in full." }
        let numbered = rows.compactMap(\.number)
        if !numbered.isEmpty && (rows.contains(where: { $0.number == nil && $0.checked == nil && $0.label != "Submit" }) || Set(numbered).count != numbered.count) {
            refusal = "The option numbering is incomplete. Use Show Terminal."
        }
        // An unmarked sibling cannot be distinguished from its description. Never guess.
        if numbered.isEmpty && rows.contains(where: { $0.checked == nil && $0.label != "Submit" }) {
            refusal = "This list uses styling that screen text cannot identify. Use Show Terminal."
        }
        let options = rows.enumerated().map { offset, row -> ReaderMenu.Option in
            let end = offset + 1 < rows.count ? rows[offset + 1].index : footerIndex
            let detail = lines[(row.index + 1)..<end].filter { !isRule($0) }.joined(separator: "\n")
            return ReaderMenu.Option(label: row.label, number: row.number, checked: row.checked, detail: detail)
        }
        let tabs = header.first { $0.lowercased().hasPrefix("question ") || $0.contains("❮") || $0.contains("✔") }
        var result = ReaderMenu(agent: agent, kind: kind, title: title, context: securityContext,
                                options: options, selected: focus.first?.label, footer: footer, tabs: tabs, refusal: refusal)
        result.allowsHorizontal = tail.contains("←/→") || tail.contains("left/right") || tail.contains("adjust effort") || tail.contains("← →")
        result.allowsTab = tail.contains("tab") && (tail.contains("question") || tail.contains("notes") || tail.contains("filter"))
        // Text is enabled only for a recognizable active filter, never an arbitrary Other
        // label. Other inputs whose focus is represented only by color stay in the terminal.
        result.allowsText = kind == .search && lines.contains { $0.hasPrefix("Search:") || $0.hasPrefix("Filter:") }
        if kind == .multiSelect && agent == "codex" { result.refusal = "This checkbox layout has not been verified for Codex. Use Show Terminal." }
        return result
    }

    /// rust-v0.167.1 startup_hooks_review uses "esc skip", and wraps the last choice
    /// at narrow widths. Require every complete source label before sending any key.
    /// Trust all is deliberately not relabelled as trusting only hantuu's hook.
    private static func codexHookTrust(_ lines: [String], agent: String) -> ReaderMenu? {
        guard agent == "codex", let heading = lines.lastIndex(of: "Hooks need review"),
              let footer = lines.last, footer.lowercased().contains("enter confirm"),
              footer.lowercased().contains("esc skip"), heading < lines.count - 1,
              !TerminalScreen.readyMarks.contains(where: footer.lowercased().contains) else { return nil }
        let body = Array(lines[(heading + 1)..<(lines.count - 1)])
        let explanation = "hantuu's hook forwards Bash and apply_patch approval requests to the reader. Codex saves trust for this hook across launches. Trust all also trusts the other hooks listed by Codex. Choose Review hooks to inspect them."
        let expected = ["Review hooks", "Trust all and continue", "Continue without trusting (hooks won't run)"]
        let regex = try! NSRegularExpression(pattern: #"^(?:(›)\s*)?([1-3])\.\s+(.+)$"#)
        var options: [ReaderMenu.Option] = []
        var focus: [Int] = []
        var header: [String] = []
        for line in body {
            let ns = line as NSString
            if let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let number = Int(ns.substring(with: match.range(at: 2)))!
                if match.range(at: 1).location != NSNotFound { focus.append(options.count) }
                options.append(.init(label: ns.substring(with: match.range(at: 3)), number: number))
            } else if options.isEmpty { header.append(line) }
            else { options[options.count - 1].label += " " + line }
        }
        let complete = options.map(\.label) == expected && options.map(\.number) == [1, 2, 3]
        let selected = complete && focus.count == 1 ? options[focus[0]].label : nil
        // If indexes or any label are hidden/truncated, retain the actual screen as
        // context, with Show Terminal available and every approval control disabled.
        let context = (complete ? header : body).joined(separator: "\n") + "\n\n" + explanation
        return ReaderMenu(agent: agent, kind: .trust, title: "Hooks need review", context: context,
            options: complete ? options : [], selected: selected, footer: footer,
            refusal: selected == nil ? "The complete hook choices and highlight are not visible. Use Show Terminal." : nil)
    }

    /// Claude 2.1.322 draws a fixed-width effort track. Accept its exact geometry,
    /// including capped prefixes, and refuse the automatic state with no triangle.
    private static func claudeEffort(_ lines: [String], agent: String) -> ReaderMenu? {
        guard agent == "claude", let heading = lines.lastIndex(of: "Effort"),
              let trackIndex = lines.indices.last(where: { lines[$0].contains("▲") }), trackIndex > heading else { return nil }
        let levels = ["low", "medium", "high", "xhigh", "max"]
        let starts = [0, 8, 19, 28, 39], positions = [1, 10, 20, 30, 40]
        let track = Array(lines[trackIndex])
        guard track.allSatisfy({ $0 == "─" || $0 == "▲" }), track.filter({ $0 == "▲" }).count == 1,
              let triangle = track.firstIndex(of: "▲"), let selected = positions.firstIndex(of: triangle) else { return nil }
        var count: Int?
        for n in 2...5 {
            var labels = ""
            for index in 0..<n {
                labels += String(repeating: " ", count: max(0, starts[index] - labels.count)) + levels[index]
            }
            if lines[(heading + 1)..<trackIndex].contains(labels), track.count == max(starts[n - 1] + levels[n - 1].count, 14) { count = n }
        }
        guard let count, selected < count else { return nil }
        let footer = lines.suffix(3).filter { !$0.allSatisfy({ $0 == "─" || $0 == "▲" }) }.joined(separator: "\n")
        let lower = footer.lowercased()
        guard !TerminalScreen.readyMarks.contains(where: lower.contains), (lower.contains("enter to confirm") || lower.contains("enter confirm")),
              (lower.contains("esc to cancel") || lower.contains("esc cancel")), lower.contains("adjust") else { return nil }
        return ReaderMenu(agent: agent, kind: .effort, title: "Effort", context: "",
            options: levels.prefix(count).enumerated().map { ReaderMenu.Option(label: $0.element, number: $0.offset + 1) },
            selected: levels[selected], footer: footer, horizontalSelection: true, allowsHorizontal: true)
    }

    /// The notes view has both a selected option pointer and an input pointer. Its own
    /// footer, rather than pointer count alone, establishes which one accepts text.
    private static func codexInput(_ lines: [String], agent: String) -> ReaderMenu? {
        guard agent == "codex", let heading = lines.lastIndex(where: {
            $0.range(of: #"^Question \d+/\d+ \("#, options: .regularExpression) != nil
        }), let footer = lines.last,
              footer.contains("enter to submit answer") || footer.contains("enter to submit all"),
              footer.contains("esc to interrupt") || footer.contains("tab or esc to clear notes"),
              let index = lines.indices.last(where: { lines[$0].hasPrefix("› ") }),
              index > heading, index == lines.count - 2 else { return nil }
        let raw = String(lines[index].dropFirst(2))
        guard raw.range(of: #"^\d+\. "#, options: .regularExpression) == nil else { return nil }
        let notes = footer.contains("clear notes")
        if !notes, lines[(heading + 1)..<index].contains(where: {
            $0.range(of: #"^(?:› )?\d+\. "#, options: .regularExpression) != nil
        }) { return nil }
        let placeholder = notes ? "Add notes" : "Type your answer (optional)"
        return ReaderMenu(input: .init(value: raw == placeholder ? "" : raw, placeholder: placeholder),
            agent: agent, kind: .freeText, title: lines[heading],
            context: lines[(heading + 1)..<index].joined(separator: "\n"), options: [], selected: nil,
            footer: footer, tabs: lines[heading], allowsTab: notes, allowsText: true)
    }

    private static func trim(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r│┃║"))
    }
    private static func isRule(_ line: String) -> Bool {
        line.count >= 3 && line.allSatisfy { "─━═╭╮╰╯┌┐└┘ ".contains($0) }
    }
    private static func isHeading(_ line: String) -> Bool {
        let s = line.lowercased()
        return ["select model", "select reasoning", "select effort", "would you like to run", "would you like to make", "do you want to proceed", "do you trust", "trust this folder", "update available", "resume a past session", "resume session", "question ", "settings", "config", "update model permissions", "ready to code", "ready to submit"].contains(where: s.hasPrefix)
    }
}

/// Pure closed-loop selection. No numeric shortcut is forwarded because some providers
/// submit it immediately. Every arrow is observed before another key, and Return requires
/// two matching reads of the exact selected label and unchanged command/question context.
struct ReaderMenuSelection {
    enum Effect: Equatable { case key(ReaderMenuKey), wait, done, refuse(String) }
    let original: ReaderMenu
    let label: String
    let confirm: Bool
    let sessionOnly: Bool
    private var expectedFocus: String?
    private var lastFocus: String?
    private var readyToConfirm = false
    private var submitted = false

    init(menu: ReaderMenu, label: String, confirm: Bool = true, sessionOnly: Bool = false) {
        original = menu; self.label = label; self.confirm = confirm; self.sessionOnly = sessionOnly
    }

    mutating func observe(_ menu: ReaderMenu?, closed: Bool) -> Effect {
        if submitted {
            if closed { return .done }
            guard let menu else { return .wait }
            if !original.sameForm(as: menu) || menu.selected != label { return .done }
            return .wait
        }
        guard let menu, menu.actionable, original.sameForm(as: menu),
              let selected = menu.selected,
              let current = menu.options.firstIndex(where: { $0.label == selected }),
              let target = menu.options.firstIndex(where: { $0.label == label }) else {
            return .refuse("The menu changed. No confirmation key was sent. Use Show Terminal.")
        }
        if let expectedFocus {
            if selected == lastFocus { return .wait }
            guard selected == expectedFocus else { return .refuse("The terminal highlighted a different option. No confirmation key was sent.") }
            self.expectedFocus = nil
        }
        if selected != label {
            readyToConfirm = false
            let next = current + (target > current ? 1 : -1)
            expectedFocus = menu.options[next].label
            lastFocus = selected
            return .key(menu.horizontalSelection ? (target > current ? .right : .left) : (target > current ? .down : .up))
        }
        if !confirm { return .done }
        if !readyToConfirm { readyToConfirm = true; return .wait }
        if sessionOnly && !menu.allowsSessionConfirm { return .refuse("This menu does not expose a session-only choice.") }
        submitted = true
        if sessionOnly { return .key(.session) }
        if original.kind == .multiSelect, original.options[target].checked != nil { return .key(.space) }
        return .key(.enter)
    }
}

/// The free-text path never erases an existing terminal draft. A changed echo refuses
/// Return, and a completed submission is only observed, never replayed.
struct ReaderMenuTextSubmission {
    let original: ReaderMenu
    let text: String
    private var matchingReads = 0
    private var submitted = false

    init(menu: ReaderMenu, text: String) { original = menu; self.text = text }

    static func suffix(for text: String, menu: ReaderMenu) -> String? {
        guard menu.actionable, let input = menu.input, text.utf8.count <= 4096,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              text.hasPrefix(input.value) else { return nil }
        return String(text.dropFirst(input.value.count))
    }

    mutating func observe(_ menu: ReaderMenu?, closed: Bool) -> ReaderMenuSelection.Effect {
        if submitted {
            if closed { return .done }
            guard let menu else { return .wait }
            return !original.sameForm(as: menu) || menu.input?.value != text ? .done : .wait
        }
        guard Self.suffix(for: text, menu: original) != nil, let menu, menu.actionable,
              original.sameForm(as: menu), let input = menu.input else {
            return .refuse("The answer field changed. Return was not sent. Use Show Terminal.")
        }
        if input.value == text {
            matchingReads += 1
            if matchingReads >= 2 { submitted = true; return .key(.enter) }
        } else if input.value == original.input?.value { matchingReads = 0 }
        else { return .refuse("The terminal text does not match the answer. Return was not sent.") }
        return .wait
    }
}
