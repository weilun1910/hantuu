import Foundation

extension SelfTest {
    static func codexSessionIdentity(_ dir: URL) {
        let root = dir.appendingPathComponent("codex-title-identity", isDirectory: true)
        Paths.ensure(root)
        let first = "019a703c-bcc8-7311-b715-8da61fb7e542"
        let collision = "019a703c-bcc8-7311-b715-8da61fffffff"
        let full = CodexTitleIdentity.parse(first + " | Review title bridge")!
        let shortText = String(first.prefix(29)) + "..."
        let short = CodexTitleIdentity.parse(shortText + " | Review title bridge")!
        check("codex title: full UUID and clean display title", !full.truncated && full.prefix == first && full.displayTitle == "Review title bridge")
        check("codex title: exact 29-character truncated UUID item", short.truncated && short.matches(first) && short.matches(collision))
        check("codex title: bare identity is accepted", CodexTitleIdentity.parse(first)?.displayTitle == "")
        for invalid in ["Codex | " + first, "Working " + first, "project-name", String(first.prefix(28)) + "...", first + "extra", "12345678-xxxx-1234-1234-123456789012", " " + first] {
            check("codex title: rejects unconfigured identity shape", CodexTitleIdentity.parse(invalid) == nil)
        }
        check("codex title: prefix never matches a non-UUID", !short.matches(short.prefix + "nonsense"))
        let renamed = CodexTitleIdentity.parse(shortText + " | A new automatic thread name")!
        check("codex title: thread-name changes preserve the same identity state", renamed.sameIdentity(as: short))
        check("codex title: initial truncated reattach preserves saved queue and seen state", short.preservesSession(first))
        check("codex title: genuinely different prefix replaces session state", !short.preservesSession("77777777-7777-4777-8777-777777777777"))
        func rollout(_ id: String, child: Bool = false, root target: URL? = nil) -> URL {
            let folder = target ?? root; Paths.ensure(folder)
            let url = folder.appendingPathComponent("rollout-2026-11-11T12-00-00-\(id).jsonl")
            var payload: [String: Any] = ["id": id, "cwd": root.path, "source": "cli", "timestamp": "2026-11-11T12:00:00Z"]
            if child { payload["parent_thread_id"] = first; payload["thread_source"] = "subagent" }
            var data = (try? JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": payload])) ?? Data()
            data.append(10); try? data.write(to: url)
            return url
        }
        check("codex title: missing rollout stays unresolved", CodexTitleLookup.resolve(full, root: root) == .missing)
        let firstFile = rollout(first)
        let before = try? Data(contentsOf: firstFile)
        let model = AppModel()
        let project = Project(path: root.path)
        let chat = Chat(projectID: project.id, agentID: "codex")
        chat.status = .ended
        chat.sessionID = first
        chat.transcriptPath = firstFile.path
        chat.seenSessionID = first
        chat.seenCompletionKey = "saved-completion"
        chat.manualUnread = true
        chat.pendingMessages.enqueue(id: "queued-fixture", text: "Keep this message", files: [], agentID: "codex", existing: [])
        model.projects = [project]; model.chats = [chat]
        model.transcriptLocations = TranscriptLocations(claude: root, codex: root)
        model.acceptCodexTitle(chat, title: shortText + " | Saved title")
        check("codex title: revalidation hides history while preserving actual chat state", chat.codexIdentityWaiting && chat.transcriptPath == nil && chat.sessionID == first && chat.manualUnread && chat.seenCompletionKey == "saved-completion" && chat.pendingMessages.entries.count == 1)
        model.followSession(chat, session: HookLineParser.Session(id: first, path: firstFile.path))
        check("codex title: verified same session restores follower and keeps state", waitUntil(3) { !chat.codexIdentityWaiting && chat.transcriptPath == firstFile.path && chat.follower != nil } && chat.manualUnread && chat.seenCompletionKey == "saved-completion" && chat.pendingMessages.entries.count == 1)
        let follower = chat.follower
        model.acceptCodexTitle(chat, title: shortText + " | New automatic name")
        check("codex title: automatic rename keeps active follower and queued message", chat.follower === follower && !chat.codexIdentityWaiting && chat.pendingMessages.entries.count == 1 && chat.manualUnread)
        chat.follower?.stop()
        chat.codexTitleIdentity.waiting = true
        chat.codexTitleIdentity.blocksInput = true
        model.followSession(chat, session: .init(id: first, path: firstFile.path), verifiedCodex: true)
        check("codex title: verified unchanged rollout releases the composer gate", !chat.codexIdentityWaiting && !chat.codexTitleIdentity.waiting && chat.follower === follower)
        let freshChat = Chat(projectID: project.id, agentID: "codex")
        freshChat.status = .ended
        model.chats.append(freshChat)
        freshChat.pendingMessages.enqueue(id: "first-send", text: "First prompt", files: [], agentID: "codex", existing: [])
        model.acceptCodexTitle(freshChat, title: shortText + " | New thread")
        check("codex title: deferred first rollout permits input while identity is unresolved", freshChat.codexTitleIdentity.waiting && !freshChat.codexIdentityWaiting && freshChat.pendingMessages.entries.count == 1)
        model.followSession(freshChat, session: .init(id: first, path: firstFile.path), verifiedCodex: true)
        check("codex title: first verified rollout retains pending input", !freshChat.codexTitleIdentity.waiting && freshChat.pendingMessages.entries.count == 1 && freshChat.follower != nil)
        model.acceptCodexTitle(freshChat, title: "77777777-7777-4777-8777-777777777777 | Different thread")
        check("codex title: changing an established thread still blocks input and clears its queue", freshChat.codexIdentityWaiting && freshChat.pendingMessages.isEmpty)
        model.followSession(freshChat, session: .init(id: "77777777-7777-4777-8777-777777777777", path: root.appendingPathComponent("missing.jsonl").path))
        _ = waitUntil(3) { freshChat.codexSessionRequest == nil }
        check("codex title: unverified hook cannot release the input gate", freshChat.codexIdentityWaiting && freshChat.follower == nil)
        freshChat.follower?.stop()
        check("codex title: launch override is isolated to the command", AgentHooks.codexArguments(existingNotify: .none).contains(#"tui.terminal_title=["session-id","thread-name"]"#))
        check("codex title: exact native identity resolves", CodexTitleLookup.resolve(full, root: root) == .found(id: first, path: firstFile.path))
        check("codex title: unique truncated identity resolves", CodexTitleLookup.resolve(short, root: root) == .found(id: first, path: firstFile.path))
        _ = rollout(collision)
        check("codex title: truncated collision is rejected", CodexTitleLookup.resolve(short, root: root) == .ambiguous)
        check("codex title: full identity ignores neighboring prefix", CodexTitleLookup.resolve(full, root: root) == .found(id: first, path: firstFile.path))
        check("codex title: partial scan cannot establish uniqueness", CodexTitleLookup.resolve(full, root: root, limit: 0) == .incomplete)
        let token = ChatHistoryCancellation(); token.cancel()
        check("codex title: cancelled scan cannot publish", CodexTitleLookup.resolve(full, root: root, cancellation: token) == .cancelled)
        let childRoot = root.appendingPathComponent("children", isDirectory: true)
        _ = rollout(first, child: true, root: childRoot)
        check("codex title: child metadata cannot become parent identity", CodexTitleLookup.resolve(full, root: childRoot) == .missing)
        let incompleteRoot = root.appendingPathComponent("incomplete", isDirectory: true)
        Paths.ensure(incompleteRoot)
        let damaged = incompleteRoot.appendingPathComponent("rollout-damaged-\(first).jsonl")
        try? Data("{\"type\":\"session_meta\"".utf8).write(to: damaged)
        check("codex title: incomplete candidate fails closed", CodexTitleLookup.resolve(full, root: incompleteRoot) == .incomplete)
        let state = CodexTitleIdentityState()
        state.hint = full; state.waiting = false
        check("codex title: resolved title still rejects a stale notify", !state.allows(collision) && state.allows(first))
        state.hint = nil; state.waiting = true
        check("codex title: custom title accepts only complete notify identity", !state.allows(nil) && !state.allows("not-an-id") && state.allows(first))
        state.inFlight = true
        let generation = state.generation
        let previous = ChatHistoryCancellation(); state.cancellation = previous
        state.cancel()
        check("codex title: cancellation invalidates generation and work", state.generation != generation && previous.cancelled && state.needsLookup)
        check("codex title: discovery leaves provider fixture unchanged", (try? Data(contentsOf: firstFile)) == before)
    }
}
