import Foundation

/// One item of the agent's plan or to-do list.
struct PlanItem: Equatable, Identifiable {
    enum State: String { case pending, inProgress, completed }
    var id: String
    var text: String
    var state: State

    static func state(_ raw: String?) -> State {
        switch raw?.lowercased() {
        case "completed", "done", "complete": return .completed
        case "in_progress", "in-progress", "inprogress", "active", "running": return .inProgress
        default: return .pending
        }
    }
}

/// What the Overview shows from the transcript: the model, how full the context window is,
/// and the latest plan or to-do list.
struct SessionInsights: Equatable {
    var model: String?
    var contextUsed: Int?
    var contextWindow: Int?
    var windowIsGuess = false
    var plan: [PlanItem] = []

    var contextFraction: Double? {
        guard let used = contextUsed, let window = contextWindow, window > 0 else { return nil }
        return min(1, Double(used) / Double(window))
    }
}

/// Reads transcript lines for the Overview. Kept separate from the reader's parser so the
/// reader stays a prose view; it only ever reads the file.
struct InsightsParser {
    let kind: TranscriptKind
    private(set) var insights = SessionInsights()

    // Claude's task list: TaskCreate adds, TaskUpdate changes, TodoWrite replaces.
    private var tasks: [PlanItem] = []
    private var todoWrite: [PlanItem] = []
    private var lastPlanSource = 0   // 1 = TodoWrite, 2 = tasks
    private var pendingCreates: [String: String] = [:]   // tool_use id -> subject
    private var nextTaskNumber = 1

    init(kind: TranscriptKind) { self.kind = kind }

    mutating func consume(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        switch kind {
        case .claude: claude(obj)
        case .codex: codex(obj)
        }
    }

    // MARK: Claude Code

    private mutating func claude(_ obj: [String: Any]) {
        if obj["isSidechain"] as? Bool == true { return }
        guard let type = obj["type"] as? String, let msg = obj["message"] as? [String: Any] else { return }
        if type == "assistant" {
            if let m = msg["model"] as? String, !m.isEmpty, !m.hasPrefix("<") { insights.model = m }
            if let u = msg["usage"] as? [String: Any] {
                let used = int(u["input_tokens"]) + int(u["cache_creation_input_tokens"]) + int(u["cache_read_input_tokens"])
                if used > 0 {
                    insights.contextUsed = used
                    let (window, guess) = Self.claudeWindow(model: insights.model, used: used)
                    insights.contextWindow = window
                    insights.windowIsGuess = guess
                }
            }
            for item in (msg["content"] as? [[String: Any]]) ?? [] where item["type"] as? String == "tool_use" {
                let input = item["input"] as? [String: Any] ?? [:]
                switch item["name"] as? String {
                case "TodoWrite":
                    let todos = (input["todos"] as? [[String: Any]]) ?? []
                    todoWrite = todos.enumerated().map { i, t in
                        PlanItem(id: (t["id"] as? String) ?? "t\(i)", text: (t["content"] as? String) ?? "", state: PlanItem.state(t["status"] as? String))
                    }
                    lastPlanSource = 1
                case "TaskCreate":
                    if let id = item["id"] as? String {
                        pendingCreates[id] = (input["subject"] as? String) ?? (input["description"] as? String) ?? "Task"
                    }
                case "TaskUpdate":
                    guard let tid = Self.string(input["taskId"]) else { break }
                    if let i = tasks.firstIndex(where: { $0.id == tid }) {
                        if let s = input["status"] as? String {
                            if s == "deleted" { tasks.remove(at: i) } else { tasks[i].state = PlanItem.state(s) }
                        }
                        if let subj = input["subject"] as? String, !subj.isEmpty, i < tasks.count, tasks[i].id == tid { tasks[i].text = subj }
                    }
                    lastPlanSource = 2
                default:
                    break
                }
            }
        } else if type == "user" {
            for item in (msg["content"] as? [[String: Any]]) ?? [] where item["type"] as? String == "tool_result" {
                guard let useID = item["tool_use_id"] as? String, let subject = pendingCreates.removeValue(forKey: useID) else { continue }
                if item["is_error"] as? Bool == true { continue }
                let text = ClaudeTranscriptParser.textOf(item["content"]) ?? ""
                var tid = String(nextTaskNumber)
                if let r = text.range(of: #"Task #(\S+) created"#, options: .regularExpression) {
                    tid = String(text[r].dropFirst("Task #".count).dropLast(" created".count))
                }
                nextTaskNumber = (Int(tid) ?? nextTaskNumber) + 1
                tasks.append(PlanItem(id: tid, text: subject, state: .pending))
                lastPlanSource = 2
            }
        }
        insights.plan = lastPlanSource == 2 ? tasks : todoWrite
    }

