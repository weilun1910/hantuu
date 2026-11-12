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
        case reasoning, checklist
        case plan        // a proposed plan, shown in full
    }

    var id: String
    var kind: Kind
    var text: String
    var detail: String? = nil
    /// A titled detail starts collapsed; untitled details retain their existing presentation.
    var detailTitle: String? = nil
    var tool: String? = nil
    /// Inline images: data: URLs from the transcript, or absolute file paths.
    var images: [String] = []
    /// Files the entry refers to directly (a tool's file_path), shown inline if image/PDF.
    var files: [String] = []
    var time: String? = nil
    /// Paths found in the text that exist on disk, filled in by PathDetector.
    var links: [DetectedPath] = []
    /// Transient reader state. These fields are never written to an agent transcript.
    var pending: Bool? = nil
    var pendingState: String? = nil
    var pendingDetail: String? = nil
    var pendingActions: [String]? = nil
    var replacesPendingID: String? = nil
    var replacesPendingIDs: [String]? = nil
    var deliveryRequested: Bool? = nil
    var sendNowLabel: String? = nil
    /// A delegated task or followup comes from another agent, not the person at the keyboard.
    var author: String? = nil
    /// The provider recorded an opaque payload instead of readable message content.
    var contentUnavailable: String? = nil
    var operation: ReaderOperation? = nil
    var checklist: ReaderChecklist? = nil
}

/// Only a subagent's own file includes sidechain lines. Every scope keeps tool outcomes.
enum TranscriptScope: Equatable { case chat, subagent, side }

protocol TranscriptParser {
    /// Parse one JSONL line. May return several entries or none (noise is hidden).
    mutating func parse(line: Data) -> [ReaderEntry]
}

// MARK: - Claude Code

/// Claude Code writes ~/.claude/projects/<cwd with non-alphanumerics as '-'>/<session>.jsonl.
/// Each line is an object with a `type`: user, assistant, system, attachment, plus
/// bookkeeping lines (summary, custom-title, file-history-snapshot, ...) that are hidden.
struct ClaudeTranscriptParser: TranscriptParser {
    private let scope: TranscriptScope
    init(scope: TranscriptScope = .chat) { self.scope = scope }
    private var lineNo = 0
    private var compactBoundarySeen = false
    private var queuedSourceIDs = Set<String>()
    private var userMessageIDs = Set<String>()
    private var toolNames: [String: String] = [:]   // tool_use id -> name
    private struct CommandImages {
        var entry: ReaderEntry
        var promptID: String
        var sessionID: String
        var parentID: String
        var expectedCount: Int
    }
    private var commandImages: CommandImages?

    private static let noisePrefixes = [
        "<system-reminder>", "<task-notification>", "<local-command-stdout>", "<local-command-stderr>",
        "<local-command-caveat>", "Caveat:", "<user-prompt-submit-hook>", "<bash-stdout>", "<bash-stderr>",
    ]

    private var evidence = ReaderEvidence(kind: .claude)

    mutating func parse(line: Data) -> [ReaderEntry] {
        let entries = parseContent(line: line)
        // A rejected companion is not a conversation boundary. Passing it to the
        // evidence reducer would adopt its foreign session and emit a notice even
        // though commandImageCompanion rejected its prompt/session/parent ownership.
        if entries.isEmpty,
           let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
           object["type"] as? String == "user", object["isMeta"] as? Bool == true,
           object["turnCompanion"] as? Bool == true { return [] }
        return evidence.consume(line, entries: entries, includeSidechain: scope != .chat)
    }

