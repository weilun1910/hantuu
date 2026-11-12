import Foundation

/// Recorded evidence belongs to an invocation, not to the current working tree.
struct ReaderOperation: Codable, Equatable {
    var id: String
    var name: String
    var provider: String
    var arguments: String
    var command: String?
    var output: String?
    var exitCode: Int?
    var state = "requested"
    var patch: String?
    var patchNote: String?
    var startedAt: String?
    var finishedAt: String?
    var truncated = false
    var childID: String?
    var childTranscript: String?
    var activity: String?
    var report: String?
    var outputFile: String?
    var duration: Double?
}

/// Both the follower and external readers replace evidence by identity in place.
enum ReaderEntries {
    static func merging(_ old: [ReaderEntry], _ updates: [ReaderEntry]) -> [ReaderEntry] {
        var result: [ReaderEntry] = []
        var positions: [String: Int] = [:]
        for entry in old + updates {
            if let index = positions[entry.id] { result[index] = entry }
            else { positions[entry.id] = result.count; result.append(entry) }
        }
        return result
    }
}

/// Adds invocation evidence to the existing prose adapters. It never reads source files.
struct ReaderEvidence {
    let kind: TranscriptKind
    private var session = "transcript"
    private var calls: [String: ReaderEntry] = [:]
    private var processCalls: [String: String] = [:]
    private var handbackCalls = Set<String>()
    private var claudeWork = ClaudeWorkParser()
    private var codexWork = CodexWorkParser()
    private var checklist: ReaderChecklistReducer
    private var lastChecklist: ReaderChecklist?
    private var lastWork = AgentWork()

    init(kind: TranscriptKind) {
        self.kind = kind
        checklist = ReaderChecklistReducer(kind: kind)
    }

