import Foundation

/// Adds what the chat's own transcript can't say: what each running subagent is doing now,
/// reports that only live in a subagent's own transcript, agents that subagents started, and
/// Codex subagents' own rollouts.
///
/// Every file is only read, and only its new part: running agents are followed from the end
/// of their transcript, and a finished agent's report is read once from the last few hundred
/// kilobytes. The subagents folder is worked out from the chat's transcript path on every
/// update, so a chat that switches session (/resume, /clear) follows along.
///
/// Not thread safe: ReviewCenter only calls it on its own queue.
final class AgentWorkTracker {
    static let tailBytes: UInt64 = 256 * 1024
    /// One-shot report reads per update, so a chat with a long history doesn't stall the first refresh.
    static let reportReadsPerUpdate = 6

    private var folder: URL?
    private var metas: [String: SubagentMeta] = [:]
    private var tails: [String: (tail: LineTail, parser: SubagentTailParser)] = [:]
    private var reports: [String: String] = [:]
    private var prompts: [String: String] = [:]
    private var codexFiles: [String: URL] = [:]
    private var codexLookups: [String: Date] = [:]
    private var codexTails: [String: (tail: LineTail, parser: CodexChildParser)] = [:]
    private var codexWork: [String: CodexWorkParser] = [:]
    var codexRoot: URL = Paths.codexSessions
    private(set) var hasOpenSubagents = false

    /// `processStart` is when the chat's agent process started, or nil once it has ended.
    func update(_ base: AgentWork, transcript: URL, kind: TranscriptKind, processStart: Date?, now: Date = Date(), sidebarOnly: Bool = false) -> AgentWork {
        var out: AgentWork
        switch kind {
        case .claude: out = claude(base, transcript: transcript, sidebarOnly: sidebarOnly)
        case .codex: out = codex(base, transcript: transcript, sidebarOnly: sidebarOnly)
        }
        // The same rules the sidebar's status uses, so the two never disagree.
        BackgroundRules.settle(&out, transcript: transcript, processStart: processStart, now: now)
        hasOpenSubagents = out.subagents.contains { $0.state.isActive }
        return out
    }

    // MARK: Claude Code

