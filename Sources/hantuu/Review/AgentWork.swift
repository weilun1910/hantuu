import Foundation

/// Where one piece of background work stands.
enum WorkState: String, Equatable {
    case running     // working now
    case waiting     // its own turn ended, but agents it started are still going
    case done
    case failed
    case stopped     // stopped by the agent, by you, or when the chat ended
    case stale       // never reported back and has been quiet too long to count as running

    var isActive: Bool { self == .running || self == .waiting }
}

/// One subagent a chat started: Claude Code's Agent tool (and the agents those start), or a
/// Codex spawn_agent.
struct SubagentInfo: Equatable, Identifiable {
    /// Stable from the moment the agent is asked for: the tool_use id for Claude, the agent
    /// path for Codex, "agent-<id>" for agents another subagent started.
    var id: String
    /// Claude Code's agent id, or the Codex thread id.
    var agentID: String?
    /// The id of the SubagentInfo that started this one, for agents started by subagents.
    var parentID: String?
    var title: String
    var type: String?
    var model: String?
    var background = false
    var prompt: String?
    var state: WorkState = .running
    var startedAt: Date?
    /// When it last started working, which is later than startedAt once it's been resumed.
    var activeSince: Date?
    var endedAt: Date?
    var duration: TimeInterval?
    /// When it last showed signs of life (its transcript or output grew). Set for stale work.
    var lastUpdate: Date?
    var result: String?
    /// What it's doing now, in the sidebar's words ("Running Bash: swift build").
    var step: String?
    /// Its own transcript or rollout, once known.
    var transcript: String?
}

/// A background shell command or monitor (Claude Code), or a terminal that outlived its call
/// (Codex unified exec).
struct BackgroundTaskInfo: Equatable, Identifiable {
    enum Kind: String { case shell, monitor, terminal }
    var id: String
    var taskID: String?
    var kind: Kind
    var title: String
    var command: String?
    var state: WorkState = .running
    var exitCode: Int?
    var startedAt: Date?
    var endedAt: Date?
    var duration: TimeInterval?
    var outputFile: String?
    var lastEvent: String?
    /// When it last showed signs of life (its output grew). Set for stale work.
    var lastUpdate: Date?
}

struct AgentWork: Equatable {
    var subagents: [SubagentInfo] = []
    var tasks: [BackgroundTaskInfo] = []
    var isEmpty: Bool { subagents.isEmpty && tasks.isEmpty }
}

enum WorkTime {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: Any?) -> Date? {
        guard let s = s as? String, !s.isEmpty else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }

    /// "12s", "4m", "1h 5m": short enough for the right edge of a row.
    static func short(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        let m = s / 60, h = m / 60
        if h > 0 { return m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m" }
        return "\(m)m"
    }
}

// MARK: - Task notifications

/// Claude Code's `<task-notification>` block: how a background agent, command or monitor
/// tells the chat that it finished (or, for monitors, that something happened).
struct TaskNotification: Equatable {
    var taskID: String?
    var toolUseID: String?
    var outputFile: String?
    var status: String?
    var summary: String?
    var result: String?
    var event: String?
    var durationMs: Int?

    static let marker = "<task-notification>"

    /// Every notification in a piece of text. Claude Code may put several in one message.
    static func parse(_ text: String) -> [TaskNotification] {
        guard text.contains(marker) else { return [] }
        var out: [TaskNotification] = []
        var rest = Substring(text)
        while let open = rest.range(of: marker) {
            let after = rest[open.upperBound...]
            let end = after.range(of: "</task-notification>")
            let body = end.map { after[..<$0.lowerBound] } ?? after
            var n = TaskNotification()
            n.taskID = tag("task-id", in: body)
            n.toolUseID = tag("tool-use-id", in: body)
            n.outputFile = tag("output-file", in: body)
            n.status = tag("status", in: body)
            n.summary = tag("summary", in: body)
            n.result = tag("result", in: body)
            n.event = tag("event", in: body)
            if let usage = tag("usage", in: body), let ms = tag("duration_ms", in: Substring(usage)) { n.durationMs = Int(ms) }
            if n.taskID != nil || n.toolUseID != nil { out.append(n) }
            rest = end.map { after[$0.upperBound...] } ?? ""
        }
        return out
    }

