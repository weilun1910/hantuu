import Foundation

/// What hantuu passes to each agent so it reports its state, all on the command line or in
/// the chat's environment. Nothing here writes to ~/.claude, ~/.codex or any transcript.
///
/// Every chat gets `HANTUU_EVENTS=<data dir>/events/<chat id>.jsonl`. Claude Code's hooks and
/// Codex's `notify` append one JSON object per line to it, and StatusCenter tails it.
enum AgentHooks {
    static let envKey = "HANTUU_EVENTS"

    static var eventsDir: URL { Paths.dataDir.appendingPathComponent("events", isDirectory: true) }
    static func eventsFile(for chatID: UUID) -> URL { eventsDir.appendingPathComponent("\(chatID.uuidString).jsonl") }

    /// The environment a chat's terminal starts with, on top of the inherited one.
    static func environment(for chatID: UUID) -> [String: String] {
        Paths.ensure(eventsDir)
        Paths.ensure(ClaudeUsage.dir)
        // HANTUU_USAGE: where Claude's status line saves its usage limits (Usage/).
        return [envKey: eventsFile(for: chatID).path, ClaudeUsage.envKey: ClaudeUsage.file(for: chatID).path,
                ReaderRequestBridge.envKey: ReaderRequestBridge.directory(for: chatID).path,
                ReaderRequestBridge.chatEnvKey: chatID.uuidString]
    }

    // MARK: Claude Code

