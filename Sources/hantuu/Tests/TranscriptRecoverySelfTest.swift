import Foundation

extension SelfTest {
    static func transcriptRecovery(_ dir: URL) {
        let folder = dir.appendingPathComponent("transcript-recovery")
        let claudeRoot = folder.appendingPathComponent("claude")
        let codexRoot = folder.appendingPathComponent("codex")
        let project = Project(path: folder.path)
        let model = AppModel()
        model.projects = [project]
        model.transcriptLocations = TranscriptLocations(claude: claudeRoot, codex: codexRoot)
        Paths.ensure(folder)

        func line(_ object: [String: Any]) -> Data {
            try! JSONSerialization.data(withJSONObject: object) + Data([0x0A])
        }
        func message(_ kind: TranscriptKind, _ text: String, role: String = "user") -> Data {
            if kind == .claude {
                return line(["type": role, "uuid": UUID().uuidString,
                             "message": ["role": role, "content": text]])
            }
            return line(["type": "response_item", "payload": ["type": "message", "role": role,
                         "content": [["type": role == "user" ? "input_text" : "output_text", "text": text]]]])
        }
        func append(_ data: Data, to url: URL) {
            let handle = try! FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(data)
            try! handle.close()
        }
        func rollout(_ id: String, parent: Bool = false) -> URL {
            let day = codexRoot.appendingPathComponent("2020/01/02")
            Paths.ensure(day)
            let url = day.appendingPathComponent("rollout-2020-01-02T10-00-00-\(id).jsonl")
            var meta: [String: Any] = ["id": id, "cwd": folder.path, "timestamp": "2020-01-02T10:00:00Z"]
            if parent { meta["parent_thread_id"] = "parent" }
            try! line(["type": "session_meta", "payload": meta]).write(to: url)
            append(message(.codex, "Old \(id) turn"), to: url)
            return url
        }
        func restored(_ kind: TranscriptKind, id: String, running: Bool = true) -> Chat {
            // Decode the same durable fields load() uses, with no saved transcript path.
            let saved = SavedChat(id: UUID(), projectID: project.id, agentID: kind.rawValue,
                                  sessionID: id, title: "Restored chat", firstPrompt: nil,
                                  transcriptPath: nil, createdAt: Date(timeIntervalSince1970: 1),
                                  worktree: nil, pinnedAt: nil)
            let decoded = try! JSONDecoder().decode(SavedChat.self, from: JSONEncoder().encode(saved))
            let chat = Chat(id: decoded.id, projectID: decoded.projectID, agentID: decoded.agentID,
                            createdAt: decoded.createdAt)
            chat.sessionID = decoded.sessionID
            chat.status = running ? .running : .ended
            // Even an incorrect new process time must not hide an existing saved session.
            chat.startedAt = Date()
            model.chats.append(chat)
            model.beginTranscriptDiscovery(chat, cwd: folder.path, replayEvents: true)
            return chat
        }
        defer {
            for chat in model.chats {
                chat.discoveryTimer?.invalidate()
                chat.transcriptRecovery = nil
                chat.follower?.stop()
            }
        }

        let codexFile = rollout("saved-codex")
        let codex = restored(.codex, id: "saved-codex")
        check("reader recovery: reattached Codex finds an old rollout by saved ID",
              waitUntil(5) { codex.allEntries.map(\.text) == ["Old saved-codex turn"] }
              && codex.transcriptPath == codexFile.path)
        append(message(.codex, "New question") + message(.codex, "New answer", role: "assistant"), to: codexFile)
        check("reader recovery: reattached Codex follows both sides of the next turn",
              waitUntil(5) { codex.allEntries.map(\.text) == ["Old saved-codex turn", "New question", "New answer"] })

        let claudeFolder = claudeRoot.appendingPathComponent(ClaudeTranscriptParser.projectFolderName(for: folder.path))
        Paths.ensure(claudeFolder)
        let claudeFile = claudeFolder.appendingPathComponent("saved-claude.jsonl")
        try! message(.claude, "Old Claude turn").write(to: claudeFile)
        let claude = restored(.claude, id: "saved-claude")
        check("reader recovery: reattached Claude finds its saved session without a new startup hook",
              waitUntil(5) { claude.allEntries.map(\.text) == ["Old Claude turn"] })
        append(message(.claude, "Claude question") + message(.claude, "Claude answer", role: "assistant"), to: claudeFile)
        check("reader recovery: reattached Claude follows both sides of the next turn",
              waitUntil(5) { claude.allEntries.map(\.text) == ["Old Claude turn", "Claude question", "Claude answer"] })

        let ended = restored(.codex, id: "saved-codex", running: false)
        check("reader recovery: an ended chat also resolves its saved ID without a path",
              waitUntil(5) { ended.allEntries.count == 3 } && ended.status == .ended
              && ended.follower?.isFollowing == false && ended.discoveryTimer == nil)

        // Restart the same follower, as both reattach and Resume Chat now do.
        let original = codex.follower
        original?.stop()
        append(message(.codex, "While detached"), to: codexFile)
        model.beginTranscriptDiscovery(codex, cwd: folder.path, replayEvents: true)
        check("reader recovery: restart keeps the follower and adds history exactly once",
              waitUntil(5) { codex.allEntries.count == 4 } && codex.follower === original
              && codex.allEntries.last?.text == "While detached")

        // Codex /resume supplies its thread ID on completion, including for old rollouts.
        let resumedFile = rollout("resumed-codex")
        let center = StatusCenter()
        center.notifier = NoticeRecorder()
        center.start(model: model, live: false)
        let eventFile = AgentHooks.eventsFile(for: codex.id)
        try! line(["type": "agent-turn-complete", "thread-id": "resumed-codex", "turn-id": "turn"])
            .write(to: eventFile)
        center.poll()
        check("reader recovery: Codex notify switches the reader to a resumed old session",
              waitUntil(5) { codex.sessionID == "resumed-codex" && codex.transcriptPath == resumedFile.path
                  && codex.allEntries.map(\.text) == ["Old resumed-codex turn"] })
        append(message(.codex, "Resumed next turn"), to: resumedFile)
        check("reader recovery: the switched Codex follower keeps growing",
              waitUntil(5) { codex.allEntries.count == 2 })

        let stalePath = TranscriptLookup.Request(kind: .codex, sessionID: "resumed-codex", path: codexFile.path,
                                                cwd: folder.path, startedAt: Date(), excluded: [resumedFile.path],
                                                roots: model.transcriptLocations)
        check("reader recovery: saved ID wins over a stale path and its own earlier claim",
              TranscriptLookup.find(stalePath, events: [])?.path == resumedFile.path)
        let staleID = TranscriptLookup.Request(kind: .codex, sessionID: "saved-codex", path: codexFile.path,
                                              cwd: folder.path, startedAt: Date(), excluded: [],
                                              roots: model.transcriptLocations)
        check("reader recovery: replayed notify metadata corrects a stale saved ID",
              TranscriptLookup.find(staleID, events: [line(["type": "agent-turn-complete", "thread-id": "resumed-codex"])])
                == HookLineParser.Session(id: "resumed-codex", path: resumedFile.path))

        let childFile = rollout("child-codex", parent: true)
        check("reader recovery: exact-ID lookup rejects subagent rollouts",
              TranscriptLookup.codex(sessionID: "child-codex", root: codexRoot) == nil
              && FileManager.default.fileExists(atPath: childFile.path))
        let request = TranscriptLookup.Request(kind: .codex, sessionID: "missing-id", path: nil,
                                              cwd: folder.path, startedAt: .distantPast, excluded: [],
                                              roots: model.transcriptLocations)
        check("reader recovery: a missing known ID cannot steal a neighboring chat",
              TranscriptLookup.find(request, events: []) == nil)

        // Quiet working chats get a lookup even when their follower is still scheduled.
        _ = waitUntil(5) { codex.transcriptRecovery?.pending == false }
        codex.discoveryTimer?.invalidate()
        codex.activity = .working
        codex.transcriptRecovery?.policy = TranscriptRecoveryPolicy()
        let now = Date()
        model.checkTranscriptRecovery(codex, cwd: folder.path, now: now)
        _ = waitUntil(5) { codex.transcriptRecovery?.pending == false }
        let before = codex.follower
        model.checkTranscriptRecovery(codex, cwd: folder.path, now: now.addingTimeInterval(6))
        check("reader recovery: a working chat with a stalled file triggers another lookup",
              codex.transcriptRecovery?.pending == true)
        _ = waitUntil(5) { codex.transcriptRecovery?.pending == false }
        append(message(.codex, "After watchdog recovery"), to: resumedFile)
        check("reader recovery: watchdog restarts following without duplicating history",
              waitUntil(5) { codex.allEntries.count == 3 } && codex.follower === before
              && codex.allEntries.last?.text == "After watchdog recovery")

        codex.follower?.stop()
        codex.activity = .idle
        append(message(.codex, "Written while follower stopped"), to: resumedFile)
        model.checkTranscriptRecovery(codex, cwd: folder.path, now: now.addingTimeInterval(40))
        check("reader recovery: a stopped follower recovers even if its file grows and work finishes",
              waitUntil(5) { codex.allEntries.count == 4 } && codex.follower === before
              && codex.follower?.isFollowing == true)

        var policy = TranscriptRecoveryPolicy()
        check("reader recovery: an attached file gets one initial lookup",
              policy.shouldLookup(now: now, fileSize: 100, hasFollower: true, working: true))
        check("reader recovery: a brief quiet period does not trigger a scan",
              !policy.shouldLookup(now: now.addingTimeInterval(4), fileSize: 100, hasFollower: true, working: true))
        check("reader recovery: stalled work is checked after five seconds",
              policy.shouldLookup(now: now.addingTimeInterval(6), fileSize: 100, hasFollower: true, working: true))
        check("reader recovery: repeated stalled lookups are throttled",
              !policy.shouldLookup(now: now.addingTimeInterval(7), fileSize: 100, hasFollower: true, working: true))
        check("reader recovery: growing files do not trigger scans",
              !policy.shouldLookup(now: now.addingTimeInterval(40), fileSize: 200, hasFollower: true, working: true))
        check("reader recovery: idle files do not trigger scans",
              !policy.shouldLookup(now: now.addingTimeInterval(60), fileSize: 200, hasFollower: true, working: false))
        var missing = TranscriptRecoveryPolicy()
        _ = missing.shouldLookup(now: now, fileSize: nil, hasFollower: false, working: false)
        check("reader recovery: missing files retry at ten seconds, not on every tick",
              !missing.shouldLookup(now: now.addingTimeInterval(1), fileSize: nil, hasFollower: false, working: false)
              && missing.shouldLookup(now: now.addingTimeInterval(10), fileSize: nil, hasFollower: false, working: false))
    }
}
