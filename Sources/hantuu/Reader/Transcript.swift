import Foundation

/// One thing the reader shows. Both agents' transcripts are normalised into these.
struct ReaderEntry: Codable, Equatable {
    enum Kind: String, Codable {
        case user        // the person's prompt, as prose
        case assistant   // the agent's answer or narration, as Markdown
        case tool        // one collapsed line per tool call
        case question    // the agent asking the person something (stands out)
        case attention   // a permission request or "waiting for you" (stands out)
        case error       // a failed tool, API error, aborted turn (stands out)
        case notice      // small system line: /command, interrupted, compacted
        case plan        // a proposed plan, shown in full
    }

    var id: String
    var kind: Kind
    var text: String
    var detail: String? = nil
    var tool: String? = nil
    /// Inline images: data: URLs from the transcript, or absolute file paths.
    var images: [String] = []
    /// Files the entry refers to directly (a tool's file_path), shown inline if image/PDF.
    var files: [String] = []
    var time: String? = nil
    /// Paths found in the text that exist on disk, filled in by PathDetector.
    var links: [DetectedPath] = []
}

protocol TranscriptParser {
    /// Parse one JSONL line. May return several entries or none (noise is hidden).
    mutating func parse(line: Data) -> [ReaderEntry]
}

// MARK: - Claude Code

/// Claude Code writes ~/.claude/projects/<cwd with non-alphanumerics as '-'>/<session>.jsonl.
/// Each line is an object with a `type`: user, assistant, system, attachment, plus
/// bookkeeping lines (summary, custom-title, file-history-snapshot, ...) that are hidden.
struct ClaudeTranscriptParser: TranscriptParser {
    private var lineNo = 0
    private var toolNames: [String: String] = [:]   // tool_use id -> name

    private static let noisePrefixes = [
        "<system-reminder>", "<task-notification>", "<local-command-stdout>", "<local-command-stderr>",
        "<local-command-caveat>", "Caveat:", "<user-prompt-submit-hook>", "<bash-stdout>", "<bash-stderr>",
    ]

    mutating func parse(line: Data) -> [ReaderEntry] {
        lineNo += 1
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String else { return [] }
        let uuid = (obj["uuid"] as? String) ?? "c\(lineNo)"
        let time = obj["timestamp"] as? String
        if obj["isSidechain"] as? Bool == true { return [] }

        switch type {
        case "user":
            if obj["isMeta"] as? Bool == true { return [] }
            if obj["isCompactSummary"] as? Bool == true {
                return [ReaderEntry(id: uuid, kind: .notice, text: "Conversation compacted", time: time)]
            }
            guard let msg = obj["message"] as? [String: Any] else { return [] }
            return parseUser(msg["content"], id: uuid, time: time)

        case "assistant":
            guard let msg = obj["message"] as? [String: Any] else { return [] }
            if obj["isApiErrorMessage"] as? Bool == true {
                let text = Self.textOf(msg["content"]) ?? "API error"
                return [ReaderEntry(id: uuid, kind: .error, text: text, time: time)]
            }
            return parseAssistant(msg["content"], id: uuid, time: time)

        case "system":
            let level = obj["level"] as? String
            let subtype = obj["subtype"] as? String
            if subtype == "api_error" || level == "error" {
                let content = (obj["content"] as? String) ?? Self.apiErrorText(obj) ?? "API error"
                return [ReaderEntry(id: uuid, kind: .error, text: content, time: time)]
            }
            return []

        default:
            return []
        }
    }

    private static func apiErrorText(_ obj: [String: Any]) -> String? {
        if let e = obj["error"] as? [String: Any] {
            if let m = e["message"] as? String { return m }
            if let inner = e["error"] as? [String: Any], let m = inner["message"] as? String { return m }
        }
        return nil
    }