    /// Hooked events. PermissionRequest fires the moment a prompt appears; the Notification
    /// hook's permission_prompt comes about six seconds later and is only a fallback.
    static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                               "PostToolUseFailure", "Notification", "Stop", "StopFailure", "SessionEnd"]

    /// Appends the event JSON from stdin as one line. It prints nothing and always exits 0, so
    /// it never adds context, blocks a tool or answers a prompt. Parallel hooks (subagents)
    /// take turns: `lockf` holds a flock on the open events file while the line is written,
    /// because the shell's printf writes a long line in several pieces.
    static let appendCommand =
        #"if [ -n "$HANTUU_EVENTS" ]; then p=$(cat); { lockf -s -t 5 1; printf '%s\n' "$p"; } >> "$HANTUU_EVENTS"; else cat >/dev/null; fi 2>/dev/null; exit 0"#

    /// PostToolUse carries the tool's whole output, so only the event name and the
    /// tool_use_id (the last one in the payload, after tool_response) are kept.
    static func compactCommand(_ event: String) -> String {
        #"if [ -n "$HANTUU_EVENTS" ]; then i=$(sed -n 's/.*"tool_use_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]*\)".*/\1/p' | tail -n 1); { lockf -s -t 5 1; printf '{"hook_event_name":"@NAME@","tool_use_id":"%s"}\n' "$i"; } >> "$HANTUU_EVENTS"; else cat >/dev/null; fi 2>/dev/null; exit 0"#
            .replacingOccurrences(of: "@NAME@", with: event)
    }

    static func claudeCommand(for event: String) -> String {
        if event == "PermissionRequest" { return permissionCommand }
        return event == "PostToolUse" || event == "PostToolUseFailure" ? compactCommand(event) : appendCommand
    }

    /// The helper owns one synchronous request; a missing reader lease produces no decision.
    /// Keep the status event, and never run shell text supplied by a tool's arguments.
    static var permissionCommand: String {
        guard let executable = Bundle.main.executableURL?.path else { return appendCommand }
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return #"p=$(cat); if [ -n "$HANTUU_EVENTS" ]; then { lockf -s -t 5 1; printf '%s\n' "$p"; } >> "$HANTUU_EVENTS"; fi 2>/dev/null; printf '%s' "$p" | "#
            + quoted + " " + ReaderRequestBridge.flag + " 2>/dev/null; exit 0"
    }

    /// The JSON for `claude --settings`. Hooks from it are added to the user's own hooks
    /// rather than replacing them. When it's on, the status line saves Claude's usage limits
    /// for the sidebar's rings and then runs the user's own status line (Usage/UsageLimits.swift).
    static var claudeSettingsJSON: String { claudeSettingsJSON(statusLine: ClaudeUsage.statusLineEnabled) }

    static func claudeSettingsJSON(statusLine: Bool) -> String {
        var hooks: [String: Any] = [:]
        for event in claudeEvents {
            hooks[event] = [["hooks": [["type": "command", "command": claudeCommand(for: event),
                                        "timeout": event == "PermissionRequest" ? 95 : 10]]]]
        }
        var settings: [String: Any] = ["hooks": hooks]
        if statusLine { settings["statusLine"] = ClaudeUsage.statusLineSettings }
        let data = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static var claudeArguments: [String] { ["--settings", claudeSettingsJSON] }

    // MARK: Codex

    /// Codex calls `notify` with the event JSON as its last argument. This writes it to the
    /// events file, then runs the user's own notify command (if they have one) exactly as Codex
    /// would have, so a notify set in ~/.codex/config.toml keeps working in hantuu chats.
    static let codexNotifyScript =
        #"for a; do j=$a; done; if [ -n "$HANTUU_EVENTS" ]; then printf '%s\n' "$j" >> "$HANTUU_EVENTS"; fi 2>/dev/null; if [ $# -gt 1 ]; then exec "$@"; fi; exit 0"#

    enum NotifyLookup: Equatable {
        case none
        case found([String])
        /// A notify key hantuu can't read safely. hantuu then leaves notify alone.
        case unreadable
    }

    static var codexConfigFile: URL {
        if let dir = ProcessInfo.processInfo.environment["CODEX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("config.toml")
        }
        return Paths.home.appendingPathComponent(".codex/config.toml")
    }

    private static var notifyCache: (NotifyLookup, Date)?

    /// Reads (never writes) the top-level `notify = [...]` from Codex's config. Cached for a
    /// few seconds, because menus ask for resume arguments while they draw.
    static func existingCodexNotify(_ url: URL = codexConfigFile) -> NotifyLookup {
        if url == codexConfigFile, let (value, at) = notifyCache, Date().timeIntervalSince(at) < 10 { return value }
        let value: NotifyLookup
        if let text = try? String(contentsOf: url, encoding: .utf8) { value = parseNotify(toml: text) } else { value = .none }
        if url == codexConfigFile { notifyCache = (value, Date()) }
        return value
    }

    static func parseNotify(toml text: String) -> NotifyLookup {
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }   // tables start: only top-level keys count
            guard line.hasPrefix("notify") else { continue }
            let rest = line.dropFirst("notify".count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { continue }
            let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            guard let arr = parseStringArray(value), !arr.isEmpty else { return .unreadable }
            return .found(arr)
        }
        return .none
    }

    /// A one-line TOML array of strings: ["a", 'b', "c\"d"], with an optional trailing comment.
    static func parseStringArray(_ s: String) -> [String]? {
        var chars = Array(s)
        var i = 0
        func skipSpace() { while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 } }
        guard i < chars.count, chars[i] == "[" else { return nil }
        i += 1
        var out: [String] = []
        while true {
            skipSpace()
            guard i < chars.count else { return nil }
            if chars[i] == "]" { i += 1; break }
            if chars[i] == "\"" {
                i += 1
                var v = ""
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count {
                        i += 1
                        switch chars[i] {
                        case "n": v.append("\n")
                        case "t": v.append("\t")
                        case "\\": v.append("\\")
                        case "\"": v.append("\"")
                        default: return nil   // \u escapes and friends: not worth guessing
                        }
                    } else {
                        v.append(chars[i])
                    }
                    i += 1
                }
                guard i < chars.count else { return nil }
                i += 1
                out.append(v)
            } else if chars[i] == "'" {
                i += 1
                var v = ""
                while i < chars.count, chars[i] != "'" { v.append(chars[i]); i += 1 }
                guard i < chars.count else { return nil }
                i += 1
                out.append(v)
            } else {
                return nil
            }
            skipSpace()
            guard i < chars.count else { return nil }
            if chars[i] == "," { i += 1; continue }
            if chars[i] == "]" { i += 1; break }
            return nil
        }
        skipSpace()
        chars = Array(chars[i...])
        if !chars.isEmpty && chars.first != "#" { return nil }
        return out
    }

    static func tomlString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if u.value < 0x20 || u.value == 0x7F { out += String(format: "\\u%04X", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    static func tomlArray(_ items: [String]) -> String { "[" + items.map(tomlString).joined(separator: ",") + "]" }

    /// `-c` overrides for one Codex run. tui.notifications makes Codex send an OSC 9 desktop
    /// notification for approvals and questions, which libghostty hands to hantuu.
    static func codexArguments(existingNotify: NotifyLookup = existingCodexNotify()) -> [String] {
        var args = [
            "-c", "tui.notifications=" + tomlArray(["approval-requested", "plan-mode-prompt", "async-question"]),
            "-c", "tui.notification_method=\"osc9\"",
            "-c", "tui.notification_condition=\"always\"",
            "-c", "tui.terminal_title=" + tomlArray(["session-id", "thread-name"]),
        ]
        switch existingNotify {
        case .none:
            args += ["-c", "notify=" + tomlArray(["/bin/sh", "-c", codexNotifyScript, "hantuu-notify"])]
        case .found(let original):
            args += ["-c", "notify=" + tomlArray(["/bin/sh", "-c", codexNotifyScript, "hantuu-notify"] + original)]
        case .unreadable:
            break   // turn ends still come from the rollout
        }
        return args
    }
}
