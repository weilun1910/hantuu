import Foundation

enum TranscriptKind: String, Codable {
    case claude, codex
}

/// A coding agent hantuu knows how to launch. Only installed ones are shown.
struct AgentDefinition: Identifiable, Hashable {
    let id: String          // also the executable name
    let name: String
    let transcript: TranscriptKind?
    var path: String? = nil

    /// The command line inside the login shell. Never adds permission-bypass flags.
    func launchArguments(sessionID: String?) -> [String] {
        switch id {
        case "claude":
            if let sessionID { return ["claude", "--session-id", sessionID] }
            return ["claude"]
        default:
            return [id]
        }
    }

    func resumeArguments(sessionID: String) -> [String]? {
        switch id {
        case "claude": return ["claude", "--resume", sessionID]
        case "codex": return ["codex", "resume", sessionID]
        default: return nil
        }
    }
}

enum AgentCatalog {
    static let known: [AgentDefinition] = [
        AgentDefinition(id: "claude", name: "Claude Code", transcript: .claude),
        AgentDefinition(id: "codex", name: "Codex", transcript: .codex),
        AgentDefinition(id: "gemini", name: "Gemini CLI", transcript: nil),
        AgentDefinition(id: "opencode", name: "opencode", transcript: nil),
        AgentDefinition(id: "amp", name: "Amp", transcript: nil),
        AgentDefinition(id: "cursor-agent", name: "Cursor Agent", transcript: nil),
        AgentDefinition(id: "aider", name: "Aider", transcript: nil),
    ]

    static func definition(_ id: String) -> AgentDefinition {
        known.first(where: { $0.id == id }) ?? AgentDefinition(id: id, name: id, transcript: nil)
    }

    static let beginMarker = "__HANTUU_AGENTS_BEGIN__"
    static let endMarker = "__HANTUU_AGENTS_END__"

    /// The script run inside the login shell. It only looks things up; it runs no agent.
    static var detectScript: String {
        let names = known.map(\.id).joined(separator: " ")
        return "echo \(beginMarker); for b in \(names); do p=$(command -v \"$b\" 2>/dev/null) && echo \"$b=$p\"; done; echo \(endMarker)"
    }

    /// Parses `name=/abs/path` lines between the markers. Aliases and functions are skipped,
    /// since only real executables can be launched with `exec`.
    static func parseDetectOutput(_ output: String) -> [String: String] {
        guard let start = output.range(of: beginMarker) else { return [:] }
        let tail = output[start.upperBound...]
        let body = tail.range(of: endMarker).map { tail[..<$0.lowerBound] } ?? tail
        var found: [String: String] = [:]
        for line in body.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let path = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("/"), known.contains(where: { $0.id == name }) { found[name] = path }
        }
        return found
    }

    /// Detects installed agents through the user's login shell, because a GUI app doesn't
    /// inherit the PATH you have in Ghostty (claude and codex often live in ~/.local/bin).
    static func detect(timeout: TimeInterval = 10) -> [AgentDefinition] {
        let output = LoginShell.run(detectScript, timeout: timeout)
        let found = parseDetectOutput(output)
        return known.compactMap { def in
            guard let p = found[def.id] else { return nil }
            var d = def
            d.path = p
            return d
        }
    }
}

enum LoginShell {
    /// The user's login shell from the password database (not $SHELL, which a GUI app may lack).
    static var path: String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty { return s }
        }
        return "/bin/zsh"
    }

    /// The command string handed to libghostty for an agent chat. libghostty itself wraps it
    /// as `login -flp <user> bash -c "exec -l <this>"`, so the agent ends up under a login,
    /// interactive shell: the same environment you get in a Ghostty window.
    /// It clears the screen first, so a chat opens on the agent rather than on login(1)'s
    /// "Last login" line.
    /// With a `session`, the agent runs inside hantuu-session, which keeps it alive after the
    /// app quits. The helper inherits the login shell's environment and hands it to the agent.
    static func surfaceCommand(_ argv: [String], session: SessionLaunch? = nil) -> String {
        let command = session?.arguments(wrapping: argv) ?? argv
        let inner = "printf '\\033[H\\033[2J'; exec " + command.map(ShellEscape.quote).joined(separator: " ")
        return "\(ShellEscape.quote(path)) -l -i -c \(ShellEscape.quote(inner))"
    }

    /// Runs a script in a login, interactive shell and returns stdout. stdin is /dev/null.
    static func run(_ script: String, timeout: TimeInterval) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-l", "-i", "-c", script]
        p.currentDirectoryURL = Paths.home
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            Log.write("login shell failed to start: \(error)")
            return ""
        }
        var data = Data()
        let reader = DispatchQueue(label: "hantuu.loginshell")
        let group = DispatchGroup()
        group.enter()
        reader.async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            Log.write("login shell timed out")
            _ = group.wait(timeout: .now() + 1)
        }
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