    private mutating func parseUser(_ content: Any?, id: String, time: String?) -> [ReaderEntry] {
        if let s = content as? String {
            return userText(s, images: [], id: id, time: time)
        }
        guard let items = content as? [[String: Any]] else { return [] }
        var out: [ReaderEntry] = []
        var texts: [String] = []
        var images: [String] = []
        for (i, item) in items.enumerated() {
            switch item["type"] as? String {
            case "text":
                if let t = item["text"] as? String { texts.append(t) }
            case "image":
                if let src = Self.imageSource(item) { images.append(src) }
            case "tool_result":
                out += toolResult(item, id: "\(id)-r\(i)", time: time)
            default:
                break
            }
        }
        if !texts.isEmpty || !images.isEmpty {
            out = userText(texts.joined(separator: "\n\n"), images: images, id: id, time: time) + out
        }
        return out
    }

    private func userText(_ raw: String, images: [String], id: String, time: String?) -> [ReaderEntry] {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<command-name>") {
            let name = Self.between(s, "<command-name>", "</command-name>") ?? "command"
            let args = Self.between(s, "<command-args>", "</command-args>") ?? ""
            return [ReaderEntry(id: id, kind: .notice, text: "Ran \(name) \(args)".trimmingCharacters(in: .whitespaces), time: time)]
        }
        if s.hasPrefix("[Request interrupted by user") {
            return [ReaderEntry(id: id, kind: .notice, text: "Interrupted", time: time)]
        }
        if Self.noisePrefixes.contains(where: { s.hasPrefix($0) }) { return [] }
        if s.isEmpty && images.isEmpty { return [] }
        // Pasted images show as "[Image #1]" placeholders in the prompt text; the image
        // itself arrives as an image block and is shown below the prose.
        return [ReaderEntry(id: id, kind: .user, text: s, images: images, time: time)]
    }

    private mutating func toolResult(_ item: [String: Any], id: String, time: String?) -> [ReaderEntry] {
        let toolID = item["tool_use_id"] as? String ?? ""
        let name = toolNames[toolID] ?? "Tool"
        var text = ""
        var images: [String] = []
        if let s = item["content"] as? String {
            text = s
        } else if let arr = item["content"] as? [[String: Any]] {
            for c in arr {
                if c["type"] as? String == "text", let t = c["text"] as? String { text += t }
                if c["type"] as? String == "image", let src = Self.imageSource(c) { images.append(src) }
            }
        }
        var out: [ReaderEntry] = []
        if item["is_error"] as? Bool == true {
            if text.contains("doesn't want to proceed") || text.contains("user rejected") || text.contains("was rejected") {
                out.append(ReaderEntry(id: id, kind: .attention, text: "You declined \(name)", tool: name, time: time))
            } else {
                let first = text.split(whereSeparator: \.isNewline).prefix(6).joined(separator: "\n")
                out.append(ReaderEntry(id: id, kind: .error, text: "\(name) failed", detail: String(first.prefix(800)), tool: name, time: time))
            }
        }
        if !images.isEmpty {
            out.append(ReaderEntry(id: id + "-img", kind: .tool, text: "\(name) returned an image", tool: name, images: images, time: time))
        }
        return out
    }

    private mutating func parseAssistant(_ content: Any?, id: String, time: String?) -> [ReaderEntry] {
        guard let items = content as? [[String: Any]] else {
            if let s = content as? String, !s.isEmpty { return [ReaderEntry(id: id, kind: .assistant, text: s, time: time)] }
            return []
        }
        var out: [ReaderEntry] = []
        for (i, item) in items.enumerated() {
            let eid = "\(id)-\(i)"
            switch item["type"] as? String {
            case "text":
                if let t = item["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(ReaderEntry(id: eid, kind: .assistant, text: t, time: time))
                }
            case "tool_use":
                let name = item["name"] as? String ?? "Tool"
                if let tid = item["id"] as? String { toolNames[tid] = name }
                let input = item["input"] as? [String: Any] ?? [:]
                out.append(Self.toolEntry(name: name, input: input, id: eid, time: time))
            default:
                break // thinking, redacted_thinking: hidden
            }
        }
        return out
    }

    static func toolEntry(name: String, input: [String: Any], id: String, time: String?) -> ReaderEntry {
        func s(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch name {
        case "Bash":
            let cmd = s("command") ?? ""
            return ReaderEntry(id: id, kind: .tool, text: s("description") ?? "Ran a command", detail: cmd, tool: name, time: time)
        case "Read":
            let p = s("file_path") ?? ""
            return ReaderEntry(id: id, kind: .tool, text: "Read \(p)", tool: name, files: p.isEmpty ? [] : [p], time: time)
        case "Edit", "MultiEdit":
            let p = s("file_path") ?? ""
            return ReaderEntry(id: id, kind: .tool, text: "Edited \(p)", tool: name, files: p.isEmpty ? [] : [p], time: time)
        case "Write":
            let p = s("file_path") ?? ""
            return ReaderEntry(id: id, kind: .tool, text: "Wrote \(p)", tool: name, files: p.isEmpty ? [] : [p], time: time)
        case "NotebookEdit":
            let p = s("notebook_path") ?? ""
            return ReaderEntry(id: id, kind: .tool, text: "Edited \(p)", tool: name, time: time)
        case "Grep":
            let where_ = s("path").map { " in \($0)" } ?? ""
            return ReaderEntry(id: id, kind: .tool, text: "Searched for “\(s("pattern") ?? "")”\(where_)", tool: name, time: time)
        case "Glob":
            return ReaderEntry(id: id, kind: .tool, text: "Listed files matching \(s("pattern") ?? "")", tool: name, time: time)
        case "WebFetch":
            return ReaderEntry(id: id, kind: .tool, text: "Fetched \(s("url") ?? "a page")", tool: name, time: time)
        case "WebSearch":
            return ReaderEntry(id: id, kind: .tool, text: "Searched the web for “\(s("query") ?? "")”", tool: name, time: time)
        case "Task", "Agent":
            return ReaderEntry(id: id, kind: .tool, text: "Started an agent: \(s("description") ?? "subtask")", tool: name, time: time)
        case "TodoWrite":
            return ReaderEntry(id: id, kind: .tool, text: "Updated the to-do list", tool: name, time: time)
        case "ExitPlanMode":
            return ReaderEntry(id: id, kind: .plan, text: s("plan") ?? "Proposed a plan", tool: name, time: time)
        case "AskUserQuestion":
            return ReaderEntry(id: id, kind: .question, text: questionsText(input), tool: name, time: time)
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_", omittingEmptySubsequences: true)
                let server = parts.count > 1 ? String(parts[1]) : "MCP"
                let tool = parts.count > 2 ? parts[2...].joined(separator: "_") : name
                return ReaderEntry(id: id, kind: .tool, text: "Used \(server): \(tool)", tool: name, time: time)
            }
            return ReaderEntry(id: id, kind: .tool, text: "Used \(name)", tool: name, time: time)
        }
    }

    private static func questionsText(_ input: [String: Any]) -> String {
        guard let qs = input["questions"] as? [[String: Any]] else {
            return (input["question"] as? String) ?? "The agent has a question for you"
        }
        return qs.map { q in
            var lines = ["**\(q["question"] as? String ?? "")**"]
            for o in (q["options"] as? [[String: Any]]) ?? [] {
                let label = o["label"] as? String ?? ""
                let desc = (o["description"] as? String).map { " - \($0)" } ?? ""
                lines.append("- \(label)\(desc)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func imageSource(_ item: [String: Any]) -> String? {
        guard let src = item["source"] as? [String: Any] else { return nil }
        if src["type"] as? String == "base64", let data = src["data"] as? String {
            let mt = src["media_type"] as? String ?? "image/png"
            return "data:\(mt);base64,\(data)"
        }
        if let url = src["url"] as? String { return url }
        return nil
    }

    static func textOf(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return nil
    }

    static func between(_ s: String, _ a: String, _ b: String) -> String? {
        guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
        return String(s[r1.upperBound..<r2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Claude Code's folder name for a working directory: every UTF-16 unit that isn't an
    /// ASCII letter or digit becomes '-' (so an emoji becomes two dashes).
    static func projectFolderName(for cwd: String) -> String {
        String(cwd.utf16.map { u -> Character in
            if (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122) { return Character(UnicodeScalar(u)!) }
            return "-"
        })
    }

    /// Finds <root>/*/<sessionID>.jsonl, trying the expected folder first.
    static func locate(sessionID: String, cwd: String, root: URL = Paths.claudeProjects) -> URL? {
        let fm = FileManager.default
        let expected = root.appendingPathComponent(projectFolderName(for: cwd)).appendingPathComponent("\(sessionID).jsonl")
        if fm.fileExists(atPath: expected.path) { return expected }
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        for d in dirs {
            let f = d.appendingPathComponent("\(sessionID).jsonl")
            if fm.fileExists(atPath: f.path) { return f }
        }
        return nil
    }
}

// MARK: - Codex

/// Codex writes ~/.codex/sessions/YYYY/MM/DD/rollout-<local time>-<id>.jsonl. Lines are
/// {timestamp, type, payload}. `response_item` carries the conversation (message, reasoning,
/// function_call, custom_tool_call, ...); `event_msg` duplicates some of it and adds errors.
struct CodexTranscriptParser: TranscriptParser {
    private var lineNo = 0

    mutating func parse(line: Data) -> [ReaderEntry] {
        lineNo += 1
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String,
              let p = obj["payload"] as? [String: Any] else { return [] }
        let time = obj["timestamp"] as? String
        let id = (p["id"] as? String).map { "x\(lineNo)-\($0)" } ?? "x\(lineNo)"
        let ptype = p["type"] as? String

        switch (type, ptype) {
        case ("response_item", "message"):
            let role = p["role"] as? String
            let content = p["content"] as? [[String: Any]] ?? []
            var texts: [String] = []
            var images: [String] = []
            for c in content {
                switch c["type"] as? String {
                case "input_text", "output_text", "text":
                    if let t = c["text"] as? String { texts.append(t) }
                case "input_image":
                    if let u = c["image_url"] as? String { images.append(u) }
                default: break
                }
            }
            if role == "user" {
                let kept = texts.filter { !Self.isContextBlock($0) }
                if kept.isEmpty && images.isEmpty { return [] }
                return [ReaderEntry(id: id, kind: .user, text: kept.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines), images: images, time: time)]
            }
            if role == "assistant" {
                return Self.answerEntries(texts.joined(separator: "\n\n"), id: id, time: time)
            }
            return [] // developer / system

        case ("response_item", "function_call"), ("response_item", "custom_tool_call"), ("response_item", "local_shell_call"):
            let name = p["name"] as? String ?? (ptype == "local_shell_call" ? "shell" : "tool")
            let rawInput = (p["arguments"] as? String) ?? (p["input"] as? String) ?? ""
            var args: [String: Any] = [:]
            if let d = rawInput.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { args = o }
            if let action = p["action"] as? [String: Any] { args = action }
            return [Self.toolEntry(name: name, args: args, raw: rawInput, id: id, time: time)]

        case ("response_item", "web_search_call"):
            let q = ((p["action"] as? [String: Any])?["query"] as? String).map { " for “\($0)”" } ?? ""
            return [ReaderEntry(id: id, kind: .tool, text: "Searched the web\(q)", tool: "web_search", time: time)]

        case ("event_msg", "error"), ("event_msg", "stream_error"):
            let m = p["message"] as? String ?? "Error"
            return [ReaderEntry(id: id, kind: .error, text: m, time: time)]

        case ("event_msg", "turn_aborted"):
            let reason = p["reason"] as? String ?? "aborted"
            return [ReaderEntry(id: id, kind: reason == "interrupted" ? .notice : .error, text: "Turn \(reason)", time: time)]

        case ("event_msg", "task_complete"):
            if let e = p["error"] as? [String: Any], let m = e["message"] as? String {
                return [ReaderEntry(id: id, kind: .error, text: m, time: time)]
            }
            return []

        case ("event_msg", "exec_approval_request"), ("event_msg", "apply_patch_approval_request"):
            let what = (p["command"] as? [String])?.joined(separator: " ") ?? "a change"
            return [ReaderEntry(id: id, kind: .attention, text: "Codex is asking to run \(what)", time: time)]

        default:
            return []
        }
    }

    /// Codex puts tags meant for its own UI into an answer, and its TUI parses them out.
    /// When it used a memory file it appends an `<oai-mem-citation>` block as the very last
    /// thing in the reply: dropped here. In plan mode the plan comes inside `<proposed_plan>`:
    /// shown as the reader's plan card, with any prose around it kept in order.
    static func answerEntries(_ raw: String, id: String, time: String?) -> [ReaderEntry] {
        var s = raw
        while let open = s.range(of: "<oai-mem-citation>") {
            let end = s.range(of: "</oai-mem-citation>", range: open.upperBound..<s.endIndex)?.upperBound ?? s.endIndex
            s.removeSubrange(open.lowerBound..<end)
        }
        var out: [ReaderEntry] = []
        func prose(_ t: Substring) {
            let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(ReaderEntry(id: out.isEmpty ? id : "\(id)-\(out.count)", kind: .assistant, text: t, time: time)) }
        }
        var rest = s[...]
        while let open = rest.range(of: "<proposed_plan>") {
            prose(rest[..<open.lowerBound])
            let close = rest.range(of: "</proposed_plan>", range: open.upperBound..<rest.endIndex)
            let plan = rest[open.upperBound..<(close?.lowerBound ?? rest.endIndex)].trimmingCharacters(in: .whitespacesAndNewlines)
            if !plan.isEmpty { out.append(ReaderEntry(id: out.isEmpty ? id : "\(id)-\(out.count)", kind: .plan, text: plan, time: time)) }
            rest = rest[(close?.upperBound ?? rest.endIndex)...]
        }
        prose(rest)
        return out
    }

    /// Codex injects its context (AGENTS.md, environment, permissions) as user messages.
    static func isContextBlock(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("# AGENTS.md instructions") { return true }
        // Codex wraps each attached image in <image name=[Image #1] path="..."> and </image>.
        if s == "</image>" || s.range(of: #"^<image\b[^>]*>$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^<([a-z_ \-]+)>[\s\S]*</\1>$"#, options: .regularExpression) != nil { return true }
        for tag in ["<environment_context>", "<user_instructions>", "<permissions", "<collaboration_mode>", "<skills_instructions>", "<turn_aborted>"] where s.hasPrefix(tag) {
            return true
        }
        return false
    }

    static func toolEntry(name: String, args: [String: Any], raw: String, id: String, time: String?) -> ReaderEntry {
        func command() -> String? {
            if let c = args["cmd"] as? String { return c }
            if let c = args["command"] as? [String] {
                if c.count >= 3, ["bash", "zsh", "sh", "/bin/bash", "/bin/zsh", "/bin/sh"].contains(c[0]), c[1].hasPrefix("-") { return c[2] }
                return c.joined(separator: " ")
            }
            if let c = args["command"] as? String { return c }
            return nil
        }
        switch name {
        case "exec", "shell", "exec_command", "local_shell", "container.exec", "shell_command":
            let cmd = command() ?? raw
            return ReaderEntry(id: id, kind: .tool, text: "Ran a command", detail: String(cmd.prefix(600)), tool: name, time: time)
        case "apply_patch":
            let patch = (args["input"] as? String) ?? raw
            let files = patch.split(whereSeparator: \.isNewline).compactMap { l -> String? in
                for p in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where l.hasPrefix(p) {
                    return String(l.dropFirst(p.count))
                }
                return nil
            }
            let label = files.isEmpty ? "Edited files" : "Edited " + files.joined(separator: ", ")
            return ReaderEntry(id: id, kind: .tool, text: label, tool: name, files: files, time: time)
        case "view_image":
            let p = args["path"] as? String ?? ""
            return ReaderEntry(id: id, kind: .tool, text: "Viewed \(p)", tool: name, files: p.isEmpty ? [] : [p], time: time)
        case "update_plan":
            return ReaderEntry(id: id, kind: .tool, text: "Updated the plan", tool: name, time: time)
        case "request_user_input":
            let q = (args["question"] as? String) ?? raw
            return ReaderEntry(id: id, kind: .question, text: q, tool: name, time: time)
        default:
            return ReaderEntry(id: id, kind: .tool, text: "Used \(name)", tool: name, time: time)
        }
    }

    struct SessionMeta {
        let id: String
        let cwd: String
        let start: Date?
    }

    static func readMeta(_ url: URL) -> SessionMeta? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let chunk = (try? h.read(upToCount: 256 * 1024)) ?? Data()
        guard let nl = chunk.firstIndex(of: 0x0A) ?? (chunk.isEmpty ? nil : chunk.endIndex) else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: chunk[..<nl])) as? [String: Any],
              obj["type"] as? String == "session_meta",
              let p = obj["payload"] as? [String: Any],
              let id = p["id"] as? String, let cwd = p["cwd"] as? String else { return nil }
        let start = (p["timestamp"] as? String).flatMap(Self.parseDate)
        return SessionMeta(id: id, cwd: cwd, start: start)
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// The newest rollout started after `after` whose cwd matches, skipping claimed files.
    static func locate(cwd: String, after: Date, excluding: Set<String>, root: URL = Paths.codexSessions) -> (URL, SessionMeta)? {
        let fm = FileManager.default
        let cal = Calendar.current
        var dayDirs: [URL] = []
        for offset in [0, -1] {
            guard let day = cal.date(byAdding: .day, value: offset, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            dayDirs.append(root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!)))
        }
        let want = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path
        var best: (URL, SessionMeta, Date)?
        for dir in dayDirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" && f.lastPathComponent.hasPrefix("rollout-") && !excluding.contains(f.path) {
                guard let meta = readMeta(f) else { continue }
                let have = URL(fileURLWithPath: meta.cwd).standardizedFileURL.resolvingSymlinksInPath().path
                guard have == want else { continue }
                let started = meta.start ?? ((try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                guard started >= after.addingTimeInterval(-5) else { continue }
                if best == nil || started < best!.2 { best = (f, meta, started) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }
}

// MARK: - Following a transcript file

/// Tails a JSONL file: reads only new complete lines on each poll, never rewrites the file.
final class TranscriptFollower {
    let url: URL
    private var parser: TranscriptParser
    private var offset: UInt64 = 0
    private var partial = Data()
    private(set) var entries: [ReaderEntry] = []
    private var timer: Timer?
    private let baseDir: String?
    var onAppend: (([ReaderEntry]) -> Void)?

    init(url: URL, kind: TranscriptKind, baseDir: String?) {
        self.url = url
        self.baseDir = baseDir
        switch kind {
        case .claude: parser = ClaudeTranscriptParser()
        case .codex: parser = CodexTranscriptParser()
        }
    }

    func start(interval: TimeInterval = 0.5) {
        poll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Reads whatever was appended since the last call. Returns the new entries.
    @discardableResult
    func poll() -> [ReaderEntry] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return [] }
        if size < offset {
            // File was replaced or truncated: start over.
            offset = 0
            partial = Data()
            entries = []
        }
        guard size > offset, let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        do { try h.seek(toOffset: offset) } catch { return [] }
        let data = (try? h.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        var buf = partial + data
        var fresh: [ReaderEntry] = []
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf[buf.startIndex..<nl]
            buf = Data(buf[buf.index(after: nl)...])
            if line.isEmpty { continue }
            fresh += parser.parse(line: Data(line))
        }
        partial = buf
        if fresh.isEmpty { return [] }
        for i in fresh.indices {
            fresh[i].links = PathDetector.detect(in: fresh[i].text + "\n" + (fresh[i].detail ?? ""), base: baseDir)
            for f in fresh[i].files {
                if let d = PathDetector.resolve(f, base: baseDir), !fresh[i].links.contains(where: { $0.path == d.path }) {
                    fresh[i].links.append(DetectedPath(match: f, path: d.path, line: nil, kind: d.kind))
                }
            }
        }
        entries += fresh
        onAppend?(fresh)
        return fresh
    }
}
