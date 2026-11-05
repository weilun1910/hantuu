import Foundation

/// Where a signal came from. The reducer uses this to keep one source of truth per state.
enum SignalOrigin: Equatable {
    case hook        // Claude Code hooks, appended to the chat's events file
    case notify      // Codex `notify`, appended to the same file
    case transcript  // the agent's own transcript or rollout file
    case terminal    // OSC 9 / OSC 777 notifications, the bell, OSC 9;4 progress
}

/// Everything that can move a chat's state, normalised from every source.
enum StatusSignal: Equatable {
    case sessionStarted(source: String)
    case promptSubmitted
    case toolStarted(id: String?, call: ToolCall)
    case permissionRequested(call: ToolCall)
    case toolFinished(id: String?)
    case declined(id: String?)
    case turnEnded(lastMessage: String?)
    case turnFailed(reason: String)
    case interrupted
    case notification(type: String, message: String)
    case sessionEnded(reason: String)
    case codexTurnStarted(id: String)
    case codexTurnComplete(id: String?, lastMessage: String?)
    case codexTurnAborted(id: String?, reason: String)
    /// A terminal notification's text, or nil for a bell.
    case terminalNotice(text: String?)
    case progress(active: Bool)
}

struct OriginSignal: Equatable {
    var origin: SignalOrigin
    var signal: StatusSignal
}

// MARK: - Claude Code hook lines