    static func tag(_ name: String, in s: Substring) -> String? {
        guard let a = s.range(of: "<\(name)>"), let b = s.range(of: "</\(name)>", range: a.upperBound..<s.endIndex) else { return nil }
        let v = s[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// "Background command "x" failed with exit code 1" -> 1.
    var exitCode: Int? {
        guard let s = summary, let r = s.range(of: #"exit code (-?\d+)"#, options: .regularExpression) else { return nil }
        return Int(s[r].dropFirst("exit code ".count))
    }

    var isAgent: Bool {
        guard let s = summary else { return false }
        return s.hasPrefix("Agent ") || s.hasPrefix("Background agent ")
    }

    var isMonitor: Bool { summary?.hasPrefix("Monitor") == true }

    /// The agent ended its turn but agents it started are still running.
    var isWaiting: Bool { summary?.contains("waiting on its own background work") == true }

    var state: WorkState? {
        switch status?.lowercased() {
        case "completed": return isWaiting ? .waiting : .done
        case "failed": return .failed
        case "killed", "stopped", "cancelled", "canceled": return .stopped
        case nil: return nil
        default: return .done
        }
    }

    /// The text inside the first pair of quotes in the summary: the agent's description or
    /// the command's.
    var quotedName: String? {
        guard let s = summary, let a = s.firstIndex(of: "\""), let b = s[s.index(after: a)...].firstIndex(of: "\"") else { return nil }
        let v = String(s[s.index(after: a)..<b])
        return v.isEmpty ? nil : v
    }

    /// The agent's report, unless it says the report went somewhere else (SubagentHandback).
    var report: String? {
        guard let r = result, !r.hasPrefix("This agent's report was delivered") else { return nil }
        return r
    }
}

// MARK: - Claude Code: the chat's own transcript

/// Reads a Claude Code transcript for the agents and background work it started. Fed the
/// already-parsed JSON lines by InsightsParser, in order, so a big transcript is read once.
struct ClaudeWorkParser {
    private(set) var subagents: [SubagentInfo] = []
    private(set) var tasks: [BackgroundTaskInfo] = []
    private var agentIndex: [String: Int] = [:]     // tool_use id -> subagents index
    private var taskIndex: [String: Int] = [:]      // tool_use id or task id -> tasks index
    private struct Call { var name: String; var command: String?; var title: String?; var at: Date?; var target: String? }
    private var calls: [String: Call] = [:]         // Bash, Monitor, SendMessage and TaskStop calls waiting for a result
    private var seenNotes = Set<Int>()

    var work: AgentWork { AgentWork(subagents: subagents, tasks: tasks) }

    mutating func consume(_ obj: [String: Any]) {
        if obj["isSidechain"] as? Bool == true { return }
        let time = WorkTime.parse(obj["timestamp"])
        switch obj["type"] as? String {
        case "assistant":
            guard let msg = obj["message"] as? [String: Any], let items = msg["content"] as? [[String: Any]] else { return }
            for item in items where item["type"] as? String == "tool_use" { toolUse(item, time) }
        case "user":
            guard let msg = obj["message"] as? [String: Any] else { return }
            if let s = msg["content"] as? String {
                notes(s, time)
            } else if let items = msg["content"] as? [[String: Any]] {
                for item in items {
                    switch item["type"] as? String {
                    case "tool_result": toolResult(item, result: obj["toolUseResult"], time)
                    case "text": if let t = item["text"] as? String { notes(t, time) }
                    default: break
                    }
                }
            }
        case "queue-operation":
            if obj["operation"] as? String == "enqueue", let c = obj["content"] as? String { notes(c, time) }
        case "attachment":
            guard let a = obj["attachment"] as? [String: Any], a["type"] as? String == "queued_command" else { return }
            if let p = a["prompt"] as? String { notes(p, time) }
            else if let ps = a["prompt"] as? [[String: Any]] { for p in ps { if let t = p["text"] as? String { notes(t, time) } } }
        default:
            break
        }
    }

    // MARK: Calls

    private mutating func toolUse(_ item: [String: Any], _ time: Date?) {
        guard let id = item["id"] as? String, let name = item["name"] as? String else { return }
        let input = item["input"] as? [String: Any] ?? [:]
        func s(_ k: String) -> String? {
            guard let v = input[k] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        switch name {
        case "Agent", "Task":
            // The old Task tool and today's Agent tool. TaskCreate and friends are the to-do list.
            guard input["prompt"] != nil || input["subagent_type"] != nil else { return }
            var a = SubagentInfo(id: id, title: s("description") ?? s("subagent_type") ?? "Agent")
            a.type = s("subagent_type")
            a.model = s("model")
            a.background = Self.flag(input["run_in_background"])
            a.prompt = s("prompt")
            a.startedAt = time
            a.activeSince = time
            agentIndex[id] = subagents.count
            subagents.append(a)
        case "Bash", "PowerShell":
            calls[id] = Call(name: name, command: s("command"), title: s("description"), at: time)
        case "Monitor":
            calls[id] = Call(name: name, command: s("command"), title: s("description"), at: time)
        case "SendMessage":
            calls[id] = Call(name: name, at: time, target: s("to") ?? s("recipient"))
        case "TaskStop", "KillShell":
            calls[id] = Call(name: name, at: time, target: s("task_id") ?? s("shell_id"))
        default:
            break
        }
    }

    private mutating func toolResult(_ item: [String: Any], result: Any?, _ time: Date?) {
        guard let useID = item["tool_use_id"] as? String else { return }
        let isError = item["is_error"] as? Bool == true
        let text = ClaudeTranscriptParser.textOf(item["content"]) ?? ""
        let tur = result as? [String: Any]
        if let i = agentIndex[useID] {
            agentResult(i, tur: tur, text: text, isError: isError, time)
            return
        }
        guard let call = calls.removeValue(forKey: useID) else { return }
        switch call.name {
        case "Bash", "PowerShell":
            guard !isError else { return }
            let taskID = (tur?["backgroundTaskId"] as? String) ?? Self.after("running in background with ID: ", in: text)
            guard let taskID else { return }
            var t = BackgroundTaskInfo(id: useID, taskID: taskID, kind: .shell, title: call.title ?? call.command.map(ToolCall.oneLine) ?? "Command")
            t.command = call.command
            t.startedAt = call.at ?? time
            t.outputFile = Self.outputPath(in: text)
            addTask(t)
        case "Monitor":
            guard !isError else { return }
            let taskID = (tur?["taskId"] as? String) ?? Self.after("Monitor started (task ", in: text).map { String($0.prefix { $0 != "," && $0 != ")" }) }
            var t = BackgroundTaskInfo(id: useID, taskID: taskID, kind: .monitor, title: call.title ?? call.command.map(ToolCall.oneLine) ?? "Monitor")
            t.command = call.command
            t.startedAt = call.at ?? time
            addTask(t)
        case "SendMessage":
            // Sending to a finished agent resumes it; it notifies again when it's done.
            guard !isError, let resumed = (tur?["resumedAgentId"] as? String) ?? (tur?["revivedAgentId"] as? String) ?? (text.contains("Resuming agent") ? call.target : nil),
                  let i = subagents.firstIndex(where: { $0.agentID == resumed }) else { return }
            subagents[i].state = .running
            subagents[i].activeSince = time
            subagents[i].endedAt = nil
            subagents[i].duration = nil
        case "TaskStop", "KillShell":
            guard !isError, let target = call.target else { return }
            if let i = taskIndex[target], tasks[i].state.isActive {
                tasks[i].state = .stopped
                tasks[i].endedAt = time
            } else if let i = subagents.firstIndex(where: { $0.agentID == target }), subagents[i].state.isActive {
                subagents[i].state = .stopped
                subagents[i].endedAt = time
            }
        default:
            break
        }
    }

    private mutating func agentResult(_ i: Int, tur: [String: Any]?, text: String, isError: Bool, _ time: Date?) {
        if let id = tur?["agentId"] as? String { subagents[i].agentID = id }
        else if subagents[i].agentID == nil, let id = Self.after("agentId: ", in: text) { subagents[i].agentID = String(id.prefix { !$0.isWhitespace && $0 != "(" }) }
        if subagents[i].type == nil, let t = tur?["agentType"] as? String { subagents[i].type = t }
        if subagents[i].model == nil, let m = tur?["resolvedModel"] as? String { subagents[i].model = m }
        if isError {
            subagents[i].state = .failed
            subagents[i].endedAt = time
            subagents[i].result = text.isEmpty ? nil : text
            return
        }
        let status = tur?["status"] as? String
        if status == "async_launched" || text.hasPrefix("Async agent launched") {
            subagents[i].background = true
            return
        }
        // A foreground agent: the result is its report.
        subagents[i].state = .done
        subagents[i].endedAt = time
        if let ms = (tur?["totalDurationMs"] as? NSNumber)?.doubleValue { subagents[i].duration = ms / 1000 }
        let handback = (tur?["handbackReport"] as? [String: Any])?["text"] as? String
        let report = handback ?? Self.report(from: tur?["content"]) ?? (text.isEmpty ? nil : text)
        subagents[i].result = report.flatMap { $0.hasPrefix("This agent's report was delivered") ? nil : $0 }
    }

    private mutating func addTask(_ t: BackgroundTaskInfo) {
        taskIndex[t.id] = tasks.count
        if let tid = t.taskID { taskIndex[tid] = tasks.count }
        tasks.append(t)
    }

    // MARK: Notifications

    private mutating func notes(_ text: String, _ time: Date?) {
        guard text.contains(TaskNotification.marker) else { return }
        // The same notification is written up to three times (queued, dequeued, delivered).
        guard seenNotes.insert(text.hashValue).inserted else { return }
        for n in TaskNotification.parse(text) { apply(n, time) }
    }

    private mutating func apply(_ n: TaskNotification, _ time: Date?) {
        if let i = subagents.firstIndex(where: { ($0.agentID != nil && $0.agentID == n.taskID) || $0.id == n.toolUseID }) {
            guard let state = n.state else { return }
            if subagents[i].agentID == nil { subagents[i].agentID = n.taskID }
            subagents[i].state = state
            if state == .waiting { return }
            subagents[i].endedAt = time
            if let ms = n.durationMs { subagents[i].duration = Double(ms) / 1000 }
            if let r = n.report { subagents[i].result = r }
            return
        }
        if let i = n.taskID.flatMap({ taskIndex[$0] }) ?? n.toolUseID.flatMap({ taskIndex[$0] }) {
            if let ev = n.event, n.status == nil {
                tasks[i].lastEvent = ev
                return
            }
            guard let state = n.state else { return }
            tasks[i].state = state
            tasks[i].endedAt = time
            tasks[i].exitCode = n.exitCode
            if let ev = n.event { tasks[i].lastEvent = ev }
            if tasks[i].outputFile == nil { tasks[i].outputFile = n.outputFile }
            return
        }
        // Work this transcript didn't see start, such as an agent from before a resume.
        guard let state = n.state, let tid = n.taskID else { return }
        if n.isAgent {
            var a = SubagentInfo(id: n.toolUseID ?? tid, agentID: tid, title: n.quotedName ?? "Agent")
            a.state = state
            a.endedAt = time
            a.background = true
            a.result = n.report
            if let ms = n.durationMs { a.duration = Double(ms) / 1000 }
            agentIndex[a.id] = subagents.count
            subagents.append(a)
        } else {
            var t = BackgroundTaskInfo(id: n.toolUseID ?? tid, taskID: tid, kind: n.isMonitor ? .monitor : .shell, title: n.quotedName ?? "Background command")
            t.state = state
            t.endedAt = time
            t.exitCode = n.exitCode
            t.outputFile = n.outputFile
            t.lastEvent = n.event
            addTask(t)
        }
    }

    // MARK: Helpers

    /// run_in_background is a bool, or the string "true" in some versions.
    static func flag(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let s = v as? String { return s.lowercased() == "true" }
        if let n = v as? NSNumber { return n.boolValue }
        return false
    }

    /// The rest of the line after a phrase: "...with ID: b4x. Output..." -> "b4x."
    static func after(_ phrase: String, in text: String) -> String? {
        guard let r = text.range(of: phrase) else { return nil }
        let rest = text[r.upperBound...]
        let word = rest.prefix { !$0.isWhitespace }
        guard !word.isEmpty else { return nil }
        var w = String(word)
        if phrase.hasSuffix("ID: "), w.hasSuffix(".") { w.removeLast() }
        return w
    }

    /// "Output is being written to: /path/with spaces/b4x.output. You will be notified..."
    static func outputPath(in text: String) -> String? {
        guard let r = text.range(of: "Output is being written to: ") else { return nil }
        let rest = text[r.upperBound...].prefix { $0 != "\n" }
        if let end = rest.range(of: ".output") { return String(rest[..<end.upperBound]) }
        let cut = rest.range(of: ". ").map { rest[..<$0.lowerBound] } ?? rest
        let path = cut.hasSuffix(".") ? cut.dropLast() : cut
        return path.isEmpty ? nil : String(path)
    }

    /// A foreground agent's report from its result content, without the harness notes.
    static func report(from content: Any?) -> String? {
        guard let items = content as? [[String: Any]] else { return content as? String }
        let parts = items.compactMap { $0["text"] as? String }
            .filter { !$0.hasPrefix("[Harness note") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("This agent's report was delivered") }
        let joined = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}

// MARK: - Claude Code: a subagent's own transcript

/// Reads the end of a subagent's transcript for what it's doing now and what it said last.
struct SubagentTailParser: Equatable {
    var step: String?
    var lastText: String?
    var handback: String?
    var endedTurn = false
    var lastActivity: Date?
    var prompt: String?

    var report: String? { handback ?? lastText }

    mutating func consume(_ obj: [String: Any]) {
        let time = WorkTime.parse(obj["timestamp"])
        let cwd = obj["cwd"] as? String
        guard let type = obj["type"] as? String, type == "assistant" || type == "user",
              let msg = obj["message"] as? [String: Any] else { return }
        if let t = time { lastActivity = t }
        if type == "user" {
            if let s = msg["content"] as? String {
                if prompt == nil, obj["parentUuid"] is NSNull || obj["parentUuid"] == nil { prompt = s }
                // A new message: the agent was resumed.
                if !s.hasPrefix("<system-reminder>") { endedTurn = false; handback = nil }
            }
            return
        }
        for item in (msg["content"] as? [[String: Any]]) ?? [] {
            switch item["type"] as? String {
            case "tool_use":
                let name = item["name"] as? String ?? "Tool"
                let input = item["input"] as? [String: Any] ?? [:]
                if name == "SubagentHandback" {
                    handback = (input["message"] as? String) ?? handback
                    endedTurn = true
                } else {
                    step = ToolCall(name: name, input: input, cwd: cwd).workingText
                    endedTurn = false
                }
            case "text":
                if let t = item["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastText = t }
            default:
                break
            }
        }
        if msg["stop_reason"] as? String == "end_turn" { endedTurn = true }
    }
}

/// `subagents/agent-<id>.meta.json`, which Claude Code writes next to each subagent's
/// transcript. It names agents that other subagents started, which the chat's own
/// transcript never sees.
struct SubagentMeta: Equatable {
    var agentID: String
    var agentType: String?
    var description: String?
    var toolUseID: String?
    var parentAgentID: String?
    var model: String?
    var background = false
    var finished = false

    static func read(_ url: URL) -> SubagentMeta? {
        guard let data = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let name = url.lastPathComponent
        guard name.hasPrefix("agent-"), name.hasSuffix(".meta.json") else { return nil }
        var m = SubagentMeta(agentID: String(name.dropFirst("agent-".count).dropLast(".meta.json".count)))
        m.agentType = o["agentType"] as? String
        m.description = o["description"] as? String
        m.toolUseID = o["toolUseId"] as? String
        m.parentAgentID = o["parentAgentId"] as? String
        m.model = (o["model"] as? String) ?? (o["pickedEffortModel"] as? String)
        m.background = (o["requestShape"] as? String) == "background"
        m.finished = o["finished"] as? Bool == true
        return m
    }
}

// MARK: - Codex

/// Reads a Codex rollout for the subagents it spawned (multi-agent v2) and for unified exec
/// terminals that kept running after their call returned.
struct CodexWorkParser {
    private(set) var subagents: [SubagentInfo] = []
    private(set) var tasks: [BackgroundTaskInfo] = []
    private var byPath: [String: Int] = [:]        // agent path -> subagents index
    private var spawnCalls: [String: (name: String, model: String?, effort: String?, at: Date?)] = [:]
    private var execCalls: [String: (command: String?, at: Date?)] = [:]
    private var terminals: [String: Int] = [:]     // process id -> tasks index

    var work: AgentWork { AgentWork(subagents: subagents, tasks: tasks) }

    mutating func consume(_ obj: [String: Any]) {
        guard let type = obj["type"] as? String, let p = obj["payload"] as? [String: Any] else { return }
        let time = WorkTime.parse(obj["timestamp"])
        switch (type, p["type"] as? String) {
        case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
            guard let callID = p["call_id"] as? String, let name = p["name"] as? String else { return }
            if name == "spawn_agent" {
                let args = Self.json(p["arguments"] as? String)
                spawnCalls[callID] = ((args["task_name"] as? String) ?? "agent", args["model"] as? String, args["reasoning_effort"] as? String, time)
            } else if name == "exec" || name == "exec_command" || name == "shell" || name == "shell_command" {
                let call = CodexRolloutStatus.codexCall(p, cwd: nil)
                execCalls[callID] = (call.command, time)
                if execCalls.count > 400 { execCalls.removeAll() }   // only recent calls matter
            }
        case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
            guard let callID = p["call_id"] as? String else { return }
            if let spawn = spawnCalls.removeValue(forKey: callID) {
                let out = Self.json(Self.outputText(p["output"]))
                let path = (out["task_name"] as? String) ?? "/root/\(spawn.name)"
                upsertAgent(path: path, model: spawn.model, effort: spawn.effort, thread: nil, time: spawn.at ?? time)
            } else if let exec = execCalls.removeValue(forKey: callID) {
                for pid in Self.runningSessions(in: Self.outputText(p["output"])) where terminals[pid] == nil {
                    var t = BackgroundTaskInfo(id: "codex-\(pid)", taskID: pid, kind: .terminal, title: exec.command.map(ToolCall.oneLine) ?? "A command")
                    t.command = exec.command
                    t.startedAt = exec.at ?? time
                    terminals[pid] = tasks.count
                    tasks.append(t)
                }
            }
        case ("event_msg", "item_completed"):
            guard let item = p["item"] as? [String: Any] else { return }
            switch item["type"] as? String {
            case "SubAgentActivity":
                guard let path = item["agent_path"] as? String else { return }
                let thread = item["agent_thread_id"] as? String
                switch item["kind"] as? String {
                case "started":
                    upsertAgent(path: path, model: item["model"] as? String, effort: item["reasoning_effort"] as? String, thread: thread, time: time)
                case "completed":
                    let i = upsertAgent(path: path, model: nil, effort: nil, thread: thread, time: time)
                    subagents[i].state = .done
                    subagents[i].endedAt = time
                case "interacted":
                    _ = upsertAgent(path: path, model: nil, effort: nil, thread: thread, time: time)
                default:
                    break
                }
            case "CommandExecution":
                guard let pid = Self.string(item["process_id"]), let i = terminals[pid], tasks[i].state.isActive else { return }
                if let argv = item["command"] as? [String] { tasks[i].command = CodexRolloutStatus.shellLine(argv) }
                else if let c = item["command"] as? String { tasks[i].command = c }
                if let c = tasks[i].command { tasks[i].title = ToolCall.oneLine(c) }
                let exit = (item["exit_code"] as? NSNumber)?.intValue ?? Self.string(item["exit_code"]).flatMap { Int($0) }
                tasks[i].exitCode = exit
                tasks[i].state = (item["status"] as? String) == "failed" || (exit ?? 0) != 0 ? .failed : .done
                tasks[i].endedAt = time
                if let d = item["duration"] as? [String: Any] {
                    tasks[i].duration = ((d["secs"] as? NSNumber)?.doubleValue ?? 0) + ((d["nanos"] as? NSNumber)?.doubleValue ?? 0) / 1e9
                }
            default:
                break
            }
        default:
            break
        }
    }

    @discardableResult
    private mutating func upsertAgent(path: String, model: String?, effort: String?, thread: String?, time: Date?) -> Int {
        if let i = byPath[path] {
            if let thread, subagents[i].agentID == nil { subagents[i].agentID = thread }
            if let model, subagents[i].model == nil { subagents[i].model = model }
            return i
        }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        var a = SubagentInfo(id: path, agentID: thread, title: name.replacingOccurrences(of: "_", with: " "))
        a.model = model
        a.background = true
        a.startedAt = time
        a.activeSince = time
        byPath[path] = subagents.count
        subagents.append(a)
        return subagents.count - 1
    }

    /// Unified exec sessions still running when the call returned: code mode's JSON chunks
    /// with a session_id and no exit_code, or the classic "Process running with session ID".
    static func runningSessions(in text: String) -> [String] {
        var ids: [String] = []
        if let re = try? NSRegularExpression(pattern: #"Process running with session ID (\d+)"#) {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) { ids.append(String(text[r])) }
            }
        }
        guard text.contains("session_id") else { return ids }
        // Each chunk is its own JSON object; split on the boundaries between them.
        for chunk in text.components(separatedBy: "{\"chunk_id\"").dropFirst() where !chunk.contains("\"exit_code\"") {
            if let r = chunk.range(of: #""session_id":(\d+)"#, options: .regularExpression) {
                ids.append(String(chunk[r].dropFirst("\"session_id\":".count)))
            }
        }
        return ids
    }

    static func outputText(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let items = v as? [[String: Any]] { return items.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        if let o = v as? [String: Any], let s = o["content"] as? String { return s }
        return ""
    }

    static func json(_ s: String?) -> [String: Any] {
        guard let s, let d = s.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
        return o
    }

    static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
}

/// A Codex subagent's own rollout: its turns, its tools and its final message.
struct CodexChildParser: Equatable {
    var running: Bool?
    var aborted = false
    var step: String?
    var lastMessage: String?
    var duration: TimeInterval?
    var endedAt: Date?
    var activeSince: Date?
    var nickname: String?
    var role: String?

    mutating func consume(_ obj: [String: Any]) {
        guard let type = obj["type"] as? String, let p = obj["payload"] as? [String: Any] else { return }
        let time = WorkTime.parse(obj["timestamp"])
        switch (type, p["type"] as? String) {
        case ("session_meta", _):
            nickname = p["agent_nickname"] as? String
            role = ((p["source"] as? [String: Any])?["subagent"] as? [String: Any]).flatMap { ($0["thread_spawn"] as? [String: Any])?["agent_role"] as? String }
        case ("event_msg", "task_started"):
            running = true
            aborted = false
            activeSince = time
            step = nil
        case ("event_msg", "task_complete"):
            running = false
            endedAt = time
            if let m = p["last_agent_message"] as? String, !m.isEmpty { lastMessage = m }
            if let ms = (p["duration_ms"] as? NSNumber)?.doubleValue ?? (p["duration_ms"] as? String).flatMap(Double.init) { duration = ms / 1000 }
        case ("event_msg", "turn_aborted"):
            running = false
            aborted = true
            endedAt = time
        case ("response_item", "function_call"), ("response_item", "custom_tool_call"), ("response_item", "local_shell_call"):
            if (p["namespace"] as? String) == "collaboration" { return }
            step = CodexRolloutStatus.codexCall(p, cwd: nil).workingText
        case ("response_item", "message"):
            if p["role"] as? String == "assistant",
               let text = ((p["content"] as? [[String: Any]]) ?? []).compactMap({ $0["text"] as? String }).joined(separator: "\n").nilIfBlank {
                lastMessage = text
            }
        default:
            break
        }
    }
}

extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
