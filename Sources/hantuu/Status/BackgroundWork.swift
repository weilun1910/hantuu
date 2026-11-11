import Foundation

/// What a chat's background work means for its status: how many subagents and background
/// tasks are still running, a line saying so, and when the last one ended.
struct BackgroundSummary: Equatable {
    var agents = 0
    var tasks = 0
    var detail = ""
    /// When the last piece of background work ended, for "Done Xm ago".
    var endedAt: Date?
    /// When the transcript was read for this summary. A turn that ended before then can be
    /// trusted to see the agents it started.
    var checkedAt: Date?

    var count: Int { agents + tasks }

    static func of(_ work: AgentWork) -> BackgroundSummary {
        // Agents that subagents started are part of their parent's work.
        let agents = work.subagents.filter { $0.parentID == nil && $0.state.isActive }
        let tasks = work.tasks.filter { $0.state.isActive }
        var s = BackgroundSummary(agents: agents.count, tasks: tasks.count)
        func plural(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }
        switch (agents.count, tasks.count) {
        case (0, 0): s.detail = ""
        case (1, 0): s.detail = "Running in background: " + ToolCall.oneLine(agents[0].title)
        case (0, 1): s.detail = "Running in background: " + ToolCall.oneLine(tasks[0].title)
        case (_, 0): s.detail = "\(agents.count) agents running in background"
        case (0, _): s.detail = "\(tasks.count) tasks running in background"
        default: s.detail = "\(plural(agents.count, "agent")) and \(plural(tasks.count, "task")) running in background"
        }
        let ends = work.subagents.filter { $0.parentID == nil && !$0.state.isActive }.compactMap { $0.endedAt ?? $0.lastUpdate }
            + work.tasks.filter { !$0.state.isActive }.compactMap { $0.endedAt ?? $0.lastUpdate }
        s.endedAt = ends.max()
        return s
    }
}

/// Decides which work can't still be running, the same way for the sidebar and the Overview.
enum BackgroundRules {
    /// A background command or terminal whose output hasn't grown for this long, and that
    /// never reported back, no longer counts as running.
    static let quietTask: TimeInterval = 30 * 60
    /// The same for an agent whose transcript hasn't grown. Agents write a line for every
    /// step, so this can be longer without hiding real work.
    static let quietAgent: TimeInterval = 60 * 60
    /// Work that started this long before the agent's current process belongs to an earlier one.
    static let processSlack: TimeInterval = 30

    /// - With no process (the chat ended), nothing is still running.
    /// - Work started before the agent's current process (a resume, a restart) died with the
    ///   old one.
    /// - Work that never reported back and has been quiet too long is stale.
    static func settle(_ work: inout AgentWork, transcript: URL?, processStart: Date?, now: Date = Date()) {
        let fm = FileManager.default
        func mtime(_ path: String?) -> Date? {
            guard let path else { return nil }
            return (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        let folder = transcript.map { $0.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true) }
        var newest: Date??
        func newestInFolder() -> Date? {
            if let n = newest { return n }
            var best: Date?
            if let folder, let names = try? fm.contentsOfDirectory(atPath: folder.path) {
                for n in names where n.hasSuffix(".jsonl") {
                    if let d = mtime(folder.appendingPathComponent(n).path), best.map({ d > $0 }) ?? true { best = d }
                }
            }
            newest = .some(best)
            return best
        }

        for i in work.subagents.indices where work.subagents[i].state.isActive {
            let a = work.subagents[i]
            guard let start = processStart else {
                work.subagents[i].state = .stopped
                work.subagents[i].step = nil
                continue
            }
            let began = a.activeSince ?? a.startedAt
            if let began, began < start.addingTimeInterval(-processSlack) {
                work.subagents[i].state = .stopped
                work.subagents[i].step = nil
                continue
            }
            let file = a.transcript ?? a.agentID.flatMap { id in folder?.appendingPathComponent("agent-\(id).jsonl").path }
            var last = [began, mtime(file)].compactMap { $0 }.max()
            // Waiting on its own agents: they're the ones writing.
            if a.state == .waiting, let n = newestInFolder() { last = max(last ?? n, n) }
            if let last, now.timeIntervalSince(last) > quietAgent {
                work.subagents[i].state = .stale
                work.subagents[i].step = nil
                work.subagents[i].lastUpdate = last
            }
        }
        for i in work.tasks.indices where work.tasks[i].state.isActive {
            let t = work.tasks[i]
            guard let start = processStart else {
                work.tasks[i].state = .stopped
                continue
            }
            if let began = t.startedAt, began < start.addingTimeInterval(-processSlack) {
                work.tasks[i].state = .stopped
                continue
            }
            let last = [t.startedAt, mtime(t.outputFile)].compactMap { $0 }.max()
            if let last, now.timeIntervalSince(last) > quietTask {
                work.tasks[i].state = .stale
                work.tasks[i].lastUpdate = last
            }
        }
    }
}

/// Follows one chat's transcript for the background work it starts: only new lines are read,
/// and only lines that can matter are parsed, so a long transcript costs one quick pass.
final class WorkFollower {
    let url: URL
    let kind: TranscriptKind
    private let tail: LineTail
    private var claude = ClaudeWorkParser()
    private var codex = CodexWorkParser()