/// One line of the events file written by the hooks hantuu passes with `--settings`.
/// PostToolUse and PostToolUseFailure lines are cut down to the event name and tool_use_id
/// by the hook itself, because their tool_response can be megabytes.
enum HookLineParser {
    static func parse(_ line: Data, cwd: String?) -> [OriginSignal] {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return [] }
        if let event = obj["hook_event_name"] as? String {
            return claude(event, obj, cwd: cwd).map { OriginSignal(origin: .hook, signal: $0) }
        }
        if let type = obj["type"] as? String, type == "agent-turn-complete" {
            let turn = obj["turn-id"] as? String
            let last = obj["last-assistant-message"] as? String
            return [OriginSignal(origin: .notify, signal: .codexTurnComplete(id: turn, lastMessage: last))]
        }
        return []
    }

    /// The transcript a SessionStart line points at, if it is one.
    static func sessionTranscript(_ line: Data) -> String? {
        guard line.range(of: Data(#""SessionStart""#.utf8)) != nil,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              obj["hook_event_name"] as? String == "SessionStart",
              let path = obj["transcript_path"] as? String, !path.isEmpty else { return nil }
        return (path as NSString).expandingTildeInPath
    }

    static func claude(_ event: String, _ obj: [String: Any], cwd fallbackCwd: String?) -> [StatusSignal] {
        let cwd = (obj["cwd"] as? String) ?? fallbackCwd
        let agentID = obj["agent_id"] as? String
        func call() -> ToolCall {
            ToolCall(name: obj["tool_name"] as? String ?? "Tool", input: obj["tool_input"] as? [String: Any] ?? [:],
                     cwd: cwd, agentID: agentID)
        }
        switch event {
        case "SessionStart":
            return [.sessionStarted(source: obj["source"] as? String ?? "startup")]
        case "UserPromptSubmit":
            return [.promptSubmitted]
        case "PreToolUse":
            return [.toolStarted(id: obj["tool_use_id"] as? String, call: call())]
        case "PermissionRequest":
            return [.permissionRequested(call: call())]
        case "PostToolUse", "PostToolUseFailure":
            let id = (obj["tool_use_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return [.toolFinished(id: id)]
        case "Stop":
            return [.turnEnded(lastMessage: obj["last_assistant_message"] as? String)]
        case "StopFailure":
            let reason = (obj["last_assistant_message"] as? String) ?? (obj["error"] as? String) ?? "API error"
            return [.turnFailed(reason: reason)]
        case "Notification":
            return [.notification(type: obj["notification_type"] as? String ?? "", message: obj["message"] as? String ?? "")]
        case "SessionEnd":
            return [.sessionEnded(reason: obj["reason"] as? String ?? "other")]
        default:
            return []
        }
    }
}

// MARK: - Claude Code transcript

/// Only the two things hooks can't tell: an interrupt (Stop doesn't fire) and a declined
/// permission prompt (no hook fires for a manual deny). Everything else comes from hooks.
enum ClaudeTranscriptStatus {
    static func parse(_ line: Data) -> [OriginSignal] {
        let head = line.prefix(400)
        // Cheap checks first: most lines are assistant text or tool output.
        guard head.range(of: Data(#""type":"user""#.utf8)) != nil || line.range(of: Data(#""type":"user""#.utf8)) != nil else { return [] }
        let interrupted = line.range(of: Data("[Request interrupted by user".utf8)) != nil
        let declined = line.range(of: Data("doesn't want to proceed".utf8)) != nil || line.range(of: Data("tool use was rejected".utf8)) != nil
        guard interrupted || declined else { return [] }
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              obj["type"] as? String == "user", obj["isSidechain"] as? Bool != true,
              let msg = obj["message"] as? [String: Any] else { return [] }
        var out: [OriginSignal] = []
        if let items = msg["content"] as? [[String: Any]] {
            for item in items where item["type"] as? String == "tool_result" && item["is_error"] as? Bool == true {
                let text = ClaudeTranscriptParser.textOf(item["content"]) ?? ""
                if text.contains("doesn't want to proceed") || text.contains("tool use was rejected") {
                    out.append(OriginSignal(origin: .transcript, signal: .declined(id: item["tool_use_id"] as? String)))
                }
            }
            for item in items where item["type"] as? String == "text" {
                if (item["text"] as? String ?? "").hasPrefix("[Request interrupted by user") {
                    out.append(OriginSignal(origin: .transcript, signal: .interrupted))
                }
            }
        } else if let s = msg["content"] as? String, s.hasPrefix("[Request interrupted by user") {
            out.append(OriginSignal(origin: .transcript, signal: .interrupted))
        }
        return out
    }
}

// MARK: - Codex rollout

/// Codex writes turn boundaries (task_started, task_complete, turn_aborted) and tool calls to
/// its rollout. Approval prompts aren't written there; they arrive as OSC 9 notifications.
enum CodexRolloutStatus {
    private static let markers = ["\"task_started\"", "\"task_complete\"", "\"turn_aborted\"", "\"function_call\"",
                                  "\"custom_tool_call\"", "\"local_shell_call\"", "\"function_call_output\"",
                                  "\"custom_tool_call_output\"", "\"exec_approval_request\"", "\"apply_patch_approval_request\""]

    static func parse(_ line: Data, cwd: String?) -> [OriginSignal] {
        // The payload type sits near the start of every line. Outputs can be huge, so they
        // are recognised without parsing.
        let head = String(decoding: line.prefix(240), as: UTF8.self)
        guard markers.contains(where: { head.contains($0) }) else { return [] }
        if head.contains("\"function_call_output\"") || head.contains("\"custom_tool_call_output\"") {
            return [OriginSignal(origin: .transcript, signal: .toolFinished(id: nil))]
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let p = obj["payload"] as? [String: Any] else { return [] }
        let type = obj["type"] as? String
        let ptype = p["type"] as? String
        func turnID() -> String? { (p["turn_id"] as? String) ?? ((p["turn_attribution"] as? [String: Any])?["turn_id"] as? String) }
        var sig: StatusSignal?
        switch (type, ptype) {
        case ("event_msg", "task_started"):
            if let id = turnID() { sig = .codexTurnStarted(id: id) } else { sig = .promptSubmitted }
        case ("event_msg", "task_complete"):
            sig = .codexTurnComplete(id: turnID(), lastMessage: p["last_agent_message"] as? String)
        case ("event_msg", "turn_aborted"):
            sig = .codexTurnAborted(id: turnID(), reason: p["reason"] as? String ?? "aborted")
        case ("event_msg", "exec_approval_request"):
            let cmd = (p["command"] as? [String]).map(shellLine) ?? (p["command"] as? String)
            sig = .permissionRequested(call: ToolCall(name: "shell", command: cmd, cwd: cwd))
        case ("event_msg", "apply_patch_approval_request"):
            let files = ((p["changes"] as? [String: Any])?.keys).map { Array($0).sorted() } ?? []
            sig = .permissionRequested(call: ToolCall(name: "apply_patch", files: files, cwd: cwd))
        case ("response_item", "function_call"), ("response_item", "custom_tool_call"), ("response_item", "local_shell_call"):
            sig = .toolStarted(id: nil, call: codexCall(p, cwd: cwd))
        default:
            break
        }
        return sig.map { [OriginSignal(origin: .transcript, signal: $0)] } ?? []
    }

    static func codexCall(_ p: [String: Any], cwd: String?) -> ToolCall {
        let ptype = p["type"] as? String
        let name = p["name"] as? String ?? (ptype == "local_shell_call" ? "shell" : "tool")
        let raw = (p["arguments"] as? String) ?? (p["input"] as? String) ?? ""
        var args: [String: Any] = [:]
        if let d = raw.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { args = o }
        if let action = p["action"] as? [String: Any] { args = action }
        switch name {
        case "apply_patch":
            let patch = (args["input"] as? String) ?? raw
            let files = patch.split(whereSeparator: \.isNewline).compactMap { l -> String? in
                for pre in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where l.hasPrefix(pre) { return String(l.dropFirst(pre.count)) }
                return nil
            }
            return ToolCall(name: "apply_patch", files: files, cwd: cwd)
        case "request_user_input":
            let q = (args["question"] as? String) ?? ((args["questions"] as? [[String: Any]])?.first?["question"] as? String)
            return ToolCall(name: "request_user_input", question: q, cwd: cwd)
        default:
            var cmd: String?
            if let c = args["cmd"] as? String { cmd = c }
            else if let c = args["command"] as? [String] { cmd = shellLine(c) }
            else if let c = args["command"] as? String { cmd = c }
            else { cmd = scriptCommand(raw) }
            return ToolCall(name: cmd != nil && name == "exec" ? "exec_command" : name, command: cmd, cwd: cwd)
        }
    }

    /// Codex 0.160's `exec` tool takes a script: text(await tools.exec_command({cmd:"swift build", ...})).
    static func scriptCommand(_ raw: String) -> String? {
        guard raw.contains("cmd") else { return nil }
        let pattern = #"\bcmd\s*:\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let r = Range(m.range(at: 1), in: raw) else { return nil }
        let quoted = String(raw[r])
        if quoted.hasPrefix("\""), let data = quoted.data(using: .utf8), let s = try? JSONDecoder().decode(String.self, from: data) { return s }
        return String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "\\'", with: "'")
    }

    /// ["bash", "-lc", "swift build"] -> "swift build".
    static func shellLine(_ argv: [String]) -> String {
        if argv.count >= 3, ["bash", "zsh", "sh", "/bin/bash", "/bin/zsh", "/bin/sh"].contains(argv[0]), argv[1].hasPrefix("-") { return argv[2] }
        return argv.joined(separator: " ")
    }
}

// MARK: - Terminal notifications

/// Codex's OSC 9 notification texts (tui.notifications) and anything else an agent sends as a
/// desktop notification.
enum TerminalNoticeText {
    enum Kind: Equatable { case permission, answer, done, other }

    static func classify(_ text: String) -> (Kind, String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The terminal may put a title in front, so look for the phrase anywhere.
        func rest(after phrase: String) -> String? {
            guard let r = t.range(of: phrase) else { return nil }
            return t[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " :")).trimmingCharacters(in: .whitespaces)
        }
        if var r = rest(after: "Approval requested") {
            if r.hasPrefix("by ") { return (.permission, "Wants approval " + ToolCall.oneLine(r)) }
            r = unwrapShell(r.trimmingCharacters(in: CharacterSet(charactersIn: "`")))
            return (.permission, r.isEmpty ? "Wants approval" : "Wants to run " + ToolCall.oneLine(r))
        }
        if let r = rest(after: "Codex wants to edit") {
            return (.permission, r.isEmpty ? "Wants to edit files" : "Wants to edit " + ToolCall.oneLine(r))
        }
        if t.contains("Plan mode prompt") { return (.answer, "Plan ready for review") }
        if let r = rest(after: "Question:") { return (.answer, "Asks: " + ToolCall.oneLine(r)) }
        if t.contains("Agent turn complete") { return (.done, t) }
        let lower = t.lowercased()
        if lower.contains("permission") || lower.contains("approv") { return (.permission, ToolCall.oneLine(t)) }
        return (.other, ToolCall.oneLine(t))
    }

    /// "/bin/zsh -lc 'touch a.txt'" -> "touch a.txt" (Codex may cut the end off with "...").
    static func unwrapShell(_ s: String) -> String {
        for shell in ["/bin/zsh", "/bin/bash", "/bin/sh", "zsh", "bash", "sh"] {
            for flag in [" -lc ", " -c "] where s.hasPrefix(shell + flag) {
                var inner = String(s.dropFirst(shell.count + flag.count))
                if inner.hasPrefix("'") || inner.hasPrefix("\"") { inner.removeFirst() }
                if inner.hasSuffix("'") || inner.hasSuffix("\"") { inner.removeLast() }
                return inner
            }
        }
        return s
    }
}
