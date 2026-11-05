import Foundation

/// What a chat's agent is doing, as the sidebar shows it. `Chat.status` still says whether
/// the process is alive; this says whether it needs you.
enum AgentActivity: String, Codable, CaseIterable {
    case working           // running a turn
    case needsPermission   // wants approval to run a tool
    case needsAnswer       // asking you something (AskUserQuestion, a plan, a final question)
    case doneUnseen        // finished a turn while you weren't looking at the chat
    case idle              // its prompt is waiting and you've seen it
    case ended             // the process exited

    /// Permission or a question: these stay until the agent resumes, not when you look.
    var isNeeds: Bool { self == .needsPermission || self == .needsAnswer }

    /// Counts toward "need you", the Dock badge and Cmd-J.
    var wantsAttention: Bool { isNeeds || self == .doneUnseen }

    var label: String {
        switch self {
        case .working: return "Working"
        case .needsPermission: return "Needs permission"
        case .needsAnswer: return "Needs answer"
        case .doneUnseen: return "Done"
        case .idle: return "Idle"
        case .ended: return "Ended"
        }
    }
}

/// One tool call as the status line describes it. Built from a hook's `tool_name` and
/// `tool_input`, or from a Codex rollout's function call.
struct ToolCall: Equatable {
    var name: String
    /// The input in canonical JSON, used to match a PermissionRequest to its PreToolUse.
    var inputKey: String = ""
    var command: String?
    var filePath: String?
    var url: String?
    var query: String?
    var pattern: String?
    var label: String?        // a description, an agent task, a plan
    var question: String?
    var agentID: String?

    init(name: String, input: [String: Any], cwd: String?, agentID: String? = nil) {
        self.name = name
        self.agentID = agentID
        if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) {
            inputKey = String(decoding: data, as: UTF8.self)
        }
        func s(_ k: String) -> String? {
            guard let v = input[k] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        command = s("command")
        filePath = (s("file_path") ?? s("notebook_path") ?? s("path")).map { ToolCall.shorten($0, cwd: cwd) }
        url = s("url")
        query = s("query")
        pattern = s("pattern")
        label = s("description") ?? s("prompt").map { String($0.prefix(80)) }
        if let qs = input["questions"] as? [[String: Any]], let first = qs.first?["question"] as? String {
            question = first.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            question = s("question")
        }
    }

    /// A Codex call, where the command or files are already worked out.
    init(name: String, command: String? = nil, files: [String] = [], question: String? = nil, cwd: String?) {
        self.name = name
        self.command = command
        self.question = question
        if !files.isEmpty { filePath = files.map { ToolCall.shorten($0, cwd: cwd) }.joined(separator: ", ") }
        inputKey = [command ?? "", files.joined(separator: ","), question ?? ""].joined(separator: "|")
    }

    var isQuestion: Bool { name == "AskUserQuestion" || name == "request_user_input" }
    var isPlan: Bool { name == "ExitPlanMode" }

    /// "Running Bash: swift build", "Editing README.md".
    var workingText: String { phrase(wants: false) }
    /// "Wants to run Bash: npm test", "Wants to edit Sources/App.swift".
    var wantsText: String { phrase(wants: true) }
    /// "Asks: Which database should I use?", "Plan ready for review".
    var askText: String {
        if isPlan { return "Plan ready for review" }
        return "Asks: " + (question.map(ToolCall.oneLine) ?? "a question")
    }

    private func phrase(wants: Bool) -> String {
        let cmd = command.map(ToolCall.oneLine)
        let file = filePath ?? ""
        func v(_ running: String, _ want: String) -> String { wants ? "Wants to \(want)" : running }
        switch name {
        case "Bash", "PowerShell":
            return v("Running \(name)", "run \(name)") + (cmd.map { ": \($0)" } ?? "")
        case "shell", "exec", "exec_command", "local_shell", "container.exec", "shell_command", "unified_exec":
            return v("Running", "run") + (cmd.map { " \($0)" } ?? " a command")
        case "Edit", "MultiEdit", "NotebookEdit", "apply_patch":
            return v("Editing", "edit") + (file.isEmpty ? " files" : " \(file)")
        case "Write":
            return v("Writing", "write") + (file.isEmpty ? " a file" : " \(file)")
        case "Read", "view_image":
            return v("Reading", "read") + (file.isEmpty ? " a file" : " \(file)")
        case "Grep":
            return v("Searching for", "search for") + " \(pattern ?? "text")"
        case "Glob":
            return v("Listing", "list") + " \(pattern ?? "files")"
        case "WebFetch":
            return v("Fetching", "fetch") + " \(url.map(ToolCall.host) ?? "a page")"
        case "WebSearch", "web_search":
            return v("Searching the web for", "search the web for") + " \(query ?? "something")"
        case "Agent", "Task":
            return v("Running an agent", "start an agent") + (label.map { ": \($0)" } ?? "")
        case "TodoWrite", "TaskCreate", "TaskUpdate", "update_plan":
            return v("Updating the plan", "update the plan")
        case "AskUserQuestion", "request_user_input", "ExitPlanMode":
            return askText
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_", omittingEmptySubsequences: true)
                let server = parts.count > 1 ? String(parts[1]) : "MCP"
                let tool = parts.count > 2 ? parts[2...].joined(separator: "_") : name
                return v("Using", "use") + " \(server): \(tool)"
            }
            return v("Using", "use") + " \(name)"
        }
    }

    /// First line, whitespace collapsed, capped so a pasted script doesn't flood the line.
    static func oneLine(_ s: String) -> String {
        let first = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        let collapsed = first.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        return collapsed.count > 160 ? String(collapsed.prefix(159)) + "…" : collapsed
    }

    /// A path inside the working folder is shown relative to it.
    static func shorten(_ path: String, cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return path }
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        if path.hasPrefix(base) { return String(path.dropFirst(base.count)) }
        return path
    }

    static func host(_ url: String) -> String {
        if let h = URL(string: url)?.host, !h.isEmpty { return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h }
        return url
    }
}

enum StatusText {
    /// "Done just now", "Done 2m ago", "Done 3h ago".
    static func done(at date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "Done just now" }
        if s < 3600 { return "Done \(Int(s / 60))m ago" }
        if s < 86400 { return "Done \(Int(s / 3600))h ago" }
        return "Done \(Int(s / 86400))d ago"
    }

    /// The question at the end of a final message, if it ends on one.
    /// "…Should I run the migration now?" -> "Should I run the migration now?"
    static func finalQuestion(_ message: String?) -> String? {
        guard let message else { return nil }
        let lines = message.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
        guard var last = lines.last else { return nil }
        last = plain(last)
        guard last.hasSuffix("?") else { return nil }
        // Keep only the last sentence of that line.
        let body = last.dropLast()
        if let cut = body.lastIndex(where: { ".!?:".contains($0) }) {
            let tail = body[body.index(after: cut)...].trimmingCharacters(in: .whitespaces)
            if tail.count >= 8 { return tail + "?" }
        }
        return last
    }

    /// The last line of a final message, for a notification body.
    static func lastLine(_ message: String?) -> String? {
        guard let message else { return nil }
        let lines = message.split(whereSeparator: \.isNewline)
            .map { plain($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") && $0 != "---" }
        guard let last = lines.last else { return nil }
        return last.count > 200 ? String(last.prefix(199)) + "…" : last
    }

    /// Strips the Markdown that would look odd in one line of plain text.
    static func plain(_ s: String) -> String {
        var t = s
        for p in ["#", ">", "- ", "* "] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces) }
        t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
        return t.trimmingCharacters(in: .whitespaces)
    }
}
