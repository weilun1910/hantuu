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
    /// Subagents and background work, as the chat's own transcript tells it. ReviewCenter
    /// adds what the subagents' own files say (AgentWorkTracker).
    var work = AgentWork()

    var contextFraction: Double? {
        guard let used = contextUsed, let window = contextWindow, window > 0 else { return nil }
        return min(1, Double(used) / Double(window))
    }
}

/// Reads transcript lines for the Overview. Kept separate from the reader's parser so the
/// reader stays a prose view; it only ever reads the file.
struct InsightsParser {
    let kind: TranscriptKind
    private var state = SessionInsights()
    private var claudeWork = ClaudeWorkParser()
    private var codexWork = CodexWorkParser()
    private var checklist: ReaderChecklistReducer

    var insights: SessionInsights {
        var i = state
        i.work = kind == .claude ? claudeWork.work : codexWork.work
        return i
    }

    init(kind: TranscriptKind) {
        self.kind = kind
        checklist = ReaderChecklistReducer(kind: kind)
    }

    mutating func consume(_ line: Data) {
        state.plan = checklist.consume(line: line)?.items.map {
            PlanItem(id: $0.id, text: $0.text, state: PlanItem.state($0.status))
        } ?? []
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        switch kind {
        case .claude:
            claudeWork.consume(obj)
            claude(obj)
        case .codex:
            codexWork.consume(obj)
            codex(obj)
        }
    }

    // MARK: Claude Code

    private mutating func claude(_ obj: [String: Any]) {
        if obj["isSidechain"] as? Bool == true { return }
        guard let type = obj["type"] as? String, let msg = obj["message"] as? [String: Any] else { return }
        if type == "assistant" {
            if let m = msg["model"] as? String, !m.isEmpty, !m.hasPrefix("<") { state.model = m }
            if let u = msg["usage"] as? [String: Any] {
                let used = int(u["input_tokens"]) + int(u["cache_creation_input_tokens"]) + int(u["cache_read_input_tokens"])
                if used > 0 {
                    state.contextUsed = used
                    let (window, guess) = Self.claudeWindow(model: state.model, used: used)
                    state.contextWindow = window
                    state.windowIsGuess = guess
                }
            }
        }
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
            if let m = p["model"] as? String, !m.isEmpty { state.model = m }
        case ("session_meta", _):
            if state.model == nil, let m = p["model"] as? String, !m.isEmpty { state.model = m }
        case ("event_msg", "token_count"):
            guard let info = p["info"] as? [String: Any] else { return }
            if let last = info["last_token_usage"] as? [String: Any] {
                var used = int(last["total_tokens"])
                if used == 0 { used = int(last["input_tokens"]) + int(last["output_tokens"]) }
                if used > 0 { state.contextUsed = used }
            }
            if let w = info["model_context_window"] as? NSNumber, w.intValue > 0 {
                state.contextWindow = w.intValue
                state.windowIsGuess = false
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