    /// Claude Code's transcript doesn't record the window size, so it's a guess: 200k, or 1M
    /// for a 1M-context model or once usage has gone past 200k.
    static func claudeWindow(model: String?, used: Int) -> (Int, Bool) {
        let m = (model ?? "").lowercased()
        if m.contains("[1m]") || m.hasSuffix("-1m") || used > 200_000 { return (1_000_000, true) }
        return (200_000, true)
    }

    // MARK: Codex

    private mutating func codex(_ obj: [String: Any]) {
        guard let type = obj["type"] as? String, let p = obj["payload"] as? [String: Any] else { return }
        switch (type, p["type"] as? String) {
        case ("turn_context", _):
            if let m = p["model"] as? String, !m.isEmpty { insights.model = m }
        case ("session_meta", _):
            if insights.model == nil, let m = p["model"] as? String, !m.isEmpty { insights.model = m }
        case ("event_msg", "token_count"):
            guard let info = p["info"] as? [String: Any] else { return }
            if let last = info["last_token_usage"] as? [String: Any] {
                var used = int(last["total_tokens"])
                if used == 0 { used = int(last["input_tokens"]) + int(last["output_tokens"]) }
                if used > 0 { insights.contextUsed = used }
            }
            if let w = info["model_context_window"] as? NSNumber, w.intValue > 0 {
                insights.contextWindow = w.intValue
                insights.windowIsGuess = false
            }
        case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
            guard (p["name"] as? String) == "update_plan" else { return }
            let raw = (p["arguments"] as? String) ?? (p["input"] as? String) ?? ""
            guard let d = raw.data(using: .utf8), let args = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let plan = args["plan"] as? [[String: Any]] else { return }
            insights.plan = plan.enumerated().map { i, s in
                PlanItem(id: "p\(i)", text: (s["step"] as? String) ?? "", state: PlanItem.state(s["status"] as? String))
            }
        default:
            break
        }
    }

    private func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
    private static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
}

/// Tails a transcript for the Overview, reading only what was appended since the last poll.
final class InsightsFollower {
    let url: URL
    private var parser: InsightsParser
    private var offset: UInt64 = 0
    private var partial = Data()

    init(url: URL, kind: TranscriptKind) {
        self.url = url
        parser = InsightsParser(kind: kind)
    }

    func poll() -> SessionInsights {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return parser.insights }
        if size < offset {
            offset = 0
            partial = Data()
            parser = InsightsParser(kind: parser.kind)
        }
        guard size > offset, let h = try? FileHandle(forReadingFrom: url) else { return parser.insights }
        defer { try? h.close() }
        do { try h.seek(toOffset: offset) } catch { return parser.insights }
        let data = (try? h.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        let buf = partial + data
        var start = buf.startIndex
        while let nl = buf[start...].firstIndex(of: 0x0A) {
            if nl > start { parser.consume(Data(buf[start..<nl])) }
            start = buf.index(after: nl)
        }
        partial = Data(buf[start...])
        return parser.insights
    }
}