    private mutating func parseContent(line: Data) -> [ReaderEntry] {
        lineNo += 1
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String else { return [] }
        let uuid = (obj["uuid"] as? String) ?? "c\(lineNo)"
        let time = obj["timestamp"] as? String
        if scope == .chat, obj["isSidechain"] as? Bool == true { return [] }

        switch type {
        case "user":
            if queuedSourceIDs.contains(uuid) { return [] }
            userMessageIDs.insert(uuid)
            if obj["isCompactSummary"] as? Bool == true {
                commandImages = nil
                if compactBoundarySeen { compactBoundarySeen = false; return [] }
                return [ReaderEntry(id: uuid, kind: .notice, text: "Conversation compacted", time: time)]
            }
            if obj["isMeta"] as? Bool == true { return commandImageCompanion(obj, id: uuid) }
            guard let msg = obj["message"] as? [String: Any] else { return [] }
            let entries = parseUser(msg["content"], id: uuid, time: time)
            rememberCommandImages(obj, entries: entries, id: uuid)
            return entries

        case "attachment":
            return parseQueuedCommand(obj, id: uuid, time: time)

        case "assistant":
            commandImages = nil
            guard let msg = obj["message"] as? [String: Any] else { return [] }
            if obj["isApiErrorMessage"] as? Bool == true {
                let text = Self.textOf(msg["content"]) ?? "API error"
                return [ReaderEntry(id: uuid, kind: .error, text: text, time: time)]
            }
            return parseAssistant(msg["content"], id: uuid, time: time)

        case "system":
            let level = obj["level"] as? String
            let subtype = obj["subtype"] as? String
            if subtype == "compact_boundary" {
                commandImages = nil
                compactBoundarySeen = true
                return [ReaderEntry(id: uuid, kind: .notice, text: "Conversation compacted", time: time)]
            }
            if subtype == "api_error" || level == "error" {
                let content = (obj["content"] as? String) ?? Self.apiErrorText(obj) ?? "API error"
                return [ReaderEntry(id: uuid, kind: .error, text: content, time: time)]
            }
            return []

        default:
            return []
        }
    }