    mutating func consume(_ line: Data, entries: [ReaderEntry], includeSidechain: Bool = false) -> [ReaderEntry] {
        guard var obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return entries }
        if obj["isSidechain"] as? Bool == true {
            guard includeSidechain else { return entries }
            obj["isSidechain"] = false
        }
        let time = obj["timestamp"] as? String
        var incoming: String?
        if kind == .claude { incoming = obj["sessionId"] as? String }
        else if obj["type"] as? String == "session_meta" { incoming = (obj["payload"] as? [String: Any])?["id"] as? String }
        var boundary: ReaderEntry?
        if let incoming, incoming != session {
            if session != "transcript" {
                self = ReaderEvidence(kind: kind)
                boundary = ReaderEntry(id: "session:\(incoming)", kind: .notice, text: "Conversation changed", time: time)
            }
            session = incoming
        }
        var result = boundary.map { [$0] + entries } ?? entries
        if kind == .claude {
            if let id = obj["sessionId"] as? String { session = id }
            claudeWork.consume(obj)
            let message = obj["message"] as? [String: Any] ?? [:]
            let blocks = message["content"] as? [[String: Any]] ?? []
            if obj["type"] as? String == "assistant" {
                for (index, block) in blocks.enumerated() {
                    if block["type"] as? String == "thinking", let text = block["thinking"] as? String, !text.isEmpty {
                        result.append(ReaderEntry(id: "reasoning:\(session):\(obj["uuid"] as? String ?? time ?? ""):\(index)", kind: .reasoning, text: text, time: time))
                    }
                    guard block["type"] as? String == "tool_use", let id = block["id"] as? String else { continue }
                    let name = block["name"] as? String ?? "Tool"
                    let args = block["input"] as? [String: Any] ?? [:]
                    // The child prose adapter already renders this report as its answer.
                    if includeSidechain, name == "SubagentHandback",
                       let report = args["message"] as? String,
                       !report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       entries.contains(where: { $0.kind == .assistant && $0.text == report }) {
                        handbackCalls.insert(id)
                        continue
                    }
                    let candidates = result.indices.filter { result[$0].tool == name && result[$0].operation == nil }
                    let original = candidates.first.map { result[$0] }
                    let entry = requested(id: id, name: name, args: args, raw: Self.json(args), time: time, original: original)
                    if let i = candidates.first { result[i] = entry } else { result.append(entry) }
                }
            } else if obj["type"] as? String == "user" {
                let outcomes = blocks.filter { $0["type"] as? String == "tool_result" }
                if !outcomes.isEmpty { result.removeAll { $0.kind != .user && $0.tool != "SubagentHandback" } }
                for block in outcomes {
                    guard let id = block["tool_use_id"] as? String else { continue }
                    // Successful receipts are hidden by the prose adapter. Its delivery
                    // errors stay visible, without turning the report back into a tool.
                    if handbackCalls.contains(id) { continue }
                    let output = ClaudeTranscriptParser.textOf(block["content"]) ?? ""
                    let metadata = outcomes.count == 1 ? obj["toolUseResult"] as? [String: Any] : nil
                    let failed = block["is_error"] as? Bool == true
                    var update = completed(id: id, output: output, metadata: metadata, failed: failed, time: time)
                    if let images = block["content"] as? [[String: Any]] {
                        update.images = images.compactMap(ClaudeTranscriptParser.imageSource)
                        calls[id] = update
                    }
                    result.append(update)
                }
            }
        } else {
            let payload = obj["payload"] as? [String: Any] ?? [:]
            let type = obj["type"] as? String
            let ptype = payload["type"] as? String
            if type == "session_meta", let id = payload["id"] as? String { session = id }
            codexWork.consume(obj)
            if type == "event_msg", var entry = CodexOperationEvent.entry(payload, session: session, time: time) {
                let item = payload["item"] as? [String: Any] ?? [:]
                let processID = CodexWorkParser.string(item["process_id"])
                let callID = processID.flatMap { processCalls[$0] }
                // Only a known direct shell can share this identity. An exec wrapper may
                // contain several operations with different outcomes and keeps its own card.
                if let callID, let original = calls[callID], let prior = original.operation,
                   ["exec_command", "shell", "shell_command", "local_shell"].contains(prior.name) {
                    let startedAt = prior.startedAt ?? entry.operation?.startedAt
                    entry.id = original.id
                    entry.operation?.id = prior.id
                    entry.operation?.arguments = prior.arguments
                    entry.operation?.startedAt = startedAt
                    calls[callID] = entry
                }
                result.append(entry)
            }
            if type == "response_item" {
                if ["function_call", "custom_tool_call", "local_shell_call"].contains(ptype ?? ""),
                   let id = (payload["call_id"] as? String) ?? (payload["id"] as? String) {
                    let name = payload["name"] as? String ?? "shell"
                    let raw = (payload["arguments"] as? String) ?? (payload["input"] as? String) ?? ""
                    let args = (payload["action"] as? [String: Any]) ?? Self.object(raw)
                    result = [requested(id: id, name: name, args: args, raw: raw, time: time, original: entries.first)]
                } else if ["function_call_output", "custom_tool_call_output"].contains(ptype ?? ""), let id = payload["call_id"] as? String {
                    let raw = payload["output"]
                    let output = Self.outputText(raw)
                    let metadata = raw as? [String: Any]
                    let failed = metadata?["isError"] as? Bool == true || metadata?["is_error"] as? Bool == true
                    result = [completed(id: id, output: output, metadata: metadata, failed: failed, time: time)]
                } else if ptype == "reasoning" {
                    let published = ((payload["summary"] as? [[String: Any]]) ?? []) + ((payload["content"] as? [[String: Any]]) ?? [])
                    let text = published.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                    if !text.isEmpty { result.append(ReaderEntry(id: "reasoning:\(session):\(payload["id"] as? String ?? time ?? "")", kind: .reasoning, text: text, time: time)) }
                }
            }
        }
        let interrupted = result.contains { ($0.kind == .notice || $0.kind == .error) && $0.text.lowercased().contains("interrupt") }
        if interrupted {
            for (id, var entry) in calls where ["requested", "running"].contains(entry.operation?.state ?? "") {
                entry.operation?.state = "interrupted"
                entry.operation?.finishedAt = time
                calls[id] = entry
                result.append(entry)
            }
        }
        let checklistLine = includeSidechain ? (try? JSONSerialization.data(withJSONObject: obj)) ?? line : line
        if let plan = checklist.consume(line: checklistLine), plan != lastChecklist {
            lastChecklist = plan
            result.append(ReaderEntry(id: "checklist:\(session)", kind: .checklist, text: "Execution checklist", time: time, checklist: plan))
        }
        for entry in result {
            guard let op = entry.operation, let parentID = processCalls[op.id], parentID != op.id,
                  var parent = calls[parentID], let output = op.output else { continue }
            let combinedOutput = [parent.operation?.output, output].compactMap { $0 }.joined(separator: "\n")
            parent.operation?.output = combinedOutput
            parent.operation?.state = op.state
            parent.operation?.exitCode = op.exitCode
            parent.operation?.finishedAt = op.finishedAt
            calls[parentID] = parent
            result.append(parent)
        }
        result += workUpdates(time: time)
        return ReaderEntries.merging([], result)
    }

    private mutating func requested(id: String, name: String, args: [String: Any], raw: String, time: String?, original: ReaderEntry?) -> ReaderEntry {
        var entry = original ?? ReaderEntry(id: id, kind: .tool, text: name, tool: name, time: time)
        entry.id = "operation:\(session):\(id)"
        // A request is not evidence that the operation ran or succeeded.
        if entry.kind == .tool { entry.text = (args["description"] as? String) ?? name }
        let shortName = name.split(separator: ".").last.map(String.init) ?? name
        if kind == .codex, name != shortName {
            let normalized = CodexTranscriptParser.toolEntry(name: shortName, args: args, raw: raw, id: entry.id, time: time)
            entry.files = normalized.files
            entry.kind = normalized.kind
            entry.detail = normalized.detail
        }
        var operation = ReaderOperation(id: id, name: shortName, provider: kind.rawValue, arguments: raw, startedAt: time)
        operation.command = (args["cmd"] as? String) ?? (args["command"] as? String) ?? (args["command"] as? [String])?.joined(separator: " ")
        if shortName == "exec", operation.command == nil {
            operation.command = raw
            let patches = Self.literalPatches(raw)
            if !patches.isEmpty {
                operation.patch = patches.joined(separator: "\n\n")
                operation.patchNote = "Recorded patch literals from the script. The result describes the whole invocation, not each nested call."
            }
        }
        if shortName == "apply_patch" {
            operation.patch = (args["input"] as? String) ?? raw
            if operation.patch?.contains("*** Delete File:") == true { operation.patchNote = "Deleted file contents are available only when the provider included them in this patch." }
        }
        if ["Edit", "MultiEdit", "Write"].contains(shortName) {
            operation.patchNote = shortName == "Write"
                ? "Recorded new content. The previous file contents were not recorded."
                : "Recorded replacement text. Repeated matches can change more lines than this excerpt."
            let path = args["file_path"] as? String ?? "file"
            let edits = (args["edits"] as? [[String: Any]]) ?? [args]
            operation.patch = edits.map { edit in
                let old = edit["old_string"] as? String ?? ""
                let new = (edit["new_string"] as? String) ?? (edit["content"] as? String) ?? ""
                let removed = old.isEmpty ? "" : old.components(separatedBy: "\n").map { "-" + $0 }.joined(separator: "\n") + "\n"
                let added = new.isEmpty ? "" : new.components(separatedBy: "\n").map { "+" + $0 }.joined(separator: "\n")
                return "--- \(path)\n+++ \(path)\n@@ Recorded replacement @@\n" + removed + added
            }.joined(separator: "\n")
        }
        if shortName == "request_user_input" { entry.text = Self.questions(args); entry.kind = .question }
        // A resumed process can report its eventual result through a later write_stdin.
        let processID = CodexWorkParser.string(args["session_id"])
            ?? CodexWorkParser.string(args["cell_id"]).map { "cell:" + $0 }
        if let processID, let parent = processCalls[processID] { processCalls[id] = parent }
        entry.operation = operation
        calls[id] = entry
        return entry
    }

    /// Read JSON string literals without evaluating the provider's orchestration script.
    /// Computed arguments remain available in the complete recorded command.
    static func literalPatches(_ script: String) -> [String] {
        let pattern = #"\btools\.apply_patch\s*\(\s*("(?:[^"\\]|\\.)*")\s*\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: script, range: NSRange(script.startIndex..., in: script)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: script),
                  let data = String(script[range]).data(using: .utf8),
                  let patch = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String,
                  patch.hasPrefix("*** Begin Patch\n"), patch.contains("*** End Patch") else { return nil }
            return patch
        }
    }

    private mutating func completed(id: String, output: String, metadata: [String: Any]?, failed: Bool, time: String?) -> ReaderEntry {
        var entry = calls[id] ?? ReaderEntry(id: "operation:\(session):\(id)", kind: .tool, text: "Tool result", tool: "Tool", time: time)
        var operation = entry.operation ?? ReaderOperation(id: id, name: "Tool", provider: kind.rawValue, arguments: "")
        operation.output = output
        operation.finishedAt = time
        if let start = operation.startedAt.flatMap(CodexTranscriptParser.parseDate), let end = time.flatMap(CodexTranscriptParser.parseDate) {
            operation.duration = max(0, end.timeIntervalSince(start))
        }
        let info = Self.outcome(output, metadata: metadata)
        operation.exitCode = info.exitCode
        operation.truncated = info.truncated
        let denied = failed && ["doesn't want to proceed", "user rejected", "was rejected"].contains(where: output.lowercased().contains)
        operation.state = denied ? "declined" : (failed || (info.exitCode.map { $0 != 0 } ?? false) ? "failed" : "completed")
        if metadata?["interrupted"] as? Bool == true { operation.state = "interrupted" }
        if let pid = info.processID {
            if !failed && !(info.exitCode.map { $0 != 0 } ?? false) {
                operation.state = "running"
                operation.exitCode = nil
                operation.finishedAt = nil
            }
            processCalls[pid] = processCalls[id] ?? id
        }
        if operation.state == "failed" || operation.state == "declined" || operation.state == "interrupted" { entry.kind = .tool }
        entry.operation = operation
        calls[id] = entry
        return entry
    }

    private mutating func workUpdates(time: String?) -> [ReaderEntry] {
        let work = kind == .claude ? claudeWork.work : codexWork.work
        defer { lastWork = work }
        var updates: [ReaderEntry] = []
        for agent in work.subagents where !lastWork.subagents.contains(agent) {
            let matching = calls.first { key, value in
                key == agent.id || value.operation?.childID == agent.id || (agent.agentID != nil && value.operation?.childID == agent.agentID) ||
                (value.operation?.name == "spawn_agent" && Self.object(value.operation?.arguments ?? "")["task_name"] as? String == agent.id.split(separator: "/").last.map(String.init))
            }
            let callID = matching?.key ?? "agent:\(agent.id)"
            var entry = matching?.value ?? ReaderEntry(id: "work:\(session):\(agent.id)", kind: .tool, text: agent.title, tool: "Agent", time: time)
            var operation = entry.operation ?? ReaderOperation(id: callID, name: "Agent", provider: kind.rawValue, arguments: agent.prompt ?? "")
            operation.childID = agent.id
            operation.report = agent.result
            operation.duration = agent.duration
            operation.state = Self.workState(agent.state)
            operation.startedAt = agent.startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? operation.startedAt
            operation.finishedAt = agent.endedAt.map { ISO8601DateFormatter().string(from: $0) }
            entry.text = agent.title
            entry.operation = operation
            calls[callID] = entry
            updates.append(entry)
        }
        for task in work.tasks where !lastWork.tasks.contains(task) {
            let callID = calls.keys.first(where: { $0 == task.id }) ?? task.taskID.flatMap { processCalls[$0] }
            var entry = callID.flatMap { calls[$0] } ?? ReaderEntry(id: "background:\(session):\(task.id)", kind: .tool, text: task.title, tool: "Background command", time: time)
            var operation = entry.operation ?? ReaderOperation(id: task.id, name: "Background command", provider: kind.rawValue, arguments: "", command: task.command)
            operation.state = Self.workState(task.state)
            operation.exitCode = task.exitCode
            operation.outputFile = task.outputFile
            operation.report = task.lastEvent
            operation.duration = task.duration
            operation.startedAt = task.startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? operation.startedAt
            operation.finishedAt = task.endedAt.map { ISO8601DateFormatter().string(from: $0) } ?? operation.finishedAt
            entry.operation = operation
            if let callID { calls[callID] = entry }
            updates.append(entry)
        }
        return updates
    }

    static func workState(_ state: WorkState) -> String {
        switch state {
        case .running, .waiting: return "running"
        case .done: return "completed"
        case .failed: return "failed"
        case .stopped: return "interrupted"
        case .stale: return "unknown"
        }
    }

    struct Outcome { var exitCode: Int?; var processID: String?; var truncated = false }
    static func outcome(_ output: String, metadata: [String: Any]?) -> Outcome {
        var info = Outcome()
        func ingest(_ value: [String: Any]) {
            if let code = (value["exit_code"] as? NSNumber)?.intValue ?? (value["exitCode"] as? NSNumber)?.intValue { if info.exitCode == nil || code != 0 { info.exitCode = code } }
            if value["exit_code"] == nil || value["exit_code"] is NSNull {
                if let pid = CodexWorkParser.string(value["session_id"]) { info.processID = pid }
            }
            if value["truncated"] as? Bool == true { info.truncated = true }
            if let inner = value["metadata"] as? [String: Any] { ingest(inner) }
        }
        if let metadata { ingest(metadata) }
        ingest(object(output))
        // Exec wrappers contain one serialized command result per output line.
        for line in output.split(whereSeparator: \.isNewline) { ingest(object(String(line))) }
        if let r = output.range(of: #"(?:Process exited with code|Exit code) -?\d+"#, options: .regularExpression) { if let code = Int(output[r].split(separator: " ").last ?? ""), info.exitCode == nil || code != 0 { info.exitCode = code } }
        if let r = output.range(of: #"Process running with session ID \d+"#, options: .regularExpression) { info.processID = String(output[r].split(separator: " ").last ?? "") }
        if let r = output.range(of: #"Script running with cell ID [A-Za-z0-9_-]+"#, options: .regularExpression) {
            info.processID = "cell:" + String(output[r].split(separator: " ").last ?? "")
        }
        info.truncated = info.truncated || output.contains("tokens truncated") || output.contains("Output truncated")
        return info
    }

    static func outputText(_ value: Any?) -> String {
        let text = CodexWorkParser.outputText(value)
        if !text.isEmpty { return text }
        if let object = value as? [String: Any] { return json(object) }
        return ""
    }

    static func object(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8) else { return [:] }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }
    static func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func questions(_ args: [String: Any]) -> String {
        guard let questions = args["questions"] as? [[String: Any]] else { return args["question"] as? String ?? "The agent has a question." }
        return questions.map { question in
            let title = (question["question"] as? String) ?? (question["title"] as? String) ?? "Question"
            let options = (question["options"] as? [[String: Any]]) ?? []
            return ([title] + options.map { "- " + ($0["label"] as? String ?? "") + ($0["description"].map { ": \($0)" } ?? "") }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
