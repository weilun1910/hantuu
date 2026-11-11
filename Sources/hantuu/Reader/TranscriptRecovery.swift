import Foundation

/// Discovery uses injectable roots so fixture checks never inspect the user's agents.
struct TranscriptLocations {
    var claude = Paths.claudeProjects
    var codex = Paths.codexSessions
}

/// A cheap file stat runs each tick. Directory searches only run when recovery is due.
struct TranscriptRecoveryPolicy {
    private var size: UInt64?
    private var lastGrowth: Date?
    private var workingSince: Date?
    private var lastLookup: Date?
    private var didInitialLookup = false

    mutating func shouldLookup(now: Date, fileSize: UInt64?, hasFollower: Bool, working: Bool) -> Bool {
        if fileSize != size {
            size = fileSize
            lastGrowth = now
        }
        if working {
            if workingSince == nil { workingSince = now }
        } else {
            workingSince = nil
        }
        let missing = !hasFollower || fileSize == nil
        let stalled = workingSince.map { now.timeIntervalSince(max($0, lastGrowth ?? $0)) >= 5 } ?? false
        if !didInitialLookup {
            didInitialLookup = true
            lastLookup = missing ? now : nil
            return true
        }
        guard missing || stalled else { return false }
        let delay: TimeInterval = missing ? 10 : 30
        if let lastLookup, now.timeIntervalSince(lastLookup) < delay { return false }
        lastLookup = now
        return true
    }
}

final class TranscriptRecovery {
    var policy = TranscriptRecoveryPolicy()
    var pending = false
    var processID: Int32?
    var lastProcessLookup: Date?
    let processRollouts = CodexRolloutSelection()
    let events: LineTail
    let queue = DispatchQueue(label: "hantuu.transcript-discovery", qos: .utility)

    init(events: URL, replay: Bool) {
        self.events = LineTail(url: events, from: replay ? .lastBytes(256 * 1024) : .end)
    }
}

enum TranscriptLookup {
    struct Request {
        var kind: TranscriptKind
        var sessionID: String?
        var path: String?
        var cwd: String
        var startedAt: Date
        var excluded: Set<String>
        var roots: TranscriptLocations
    }

    /// Looks up the saved identity first, then lets newer hook metadata correct it.
    /// A known ID is never replaced by an unrelated chat in the same working folder.
    static func find(_ request: Request, events: [Data]) -> HookLineParser.Session? {
        if request.kind == .codex { return findCodex(request, events: events) }
        var id = request.sessionID
        var path = existing(request.path)
        if path == nil, let id { path = locate(id, request: request)?.path }
        var signalled = false
        for line in events {
            guard let next = HookLineParser.session(line) else { continue }
            let changed = next.id != nil && next.id != id
            if changed { path = nil }
            id = next.id ?? id
            path = next.path ?? path
            signalled = true
        }
        if path == nil, let id { path = locate(id, request: request)?.path }
        guard path != nil || signalled else { return nil }
        return HookLineParser.Session(id: id, path: path)
    }

    private static func findCodex(_ request: Request, events: [Data]) -> HookLineParser.Session? {
        // Keep the attached history when an ID cannot be resolved. Completion notifications
        // can name a subagent, and a failed lookup is not evidence that the reader is wrong.
        var result: HookLineParser.Session?
        if let path = existing(request.path) {
            let meta = CodexTranscriptParser.readMeta(URL(fileURLWithPath: path))
            result = HookLineParser.Session(id: meta?.id ?? request.sessionID, path: path)
        }
        if let id = request.sessionID, result?.id != id || result == nil,
           let resolved = validatedCodexSession(.init(id: id, path: nil), root: request.roots.codex) {
            result = resolved
        }
        // Only a fully validated main-agent transcript may replace a working attachment.
        for line in events.reversed() {
            guard let next = codexSession(line),
                  let resolved = validatedCodexSession(next, root: request.roots.codex) else { continue }
            result = resolved
            break
        }
        if result == nil, request.sessionID == nil,
           let found = CodexTranscriptParser.locate(cwd: request.cwd, after: request.startedAt,
                                                    excluding: request.excluded, root: request.roots.codex) {
            result = HookLineParser.Session(id: found.1.id, path: found.0.path)
        }
        return result
    }

    static func validatedCodexSession(_ session: HookLineParser.Session, root: URL) -> HookLineParser.Session? {
        if let path = session.path, let meta = CodexTranscriptParser.readMeta(URL(fileURLWithPath: path)),
           session.id == nil || session.id == meta.id {
            return HookLineParser.Session(id: meta.id, path: path)
        }
        guard let id = session.id, let url = codex(sessionID: id, root: root) else { return nil }
        return HookLineParser.Session(id: id, path: url.path)
    }

    static func codexSession(_ line: Data) -> HookLineParser.Session? {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              obj["type"] as? String == "agent-turn-complete",
              let id = obj["thread-id"] as? String, !id.isEmpty else { return nil }
        return HookLineParser.Session(id: id, path: nil)
    }

    private static func existing(_ path: String?) -> String? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    private static func locate(_ id: String, request: Request) -> URL? {
        switch request.kind {
        case .claude:
            return ClaudeTranscriptParser.locate(sessionID: id, cwd: request.cwd, root: request.roots.claude)
        case .codex:
            return codex(sessionID: id, root: request.roots.codex)
        }
    }

    /// Resumed rollouts can be months old. Match the filename before reading any metadata.
    static func codex(sessionID: String, root: URL) -> URL? {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in files where url.lastPathComponent.hasPrefix("rollout-")
            && url.lastPathComponent.hasSuffix("-\(sessionID).jsonl") {
            guard CodexTranscriptParser.readMeta(url)?.id == sessionID else { continue }
            return url
        }
        return nil
    }
}