    /// Claude 2.1.322 can omit /plan's actual image block and instead append a
    /// turnCompanion source reference after local-command-stdout. Upgrade the original
    /// command entry by identity, never create a second human prompt or infer a base64
    /// image. Parent, prompt and session ownership must all match the observed chain.
    private mutating func rememberCommandImages(_ object: [String: Any], entries: [ReaderEntry], id: String) {
        let content = (object["message"] as? [String: Any])?["content"] as? String ?? ""
        if var context = commandImages, content.hasPrefix("<local-command-stdout>"),
           object["parentUuid"] as? String == context.parentID,
           object["promptId"] as? String == context.promptID, object["sessionId"] as? String == context.sessionID {
            context.parentID = id
            commandImages = context
            return
        }
        commandImages = nil
        guard content.hasPrefix("<command-name>"), let entry = entries.first,
              entry.kind == .notice, entry.text.hasPrefix("Ran /"),
              let prompt = object["promptId"] as? String, !prompt.isEmpty,
              let session = object["sessionId"] as? String, !session.isEmpty else { return }
        let command = String(entry.text.dropFirst(4))
        let pattern = #"\[Image #\d+\]"#
        let count = (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(
            in: command, range: NSRange(location: 0, length: (command as NSString).length)
        ) ?? 0
        guard count > 0 else { return }
        var user = entry
        user.kind = .user
        user.text = command
        user.author = scope == .subagent ? "Parent" : nil
        commandImages = CommandImages(entry: user, promptID: prompt, sessionID: session, parentID: id, expectedCount: count)
    }

    private mutating func commandImageCompanion(_ object: [String: Any], id: String) -> [ReaderEntry] {
        guard var context = commandImages else { return [] }
        commandImages = nil
        guard object["turnCompanion"] as? Bool == true,
              object["promptId"] as? String == context.promptID, object["sessionId"] as? String == context.sessionID,
              object["parentUuid"] as? String == context.parentID,
              let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]], !blocks.isEmpty else { return [] }
        let prefix = "[Image: source: "
        var paths: [String] = []
        for block in blocks {
            guard block["type"] as? String == "text", let text = block["text"] as? String,
                  text.hasPrefix(prefix), text.hasSuffix("]") else { return [] }
            let path = String(text.dropFirst(prefix.count).dropLast())
            guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return [] }
            paths.append(path)
        }
        context.entry.images += paths
        guard context.entry.images.count <= context.expectedCount else { return [] }
        context.parentID = id
        commandImages = context
        return context.entry.images.count == context.expectedCount ? [context.entry] : []
    }

    private mutating func parseQueuedCommand(_ obj: [String: Any], id: String, time: String?) -> [ReaderEntry] {
        guard let attachment = obj["attachment"] as? [String: Any],
              attachment["type"] as? String == "queued_command",
              let origin = attachment["origin"] as? [String: Any],
              origin["kind"] as? String == "human",
              attachment["commandMode"] as? String != "task-notification" else { return [] }
        // Use identity when both representations exist. Equal text alone can be two sends.
        if let source = attachment["source_uuid"] as? String {
            guard !userMessageIDs.contains(source), queuedSourceIDs.insert(source).inserted else { return [] }
        }
        return parseUser(attachment["prompt"], id: id, time: time ?? (attachment["timestamp"] as? String))
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
        let s = ClaudePastedContent.unwrap(raw)
        if s.hasPrefix("<command-name>") || s.hasPrefix("<command-message>") {
            let name = Self.between(s, "<command-name>", "</command-name>") ?? "command"
            let args = Self.between(s, "<command-args>", "</command-args>") ?? ""
            let command = "\(name) \(args)".trimmingCharacters(in: .whitespaces)
            // Native /plan can record command XML together with image blocks. Keep that
            // multimodal input as a user message so its images render and acknowledge once.
            if !images.isEmpty {
                return [ReaderEntry(id: id, kind: .user, text: command, images: images, time: time,
                                    author: scope == .subagent ? "Parent" : nil)]
            }
            return [ReaderEntry(id: id, kind: .notice, text: "Ran \(command)", time: time)]
        }
        for tag in ["local-command-stdout", "local-command-stderr"] where s.hasPrefix("<" + tag + ">") {
            let output = (Self.between(s, "<" + tag + ">", "</" + tag + ">") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { return [] }
            return [ReaderEntry(id: id, kind: tag.hasSuffix("stderr") ? .error : .notice, text: String(output.prefix(2000)), time: time)]
        }
        if s.hasPrefix("[Request interrupted by user") {
            return [ReaderEntry(id: id, kind: .notice, text: "Interrupted", time: time)]
        }
        if Self.noisePrefixes.contains(where: { s.hasPrefix($0) }) { return [] }
        if s.isEmpty && images.isEmpty { return [] }
        // Pasted images show as "[Image #1]" placeholders in the prompt text; the image
        // itself arrives as an image block and is shown below the prose.
        return [ReaderEntry(id: id, kind: .user, text: s, images: images, time: time,
                            author: scope == .subagent ? "Parent" : nil)]
    }

    private mutating func toolResult(_ item: [String: Any], id: String, time: String?) -> [ReaderEntry] {
        let toolID = item["tool_use_id"] as? String ?? ""
        let name = toolNames[toolID] ?? "Tool"
        // Handback carries the answer in its call. Its successful receipt is bookkeeping,
        // but a rejected or failed delivery still needs to be visible below.
        if scope == .subagent, name == "SubagentHandback", item["is_error"] as? Bool != true { return [] }
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
        if scope == .subagent, item["is_error"] as? Bool != true, !text.isEmpty {
            out.append(ReaderEntry(id: id, kind: .tool, text: "\(name) result", detail: String(text.prefix(12_000)), tool: name, time: time))
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
                // Newer Claude children finish through this tool instead of a text block.
                // Treat the report as their answer, not a collapsed tool with no content.
                if scope == .subagent, name == "SubagentHandback",
                   let report = input["message"] as? String,
                   !report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(ReaderEntry(id: eid, kind: .assistant, text: report, time: time))
                    continue
                }
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
    private let scope: TranscriptScope
    init(scope: TranscriptScope = .chat) { self.scope = scope }
    private var lineNo = 0
    private var previousModel: String?
    private var lastCompactionRecord: String?
    private var sideBoundarySeen = false
    private var agentPath: String?

    private var evidence = ReaderEvidence(kind: .codex)

    mutating func parse(line: Data) -> [ReaderEntry] {
        let entries = parseContent(line: line)
        if scope == .side, !sideBoundarySeen { return [] }
        return evidence.consume(line, entries: entries)
    }

    private mutating func parseContent(line: Data) -> [ReaderEntry] {
        lineNo += 1
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String,
              let p = obj["payload"] as? [String: Any] else { return [] }
        let time = obj["timestamp"] as? String
        let id = (p["id"] as? String).map { "x\(lineNo)-\($0)" } ?? "x\(lineNo)"
        let ptype = p["type"] as? String

        // Attached side forks may physically copy the parent's history. The native
        // boundary is injected after that copy, before the first actual side question.
        if scope == .side {
            if type == "response_item", ptype == "message", p["role"] as? String == "user",
               let content = p["content"] as? [[String: Any]], content.contains(where: {
                   $0["type"] as? String == "input_text" && ($0["text"] as? String)?.hasPrefix("Side conversation boundary.") == true
               }) {
                sideBoundarySeen = true
                return []
            }
            if !sideBoundarySeen { return [] }
        }

        if type == "compacted" || (type == "event_msg" && ptype == "context_compacted") {
            let record = type == "compacted" ? "compacted" : "event"
            if let previous = lastCompactionRecord, previous != record {
                lastCompactionRecord = nil
                return []
            }
            lastCompactionRecord = record
            return [ReaderEntry(id: id, kind: .notice, text: "Conversation compacted", time: time)]
        }
        if type == "turn_context", let model = p["model"] as? String {
            let previous = previousModel
            previousModel = model
            if let previous, previous != model {
                return [ReaderEntry(id: id, kind: .notice, text: "Model changed to \(model)", time: time)]
            }
            return []
        }

        switch (type, ptype) {
        case ("session_meta", _):
            let source = p["source"] as? [String: Any]
            let subagent = source?["subagent"] as? [String: Any]
            let spawn = subagent?["thread_spawn"] as? [String: Any]
            agentPath = (p["agent_path"] as? String) ?? (spawn?["agent_path"] as? String)
            return []

        case ("response_item", "agent_message"):
            // Codex children receive their task and followups as collaboration messages.
            // Keep the sender and plaintext payload, never the opaque encrypted block.
            // A bounded tail may start after the session metadata.
            guard scope == .subagent,
                  let author = p["author"] as? String, !author.isEmpty,
                  let recipient = p["recipient"] as? String, !recipient.isEmpty,
                  agentPath == nil || recipient == agentPath,
                  let content = p["content"] as? [[String: Any]] else { return [] }
            let text = content.compactMap { item -> String? in
                guard item["type"] as? String == "input_text" else { return nil }
                return item["text"] as? String
            }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let encrypted = content.contains { $0["type"] as? String == "encrypted_content" }
            if encrypted && (text.isEmpty || Self.agentMessagePayload(text, author: author) == "") {
                return [ReaderEntry(id: id, kind: .notice,
                                    text: "Codex saved this delegated message as encrypted content. Its text is unavailable in the transcript.",
                                    time: time, author: author, contentUnavailable: "encrypted-agent-message")]
            }
            guard !text.isEmpty else { return [] }
            lastCompactionRecord = nil
            return [ReaderEntry(id: id, kind: .user, text: Self.agentMessageText(text, author: author), time: time, author: author)]

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
                lastCompactionRecord = nil
                let kept = texts.filter { !Self.isContextBlock($0) }
                if kept.isEmpty && images.isEmpty { return [] }
                return [ReaderEntry(id: id, kind: .user, text: kept.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines), images: images, time: time,
                                    author: scope == .subagent ? "Parent" : nil)]
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

        case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
            guard scope == .subagent || scope == .side else { return [] }
            let output = CodexWorkParser.outputText(p["output"])
            guard !output.isEmpty else { return [] }
            return [ReaderEntry(id: id, kind: .tool, text: "Tool result", detail: String(output.prefix(12_000)), time: time)]

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

    /// Strip only a recognized collaboration envelope. Unknown formats remain readable.
    static func agentMessageText(_ text: String, author: String) -> String {
        guard let payload = agentMessagePayload(text, author: author), !payload.isEmpty else { return text }
        return payload
    }

    private static func agentMessagePayload(_ text: String, author: String) -> String? {
        // A header-only plaintext block can end at Payload: before encrypted content.
        let terminated = text + "\n"
        guard let delimiter = terminated.range(of: "\nPayload:\n") else { return nil }
        let header = terminated[..<delimiter.lowerBound].split(separator: "\n").map(String.init)
        guard let first = header.first, ["Message Type: NEW_TASK", "Message Type: MESSAGE", "Message Type: FINAL_ANSWER"].contains(first),
              header.contains("Sender: " + author),
              header.dropFirst().allSatisfy({ $0.hasPrefix("Task name: ") || $0.hasPrefix("Sender: ") }) else { return nil }
        return String(terminated[delimiter.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
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
        // A subagent's or a reviewer's rollout shares its parent's folder; it's never a chat's own.
        let source = p["source"] as? [String: Any]
        if p["parent_thread_id"] is String || source?["subagent"] != nil || source?["internal"] != nil
            || ["subagent", "guardian_review"].contains(p["thread_source"] as? String ?? "") { return nil }
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
    var isFollowing: Bool { timer?.isValid == true }
    private let baseDir: String?
    private let kind: TranscriptKind
    private let scope: TranscriptScope
    private var initialRead = true
    private var fileNumber: UInt64?
    private var invalidRecords = false
    private(set) var health: ReaderHealth = .loading
    private var skipToNewline = false
    static let subagentTailBytes: UInt64 = 2 << 20
    private let queue = DispatchQueue(label: "hantuu.transcript", qos: .userInitiated)
    private var pollPending = false
    private var pollAgain = false
    private var restartRequested = false
    private var fileWatch: FileWatch?
    private(set) var lastReadDuration: TimeInterval = 0
    private(set) var lastReadWasOnMain = true
    var onAppend: (([ReaderEntry]) -> Void)?
    var onReset: (() -> Void)?

    init(url: URL, kind: TranscriptKind, baseDir: String?, scope: TranscriptScope = .chat) {
        self.url = url
        self.baseDir = baseDir
        self.kind = kind
        self.scope = scope
        switch kind {
        case .claude: parser = ClaudeTranscriptParser(scope: scope)
        case .codex: parser = CodexTranscriptParser(scope: scope)
        }
    }

    deinit { timer?.invalidate(); fileWatch?.stop() }

    func start(interval: TimeInterval = 0.5, follow: Bool = true) {
        stop()
        requestPoll()
        if follow {
            fileWatch = FileWatch(path: url.path) { [weak self] in self?.requestPoll() }
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.requestPoll() }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        fileWatch?.stop()
        fileWatch = nil
        pollAgain = false
        restartRequested = false
    }

    /// Reads and parses on a serial worker. Only delivery touches the reader on main.
    func retry() { requestPoll(restart: true) }

    private func requestPoll(restart: Bool = false) {
        if pollPending {
            pollAgain = true
            restartRequested = restartRequested || restart
            return
        }
        let restart = restart || restartRequested
        restartRequested = false
        pollAgain = false
        pollPending = true
        queue.async { [self] in
            let start = Date()
            if restart {
                offset = 0
                partial = Data()
                initialRead = true
                invalidRecords = false
                skipToNewline = false
                switch kind {
                case .claude: parser = ClaudeTranscriptParser(scope: scope)
                case .codex: parser = CodexTranscriptParser(scope: scope)
                }
            }
            var batch = read()
            if restart, !["missing", "unreadable"].contains(batch.health.state) { batch.reset = true }
            let elapsed = Date().timeIntervalSince(start)
            let onMain = Thread.isMainThread
            DispatchQueue.main.async { [self] in
                pollPending = false
                lastReadDuration = elapsed
                lastReadWasOnMain = onMain
                deliver(batch)
                // A final append or explicit retry can arrive while the previous read is
                // in flight. Deliver that request immediately instead of losing the edge.
                if pollAgain || restartRequested { requestPoll(restart: restartRequested) }
            }
        }
    }

    /// Synchronous polling is for small fixtures. App attachments always use start().
    @discardableResult
    func poll() -> [ReaderEntry] {
        guard !pollPending else { return [] }
        let batch = queue.sync { read() }
        deliver(batch)
        return batch.entries
    }

    private struct Batch {
        var entries: [ReaderEntry] = []
        var reset = false
        var health: ReaderHealth = .connected
    }

    private func deliver(_ batch: Batch) {
        health = batch.health
        if batch.reset { entries = []; onReset?() }
        guard !batch.entries.isEmpty else { return }
        entries = ReaderEntries.merging(entries, batch.entries)
        onAppend?(batch.entries)
    }

    private func initialPrompt() -> ReaderEntry? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 512 * 1024)) ?? Data()
        var head: TranscriptParser
        switch kind {
        case .claude: head = ClaudeTranscriptParser(scope: scope)
        case .codex: head = CodexTranscriptParser(scope: scope)
        }
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            let entries = head.parse(line: Data(data[start..<newline]))
            if var prompt = entries.first(where: { $0.kind == .user }) {
                prompt.id = "head-prompt-" + prompt.id
                return prompt
            }
            start = data.index(after: newline)
        }
        return nil
    }

    /// The parser and file cursor belong to queue, including the first full read.
    private func read() -> Batch {
        var batch = Batch()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            batch.health = FileManager.default.fileExists(atPath: url.path) ? .unreadable : .missing
            return batch
        }
        let number = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        let replaced = fileNumber != nil && number != nil && fileNumber != number
        fileNumber = number
        if size < offset || replaced {
            // File was replaced or truncated: start over.
            offset = 0
            partial = Data()
            batch.reset = true
            initialRead = true
            invalidRecords = false
            skipToNewline = false
            switch kind {
            case .claude: parser = ClaudeTranscriptParser(scope: scope)
            case .codex: parser = CodexTranscriptParser(scope: scope)
            }
        }
        if initialRead {
            initialRead = false
            if scope == .subagent, size > Self.subagentTailBytes {
                offset = size - Self.subagentTailBytes
                skipToNewline = true
                // Keep the original task when it fits in a small head read.
                if let prompt = initialPrompt() { batch.entries.append(prompt) }
                batch.entries.append(ReaderEntry(id: "tail-notice", kind: .notice, text: "Showing the latest part of this subagent's conversation."))
            }
        }
        guard size > offset else {
            batch.health = invalidRecords ? .malformed : (partial.isEmpty ? (size == 0 ? .waiting : .connected) : .incomplete)
            return batch
        }
        guard let h = try? FileHandle(forReadingFrom: url) else { batch.health = .unreadable; return batch }
        defer { try? h.close() }
        do { try h.seek(toOffset: offset) } catch { batch.health = .unreadable; return batch }
        let data: Data
        do {
            if scope == .subagent || scope == .side { data = try h.read(upToCount: 4 << 20) ?? Data() }
            else { data = try h.readToEnd() ?? Data() }
        } catch { batch.health = .unreadable; return batch }
        offset += UInt64(data.count)
        var buf = partial.isEmpty ? data : partial + data
        if skipToNewline {
            guard let nl = buf.firstIndex(of: 0x0A) else { partial = Data(); return batch }
            buf = Data(buf[buf.index(after: nl)...])
            skipToNewline = false
        }
        var fresh: [ReaderEntry] = []
        var start = buf.startIndex
        while let nl = buf[start...].firstIndex(of: 0x0A) {
            let line = buf[start..<nl]
            start = buf.index(after: nl)
            if line.isEmpty { continue }
            if (try? JSONSerialization.jsonObject(with: Data(line))) == nil { invalidRecords = true; continue }
            fresh += parser.parse(line: Data(line))
        }
        partial = Data(buf[start...])
        batch.health = invalidRecords ? .malformed : (partial.isEmpty ? (size == 0 ? .waiting : .connected) : .incomplete)
        if fresh.isEmpty { return batch }
        for i in fresh.indices {
            fresh[i].links = PathDetector.detect(in: fresh[i].text + "\n" + (fresh[i].detail ?? ""), base: baseDir)
            for f in fresh[i].files {
                if let d = PathDetector.resolve(f, base: baseDir), !fresh[i].links.contains(where: { $0.path == d.path }) {
                    fresh[i].links.append(DetectedPath(match: f, path: d.path, line: nil, kind: d.kind))
                }
            }
        }
        batch.entries += fresh
        return batch
    }
}