    private static let claudeMarks = [
        #""name":"Agent""#, #""name":"Task""#, #""name":"Bash""#, #""name":"PowerShell""#, #""name":"Monitor""#,
        #""name":"SendMessage""#, #""name":"TaskStop""#, #""name":"KillShell""#,
        #""agentId""#, "backgroundTaskId", "running in background with ID", "Monitor started", "resumedAgentId",
        "Resuming agent", "Successfully stopped", #""is_error":true"#, TaskNotification.marker,
    ].map { Data($0.utf8) }
    private static let codexMarks = [
        "spawn_agent", "task_name", "SubAgentActivity", "CommandExecution", "session_id", "Process running",
        #""name":"exec""#, "exec_command", #""name":"shell"#,
    ].map { Data($0.utf8) }
    private static let skip = Data(#""type":"api-request"#.utf8)

    init(url: URL, kind: TranscriptKind) {
        self.url = url
        self.kind = kind
        tail = LineTail(url: url, from: .beginning)
    }

    func poll() -> AgentWork {
        let marks = kind == .claude ? Self.claudeMarks : Self.codexMarks
        for _ in 0..<64 {
            let lines = tail.read(limit: 32 << 20)
            for line in lines where Self.matters(line, marks) {
                guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                switch kind {
                case .claude: claude.consume(obj)
                case .codex: codex.consume(obj)
                }
            }
            if tail.offset >= LineTail.size(of: url) { break }
        }
        return kind == .claude ? claude.work : codex.work
    }

    static func matters(_ line: Data, _ marks: [Data]) -> Bool {
        // The request copies Claude Code keeps hold every tool result again; the parser skips them.
        if contains(line.prefix(48), skip) { return false }
        return marks.contains { contains(line, $0) }
    }

    static func contains(_ data: Data, _ pattern: Data) -> Bool {
        data.withUnsafeBytes { d in
            pattern.withUnsafeBytes { p in
                guard let db = d.baseAddress, let pb = p.baseAddress else { return false }
                return memmem(db, d.count, pb, p.count) != nil
            }
        }
    }
}

/// Keeps every live chat's background work current for its status, on a queue of its own,
/// every couple of seconds. StatusCenter turns each summary into the chat's state.
final class BackgroundWatch {
    var interval: TimeInterval = 2
    var deliver: ((UUID, BackgroundSummary) -> Void)?
    private weak var model: AppModel?
    private let queue = DispatchQueue(label: "hantuu.background-work", qos: .utility)
    private var followers: [UUID: WorkFollower] = [:]   // on the queue only
    private var timer: Timer?
    private var busy = false

    private struct Job {
        var id: UUID
        var url: URL
        var kind: TranscriptKind
        var processStart: Date
    }

    func start(model: AppModel) {
        self.model = model
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Reads what's new for every live chat, then delivers each one's summary on the main thread.
    func tick(now: Date = Date(), completion: (() -> Void)? = nil) {
        guard !busy, let model else { completion?(); return }
        // The transcript can change during a chat's life (/resume, /clear), so it's read fresh each time.
        let jobs = model.chats.compactMap { c -> Job? in
            guard c.status != .ended, let p = c.transcriptPath, let kind = c.agent.transcript else { return nil }
            return Job(id: c.id, url: URL(fileURLWithPath: p), kind: kind, processStart: c.startedAt)
        }
        busy = true
        queue.async {
            let live = Set(jobs.map(\.id))
            self.followers = self.followers.filter { live.contains($0.key) }
            var out: [(UUID, BackgroundSummary)] = []
            for j in jobs {
                if self.followers[j.id]?.url != j.url { self.followers[j.id] = WorkFollower(url: j.url, kind: j.kind) }
                guard let f = self.followers[j.id] else { continue }
                var work = f.poll()
                BackgroundRules.settle(&work, transcript: j.url, processStart: j.processStart, now: now)
                var s = BackgroundSummary.of(work)
                s.checkedAt = now
                out.append((j.id, s))
            }
            DispatchQueue.main.async {
                self.busy = false
                for (id, s) in out { self.deliver?(id, s) }
                completion?()
            }
        }
    }
}