    private func claude(_ base: AgentWork, transcript: URL, sidebarOnly: Bool) -> AgentWork {
        let dir = transcript.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        if dir != folder {
            folder = dir
            metas = [:]
            tails = [:]
            reports = [:]
            prompts = [:]
        }
        readMetas(dir)

        var agents = base.subagents
        var byToolUse: [String: SubagentMeta] = [:]
        for m in metas.values { if let t = m.toolUseID { byToolUse[t] = m } }
        for i in agents.indices {
            guard let m = byToolUse[agents[i].id] else { continue }
            if agents[i].agentID == nil { agents[i].agentID = m.agentID }
            if agents[i].type == nil { agents[i].type = m.agentType }
            if agents[i].model == nil { agents[i].model = m.model }
        }

        // Agents that subagents started: only their meta files and transcripts know about them.
        var idForAgent: [String: String] = [:]
        for a in agents { if let id = a.agentID { idForAgent[id] = a.id } }
        let nested = metas.values.filter { $0.parentAgentID != nil && idForAgent[$0.agentID] == nil }
        for m in nested { idForAgent[m.agentID] = "agent-\(m.agentID)" }
        let fm = FileManager.default
        var nestedInfos: [SubagentInfo] = []
        for m in nested {
            let file = dir.appendingPathComponent("agent-\(m.agentID).jsonl")
            let attrs = try? fm.attributesOfItem(atPath: file.path)
            var a = SubagentInfo(id: "agent-\(m.agentID)", agentID: m.agentID, title: m.description ?? m.agentType ?? "Agent")
            a.parentID = m.parentAgentID.flatMap { idForAgent[$0] }
            a.type = m.agentType
            a.model = m.model
            a.background = m.background
            a.startedAt = attrs?[.creationDate] as? Date
            a.activeSince = a.startedAt
            a.state = m.finished ? .done : .running
            if m.finished { a.endedAt = attrs?[.modificationDate] as? Date }
            nestedInfos.append(a)
        }
        nestedInfos.sort { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        agents += nestedInfos

        var reads = 0
        for i in agents.indices {
            guard let aid = agents[i].agentID else { continue }
            let file = dir.appendingPathComponent("agent-\(aid).jsonl")
            guard fm.fileExists(atPath: file.path) else { continue }
            agents[i].transcript = file.path
            if agents[i].state.isActive {
                var entry = tails[aid] ?? (LineTail(url: file, from: .lastBytes(Self.tailBytes)), SubagentTailParser())
                for line in entry.tail.read(limit: 4 << 20) {
                    if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { entry.parser.consume(obj) }
                }
                tails[aid] = entry
                if agents[i].state == .running { agents[i].step = entry.parser.step }
                // A nested agent's meta can lag; its own handback says it's finished.
                if agents[i].parentID != nil, entry.parser.handback != nil, entry.parser.endedTurn {
                    agents[i].state = .done
                    agents[i].endedAt = entry.parser.lastActivity
                }
                if !sidebarOnly, agents[i].prompt == nil { agents[i].prompt = prompt(aid, file: file) }
            } else {
                if sidebarOnly { tails[aid] = nil; continue }
                if let entry = tails.removeValue(forKey: aid), let r = entry.parser.report { reports[aid] = r }
                if agents[i].result == nil {
                    if reports[aid] == nil, reads < Self.reportReadsPerUpdate {
                        reads += 1
                        reports[aid] = Self.readReport(file) ?? ""
                    }
                    if let r = reports[aid], !r.isEmpty { agents[i].result = r }
                }
                if agents[i].prompt == nil, agents[i].parentID != nil { agents[i].prompt = prompt(aid, file: file) }
            }
        }

        // A finished agent has no live children: Claude Code only reports it finished once
        // they're done.
        let finished = Set(agents.filter { !$0.state.isActive }.map(\.id))
        for i in agents.indices where agents[i].state.isActive && agents[i].parentID != nil {
            var p = agents[i].parentID
            var hops = 0
            while let pid = p, hops < 8 {
                if finished.contains(pid) {
                    agents[i].state = .done
                    agents[i].step = nil
                    break
                }
                p = agents.first { $0.id == pid }?.parentID
                hops += 1
            }
        }
        return AgentWork(subagents: agents, tasks: base.tasks)
    }

    private func readMetas(_ dir: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix("agent-") && name.hasSuffix(".meta.json") {
            let id = String(name.dropFirst("agent-".count).dropLast(".meta.json".count))
            if let m = metas[id], m.finished { continue }
            if let m = SubagentMeta.read(dir.appendingPathComponent(name)) { metas[id] = m }
        }
    }

    private func prompt(_ id: String, file: URL) -> String? {
        if let p = prompts[id] { return p.isEmpty ? nil : p }
        let p = Self.readPrompt(file) ?? ""
        prompts[id] = p
        return p.isEmpty ? nil : p
    }

    /// The subagent's handback, or else its last message, from the end of its transcript.
    static func readReport(_ file: URL) -> String? {
        let tail = LineTail(url: file, from: .lastBytes(tailBytes))
        var parser = SubagentTailParser()
        for line in tail.read(limit: Int(tailBytes) + 1) {
            if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { parser.consume(obj) }
        }
        return parser.report
    }

    /// The task a subagent was given: the first line of its transcript.
    static func readPrompt(_ file: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        let chunk = (try? h.read(upToCount: 512 * 1024)) ?? Data()
        guard let nl = chunk.firstIndex(of: 0x0A),
              let obj = (try? JSONSerialization.jsonObject(with: chunk[..<nl])) as? [String: Any],
              let msg = obj["message"] as? [String: Any] else { return nil }
        if let s = msg["content"] as? String { return s }
        return ClaudeTranscriptParser.textOf(msg["content"])
    }

    // MARK: Codex

    private func codex(_ base: AgentWork, transcript: URL, sidebarOnly: Bool) -> AgentWork {
        var agents = base.subagents
        var index = 0
        var seen = Set(agents.map(\.id))
        // Read a child's work from the same tail as its status, including its own children.
        while index < agents.count, index < 512 {
            let i = index
            index += 1
            guard let thread = agents[i].agentID else { continue }
            if sidebarOnly, !agents[i].state.isActive {
                agents[i].transcript = codexFiles[thread]?.path
                if agents[i].state == .done, let work = codexWork[thread] {
                    for var child in work.work.subagents where seen.insert(child.id).inserted {
                        child.parentID = agents[i].id
                        agents.append(child)
                    }
                }
                continue
            }
            if codexFiles[thread] == nil {
                // A new rollout can take a moment to appear; look again every few seconds.
                if let last = codexLookups[thread], Date().timeIntervalSince(last) < 5 { continue }
                codexLookups[thread] = Date()
                guard let url = Self.locateCodexRollout(thread: thread, near: agents[i].startedAt ?? Date(), root: codexRoot) else { continue }
                codexFiles[thread] = url
                var parser = CodexChildParser()
                if let meta = Self.firstLine(url) { parser.consume(meta) }
                codexTails[thread] = (LineTail(url: url, from: .lastBytes(1 << 20)), parser)
            }
            guard let url = codexFiles[thread], var entry = codexTails[thread] else { continue }
            agents[i].transcript = url.path
            var work = codexWork[thread] ?? CodexWorkParser()
            for line in entry.tail.read(limit: 4 << 20) {
                if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                    entry.parser.consume(obj)
                    work.consume(obj)
                }
            }
            codexWork[thread] = work
            codexTails[thread] = entry
            for var child in work.work.subagents where seen.insert(child.id).inserted {
                child.parentID = agents[i].id
                agents.append(child)
            }
            let c = entry.parser
            if agents[i].type == nil { agents[i].type = c.role ?? c.nickname }
            if let running = c.running {
                agents[i].state = running ? .running : (c.aborted ? .stopped : .done)
                if running {
                    agents[i].step = c.step
                    agents[i].activeSince = c.activeSince ?? agents[i].activeSince
                    agents[i].endedAt = nil
                    agents[i].duration = nil
                } else {
                    agents[i].step = nil
                    agents[i].endedAt = c.endedAt ?? agents[i].endedAt
                    agents[i].duration = c.duration
                }
            }
            if let m = c.lastMessage { agents[i].result = m }
        }
        // A completed turn can still be waiting on children it started.
        for _ in 0..<agents.count {
            var changed = false
            for i in agents.indices where agents[i].state == .done {
                if agents.contains(where: { $0.parentID == agents[i].id && $0.state.isActive }) {
                    agents[i].state = .waiting
                    agents[i].step = nil
                    changed = true
                }
            }
            if !changed { break }
        }
        return AgentWork(subagents: agents, tasks: base.tasks)
    }

    /// rollout-<local time>-<thread id>.jsonl, in the day folder of when it started or the
    /// day either side.
    static func locateCodexRollout(thread: String, near date: Date, root: URL) -> URL? {
        let fm = FileManager.default
        let cal = Calendar.current
        for offset in [0, -1, 1] {
            guard let day = cal.date(byAdding: .day, value: offset, to: date) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            if let n = names.first(where: { $0.hasPrefix("rollout-") && $0.hasSuffix("-\(thread).jsonl") }) {
                return dir.appendingPathComponent(n)
            }
        }
        return nil
    }

    static func firstLine(_ url: URL) -> [String: Any]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let chunk = (try? h.read(upToCount: 512 * 1024)) ?? Data()
        guard let nl = chunk.firstIndex(of: 0x0A) else { return nil }
        return (try? JSONSerialization.jsonObject(with: chunk[..<nl])) as? [String: Any]
    }
}
