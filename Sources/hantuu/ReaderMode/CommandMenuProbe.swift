import Foundation

/// The terminal is the authority for account, plugin and feature gates. Screens contain
/// text but no selection colors, so several Down presses can produce identical text.
enum CommandMenuScreen {
    static func rows(_ screen: String) -> [ReaderCommand] {
        let pattern = #"^[\t ]*[│┃║>›❯●○*\t ]*/([A-Za-z][A-Za-z0-9_:-]*)[\t ]{2,}(\S[^\n]*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return [] }
        let ns = screen as NSString
        return regex.matches(in: screen, range: NSRange(location: 0, length: ns.length)).map {
            ReaderCommand(name: ns.substring(with: $0.range(at: 1)),
                          description: ns.substring(with: $0.range(at: 2)).trimmingCharacters(in: .whitespaces),
                          source: "agent menu", precedence: 100)
        }
    }

    /// Only recognize a single-line input box. Unknown layouts and existing drafts must
    /// stay untouched. Slash suggestion rows have descriptions and cannot be input rows.
    static func input(_ screen: String, agent: String) -> String? {
        let marker = agent == "claude" ? "❯" : "›"
        let lines = screen.components(separatedBy: "\n")
        for index in lines.indices.suffix(20).reversed() {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line == marker || line.hasPrefix(marker + " ") else { continue }
            guard rows(line).isEmpty else { continue }
            // Reject a continuation line instead of mistaking an empty first line of a
            // multiline draft for an empty composer. A rule or footer closes the box.
            for raw in lines.dropFirst(index + 1) {
                let next = raw.trimmingCharacters(in: .whitespaces)
                if next.isEmpty || !rows(next).isEmpty { continue }
                let lower = next.lowercased()
                let rule = next.count >= 3 && next.allSatisfy { "─━═│┃║ ".contains($0) }
                let footer = TerminalScreen.readyMarks.contains(where: lower.contains) ||
                    lower.hasPrefix("gpt-") || lower.contains("for agents") || lower.contains("/effort")
                if rule || footer { break }
                return nil
            }
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func emptyInput(_ screen: String, agent: String) -> Bool {
        guard let input = input(screen, agent: agent) else { return false }
        if input.isEmpty { return true }
        // Codex paints this placeholder inside an otherwise empty composer.
        if agent == "codex" { return input == "Ask Codex to do anything" }
        // Claude's first empty prompt paints one of these suggestions. Match its complete
        // templates, not an arbitrary sentence starting with Try or a queued-message hint.
        guard agent == "claude" else { return false }
        let suggestion = #"\ATry "(?:fix lint errors|fix typecheck errors|how do I log an error\?|create a util logging\.py that\.\.\.|how does [^"\r\n]+ work\?|refactor [^"\r\n]+|edit [^"\r\n]+ to\.\.\.|write a test for [^"\r\n]+)"\z"#
        return input.range(of: suggestion, options: .regularExpression) != nil
    }

    static func safe(_ screen: String) -> Bool {
        let state = TerminalScreen.analyze(screen)
        guard !state.busy, state.menu?.kind != .trust, state.menu?.kind != .update else { return false }
        let lower = screen.split(whereSeparator: \.isNewline).suffix(24).joined(separator: "\n").lowercased()
        return !["do you want to proceed", "would you like to run", "allow this tool", "allow once",
                 "yes, allow", "approve this", "requires approval", "permission required", "sign in to",
                 "log in to", "select login method"].contains(where: lower.contains)
    }

    /// A complete observed menu limits slash suggestions, while disk metadata supplies
    /// argument hints and picker behavior. Dollar skills remain a separate Codex menu.
    static func reconcile(_ commands: [ReaderCommand], observed: [ReaderCommand], complete: Bool) -> [ReaderCommand] {
        let names = Set(observed.map(\.name))
        var result = commands.filter {
            !complete || $0.sigil != "/" || names.contains($0.name) || $0.aliasOf.map(names.contains) == true
        }
        for row in observed {
            if let index = result.firstIndex(where: { $0.token == row.token }) {
                result[index].description = row.description
                result[index].userInvocable = true
                if result[index].source == "CLI fallback" { result[index].source = "agent menu" }
            } else { result.append(row) }
        }
        return ReaderCommandLogic.merged(result)
    }
}

struct CommandMenuTraversal {
    private(set) var commands: [ReaderCommand] = []
    private(set) var steps = 0
    private(set) var unchanged = 0
    private(set) var largestPage = 0
    static let limit = 512

    mutating func observe(_ rows: [ReaderCommand]) {
        let old = Set(commands.map(\.name))
        commands = ReaderCommandLogic.merged(commands + rows)
        unchanged = Set(commands.map(\.name)) == old ? unchanged + 1 : 0
        largestPage = max(largestPage, rows.count)
        steps += 1
    }

    var finished: Bool { !commands.isEmpty && unchanged >= max(16, largestPage + 2) }
    var capped: Bool { steps >= Self.limit && !finished }
}

/// A cancellable, non-submitting traversal. The caller owns the exclusive input lease.
/// It never writes provider files, launches a process or reads account caches.
final class CommandMenuProbe {
    struct IO {
        var screen: () -> String
        var allowed: () -> Bool
        var slash: () -> Void
        var down: () -> Void
        var escape: () -> Void
        var backspace: () -> Void
    }
    private let agent: String
    private let io: IO
    private let completion: ([ReaderCommand], Bool) -> Void
    private var traversal = CommandMenuTraversal()
    private var active = true
    private var ownsInput = false
    private var emptyReads = 0

    init(agent: String, io: IO, completion: @escaping ([ReaderCommand], Bool) -> Void) {
        self.agent = agent
        self.io = io
        self.completion = completion
    }

    @discardableResult
    func start() -> Bool {
        let screen = io.screen()
        guard io.allowed(), CommandMenuScreen.safe(screen), TerminalScreen.analyze(screen).menu == nil,
              CommandMenuScreen.emptyInput(screen, agent: agent) else { active = false; return false }
        ownsInput = true
        io.slash()
        schedule(0.4)
        return true
    }

    /// Cancellation clears only the slash this probe inserted, never a user's draft.
    /// Call this before exposing the terminal or before another producer takes its input.
    func cancel() {
        guard active else { return }
        active = false
        clean()
    }

    private func clean() {
        guard ownsInput else { return }
        ownsInput = false
        let screen = io.screen()
        guard CommandMenuScreen.safe(screen), (CommandMenuScreen.input(screen, agent: agent) == "/" || CommandMenuScreen.emptyInput(screen, agent: agent)) else { return }
        io.escape()
        io.backspace()
    }

    private func schedule(_ delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.step() }
    }

    private func step() {
        guard active else { return }
        let screen = io.screen()
        guard io.allowed(), CommandMenuScreen.safe(screen), CommandMenuScreen.input(screen, agent: agent) == "/" else {
            cancel()
            completion([], false)
            return
        }
        let rows = CommandMenuScreen.rows(screen)
        if rows.isEmpty {
            emptyReads += 1
            if emptyReads < 10 { schedule(0.2); return }
            cancel()
            completion([], false)
            return
        }
        traversal.observe(rows)
        if traversal.finished || traversal.capped {
            active = false
            clean()
            // Let Esc and Backspace draw before another operation can submit input.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                let cleared = CommandMenuScreen.emptyInput(self.io.screen(), agent: self.agent)
                self.completion(self.traversal.commands, self.traversal.finished && cleared)
            }
            return
        }
        io.down()
        schedule(0.12)
    }
}
