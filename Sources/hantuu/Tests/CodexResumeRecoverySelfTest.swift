import Foundation

extension SelfTest {
    static func codexResumeRecovery(_ dir: URL) {
        let folder = dir.appendingPathComponent("codex-resume-regressions")
        let root = folder.appendingPathComponent("sessions")
        let archive = root.appendingPathComponent("2020/01/02")
        Paths.ensure(archive)
        let project = Project(path: folder.appendingPathComponent("Academics").path)
        let model = AppModel()
        model.projects = [project]
        model.transcriptLocations = TranscriptLocations(claude: folder.appendingPathComponent("claude"), codex: root)
        model.codexProcessID = { _ in nil }
        model.codexOpenRollouts = { _, _ in [] }
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func line(_ type: String, _ payload: [String: Any], at: Date = Date()) -> Data {
            try! JSONSerialization.data(withJSONObject: ["type": type, "timestamp": iso.string(from: at),
                                                        "payload": payload]) + Data([0x0A])
        }
        func message(_ text: String, role: String = "user") -> Data {
            line("response_item", ["type": "message", "role": role,
                                   "content": [["type": role == "user" ? "input_text" : "output_text", "text": text]]])
        }
        func append(_ data: Data, to file: URL) {
            let handle = try! FileHandle(forWritingTo: file)
            handle.seekToEndOfFile()
            handle.write(data)
            try! handle.close()
        }
        func rollout(_ id: String, child: Bool = false) -> URL {
            let file = archive.appendingPathComponent("rollout-2020-01-02T10-00-00-\(id).jsonl")
            var metadata: [String: Any] = ["id": id, "session_id": child ? "main" : id,
                "cwd": folder.path, "timestamp": "2020-01-02T10:00:00Z", "cli_version": "0.167.1",
                "originator": "codex-tui", "source": "cli", "thread_source": "user",
                "base_instructions": ["text": String(repeating: "Synthetic instructions. ", count: 1000)]]
            if child {
                // The child shares the root session_id but has its own thread id.
                metadata["source"] = ["subagent": ["thread_spawn": ["parent_thread_id": "main", "depth": 1]]]
                metadata["thread_source"] = "subagent"
            }
            try! line("session_meta", metadata, at: .distantPast).write(to: file)
            append(message("History for \(id)"), to: file)
            return file
        }
        let main = rollout("main")
        let child = rollout("child", child: true)
        let saved = SavedChat(id: UUID(), projectID: project.id, agentID: "codex", sessionID: "main",
                              title: "Saved conversation", firstPrompt: nil, transcriptPath: main.path,
                              createdAt: .distantPast, worktree: nil, pinnedAt: nil)
        let decoded = try! JSONDecoder().decode(SavedChat.self, from: JSONEncoder().encode(saved))
        let chat = Chat(id: decoded.id, projectID: decoded.projectID, agentID: decoded.agentID)
        chat.sessionID = decoded.sessionID
        chat.transcriptPath = decoded.transcriptPath
        chat.startedAt = now
        model.chats = [chat]
        defer {
            for chat in model.chats {
                chat.discoveryTimer?.invalidate()
                chat.transcriptRecovery = nil
                chat.codexSessionRequest = nil
                chat.follower?.stop()
            }
        }

        let request = TranscriptLookup.Request(kind: .codex, sessionID: chat.sessionID, path: chat.transcriptPath,
                                              cwd: project.path, startedAt: now, excluded: [], roots: model.transcriptLocations)
        check("Codex relaunch: 23 KB header, old timestamp and different original cwd preserve the saved attachment",
              TranscriptLookup.find(request, events: []) == .init(id: "main", path: main.path))
        model.beginTranscriptDiscovery(chat, cwd: project.path, replayEvents: true)
        check("Codex relaunch: saved path loads full history without a hook file",
              waitUntil(5) { chat.allEntries.map(\.text) == ["History for main"] })
        let original = chat.follower
        let childNotice = try! JSONSerialization.data(withJSONObject: ["type": "agent-turn-complete",
                                                                      "thread-id": "child", "turn-id": "child-turn"])
        check("Codex relaunch: a child completion cannot replace a validated main transcript",
              TranscriptLookup.find(request, events: [childNotice]) == .init(id: "main", path: main.path))
        Paths.ensure(AgentHooks.eventsDir)
        try! (childNotice + Data([0x0A])).write(to: AgentHooks.eventsFile(for: chat.id))
        let center = StatusCenter()
        center.notifier = NoticeRecorder()
        center.start(model: model, live: false)
        check("Codex relaunch: replaying an unresolvable child ID keeps the live follower and saved identity",
              waitUntil(5) { chat.codexSessionRequest == nil }
              && chat.sessionID == "main" && chat.follower === original && chat.transcriptPath == main.path)
        append(message("New question") + message("New answer", role: "assistant"), to: main)
        check("Codex relaunch: both sides of the next turn arrive after recheck and event replay",
              waitUntil(5) { chat.allEntries.count == 3 } && chat.follower === original)
        check("Codex relaunch: nested source metadata excludes a child even without parent_thread_id",
              CodexTranscriptParser.readMeta(child) == nil)

        let resumed = rollout("resumed")
        let mainNotice = try! JSONSerialization.data(withJSONObject: ["type": "agent-turn-complete", "thread-id": "resumed"])
        check("Codex relaunch: a later child completion does not hide an earlier valid main switch",
              TranscriptLookup.find(request, events: [mainNotice, childNotice]) == .init(id: "resumed", path: resumed.path))
        let fresh = Chat(projectID: project.id, agentID: "codex")
        fresh.startedAt = now
        model.chats.append(fresh)
        model.codexProcessID = { $0 == fresh.id ? 123 : nil }
        model.codexOpenRollouts = { pid, _ in pid == 123 ? [resumed, child] : [] }
        model.beginTranscriptDiscovery(fresh, cwd: project.path)
        check("Codex resume: an owned old rollout is found before a new turn despite another cwd and no hook",
              waitUntil(5) { fresh.sessionID == "resumed" && fresh.allEntries.map(\.text) == ["History for resumed"] })
        append(line("event_msg", ["type": "task_started", "turn_id": "new-turn"])
            + line("turn_context", ["turn_id": "new-turn", "cwd": project.path])
            + message("After resume") + message("Resumed answer", role: "assistant"), to: resumed)
        check("Codex resume: the newly attached full history continues through the next turn",
              waitUntil(5) { fresh.allEntries.map(\.text) == ["History for resumed", "After resume", "Resumed answer"] })

        // Current Codex can keep earlier root threads open after navigating to another one.
        let other = rollout("other-root")
        let selected = CodexRolloutSelection(since: now)
        check("Codex resume: multiple idle root writers are not guessed from cwd or title",
              selected.select(paths: [main, other, child], currentPath: nil) == nil)
        append(line("event_msg", ["type": "task_started", "turn_id": "picked-turn"], at: now.addingTimeInterval(1)), to: other)
        check("Codex resume: the next task_started selects the resumed root among retained writers",
              selected.select(paths: [main, other, child], currentPath: main.path) == .init(id: "other-root", path: other.path))
        append(line("turn_context", ["turn_id": "picked-turn", "cwd": project.path], at: now.addingTimeInterval(2)), to: other)
        check("Codex resume: turn_context confirms the same root without an original-cwd filter",
              selected.select(paths: [main, other], currentPath: main.path)?.id == "other-root")
        let settings = CodexRolloutSelection(since: now)
        append(line("event_msg", ["type": "thread_settings_applied", "thread_id": "main",
                                   "thread_settings": ["cwd": project.path]], at: now.addingTimeInterval(3)), to: main)
        check("Codex resume: changed settings can identify the resumed root before its next turn",
              settings.select(paths: [main, other], currentPath: other.path)?.id == "main")

        let rootPath = root.path
        check("Codex process: only writable rollout files inside the session root qualify",
              CodexProcessRollout.rolloutPath(main.path, openFlags: 2, sessionsRoot: root) == main.standardizedFileURL.resolvingSymlinksInPath()
              && CodexProcessRollout.rolloutPath(main.path, openFlags: 1, sessionsRoot: root) == nil
              && CodexProcessRollout.rolloutPath(rootPath + "-other/rollout-no.jsonl", openFlags: 2, sessionsRoot: root) == nil)
        func identity(_ pid: Int32, _ parent: Int32, _ executable: String) -> CodexProcessRollout.ProcessIdentity {
            .init(pid: pid, parentPID: parent, executable: executable, startSeconds: 1, startMicroseconds: 0)
        }
        let processes: [Int32: CodexProcessRollout.ProcessIdentity] = [
            1: identity(1, 0, "/usr/bin/node"), 2: identity(2, 1, "/bin/codex"),
            3: identity(3, 2, "/bin/codex")]
        check("Codex process: wrappers are traversed but Codex tool descendants are excluded",
              CodexProcessRollout.mainProcesses(rootPID: 1, identity: { processes[$0] },
                                               children: { $0 == 1 ? [2] : [3] }).map(\.pid) == [2])
    }
}
