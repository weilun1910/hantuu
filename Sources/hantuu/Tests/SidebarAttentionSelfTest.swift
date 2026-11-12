import AppKit

extension SelfTest {
    static func sidebarAttention(_ dir: URL) {
        for provider in ["claude", "codex"] {
            let model = AppModel()
            let project = Project(path: dir.path)
            model.projects = [project]
            let chat = Chat(projectID: project.id, agentID: provider)
            chat.sessionID = "attention-session-" + provider
            let center = StatusCenter()
            let notices = NoticeRecorder()
            center.notifier = notices
            center.appIsActive = { true }
            center.start(model: model, live: false)
            center.requiresVisibleWindow = true
            var visible = true
            center.conversationWindowIsVisible = { visible }
            model.chats = [chat]
            model.selectedChatID = chat.id
            let child = SidebarSubagent(SubagentInfo(id: "child", title: "Inspect child"))
            model.subagentBrowser.selection = .init(chatID: chat.id, agent: child)
            let file = AgentHooks.eventsFile(for: chat.id)
            func append(_ input: String) {
                // Session identity is supplied by the fixture, without starting transcript discovery.
                var object = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any] ?? [:]
                object["session_id"] = nil
                object["transcript_path"] = nil
                let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(input.utf8)
                let line = String(decoding: data, as: UTF8.self)
                if !FileManager.default.fileExists(atPath: file.path) {
                    FileManager.default.createFile(atPath: file.path, contents: nil)
                }
                let handle = try? FileHandle(forWritingTo: file)
                _ = try? handle?.seekToEnd()
                handle?.write(Data((line + "\n").utf8))
                try? handle?.close()
                center.poll()
            }
            func finish(_ id: String) {
                if provider == "claude" {
                    append(hook("UserPromptSubmit"))
                    append(hook("Stop", #""last_assistant_message":"Finished.""#))
                } else {
                    append(#"{"type":"agent-turn-complete","turn-id":"\#(id)","last-assistant-message":"Finished."}"#)
                }
            }
            finish("turn-one")
            check("attention: \(provider) parent behind child remains unread and notifies", chat.activity == .doneUnseen && notices.posted.count == 1)
            center.refreshVisibleConversation()
            check("attention: \(provider) child refresh does not acknowledge parent", chat.activity == .doneUnseen)
            model.subagentBrowser.selection = nil
            visible = false
            center.refreshVisibleConversation()
            check("attention: \(provider) hidden window does not acknowledge parent", chat.activity == .doneUnseen)
            visible = true
            center.refreshVisibleConversation()
            check("attention: \(provider) visible parent records native-session watermark", chat.activity == .idle && chat.seenSessionID == chat.sessionID && chat.seenCompletionKey != nil)
            center.setRead(chat: chat, read: false)
            check("attention: \(provider) manual unread is explicit", chat.manualUnread && chat.activity == .doneUnseen)
            center.setRead(chat: chat, read: true)
            visible = false
            // Relaunch the status engine against exactly the same saved session metadata.
            let restored = StatusCenter()
            let replayNotices = NoticeRecorder()
            restored.notifier = replayNotices
            restored.appIsActive = { false }
            restored.start(model: model, live: false)
            check("attention: \(provider) seen completion replay stays read and quiet", chat.activity == .idle && replayNotices.posted.isEmpty)
            center.setRead(chat: chat, read: false)
            let unreadRestored = StatusCenter()
            unreadRestored.notifier = NoticeRecorder()
            unreadRestored.appIsActive = { false }
            unreadRestored.start(model: model, live: false)
            check("attention: \(provider) explicit unread survives replay", chat.manualUnread && chat.activity == .doneUnseen)
            center.setRead(chat: chat, read: true)
            finish("turn-two")
            check("attention: \(provider) identical new reply remains a new unread completion", chat.activity == .doneUnseen && notices.posted.count == 2)
            chat.status = .ended
            check("attention: \(provider) process exit preserves unread result", chat.activity == .doneUnseen && !chat.manualUnread)
            let endedReplay = StatusCenter()
            let endedNotices = NoticeRecorder()
            endedReplay.notifier = endedNotices
            endedReplay.appIsActive = { false }
            endedReplay.start(model: model, live: false)
            check("attention: \(provider) ended replay preserves unread without notifying", chat.activity == .doneUnseen && chat.activityDetail == "Ended - unread result" && endedNotices.posted.isEmpty)
            endedReplay.setRead(chat: chat, read: true)
            let endedSeenReplay = StatusCenter()
            endedSeenReplay.notifier = NoticeRecorder()
            endedSeenReplay.appIsActive = { false }
            endedSeenReplay.start(model: model, live: false)
            check("attention: \(provider) seen ended replay remains read", chat.activity == .ended && !chat.manualUnread)
            center.setRead(chat: chat, read: false)
            check("attention: \(provider) ended chat can be marked unread", chat.status == .ended && chat.activity == .doneUnseen && center.attention.contains(chat.id))
            center.setRead(chat: chat, read: true)
            check("attention: \(provider) read ended chat keeps lifecycle", chat.status == .ended && chat.activity == .ended)
            chat.status = .running
            center.setRead(chat: chat, read: false)
            chat.archivedAt = Date()
            center.recomputeAttention()
            check("attention: \(provider) archived conversation leaves attention queue", !center.attention.contains(chat.id))
            chat.archivedAt = nil
            if provider == "claude" {
                append(hook("UserPromptSubmit"))
                center.setRead(chat: chat, read: false)
                check("attention: manual unread does not replace working", chat.activity == .working)
                append(permBash)
                center.setRead(chat: chat, read: true)
                check("attention: mark read retains strong permission wait", chat.activity == .needsPermission)
            }
        }
        for provider in ["claude", "codex"] {
            let transcript = dir.appendingPathComponent("ended-attention-" + provider + ".jsonl")
            let line = provider == "claude"
                ? #"{"type":"assistant","timestamp":"2026-11-11T09:00:00Z","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Finished."}]}}"#
                : #"{"type":"event_msg","timestamp":"2026-11-11T09:00:00Z","payload":{"type":"task_complete","turn_id":"ended-fixture","last_agent_message":"Finished."}}"#
            try? (line + "\n").write(to: transcript, atomically: true, encoding: .utf8)
            let model = AppModel()
            let chat = Chat(projectID: UUID(), agentID: provider)
            chat.sessionID = "ended-transcript-" + provider
            chat.status = .ended
            chat.transcriptPath = transcript.path
            model.chats = [chat]
            let center = StatusCenter()
            let notices = NoticeRecorder()
            center.notifier = notices
            center.appIsActive = { false }
            center.start(model: model, live: false)
            check("attention: \(provider) ended transcript fallback recovers completion quietly", chat.activity == .doneUnseen && notices.posted.isEmpty)
            center.setRead(chat: chat, read: true)
            let restored = StatusCenter()
            restored.notifier = NoticeRecorder()
            restored.appIsActive = { false }
            restored.start(model: model, live: false)
            check("attention: \(provider) seen transcript fallback remains ended", chat.activity == .ended)
        }
        for provider in ["claude", "codex"] {
            let model = AppModel()
            let chat = Chat(projectID: UUID(), agentID: provider)
            chat.sessionID = "old-session"
            let center = StatusCenter()
            center.notifier = NoticeRecorder()
            center.appIsActive = { false }
            center.start(model: model, live: false)
            model.chats = [chat]
            let file = AgentHooks.eventsFile(for: chat.id)
            func appendIdentityFixture(_ line: String) {
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                let handle = try? FileHandle(forWritingTo: file)
                _ = try? handle?.seekToEnd()
                handle?.write(Data((line + "\n").utf8))
                try? handle?.close()
                center.poll()
            }
            let completion = provider == "claude"
                ? #"{"hook_event_name":"Stop","last_assistant_message":"Old result."}"#
                : #"{"type":"agent-turn-complete","turn-id":"old-turn","last-assistant-message":"Old result."}"#
            appendIdentityFixture(completion)
            center.setRead(chat: chat, read: true)
            appendIdentityFixture(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"fixture"}}"#)
            check("attention: \(provider) identity fixture has old permission wait", chat.activity == .needsPermission)
            chat.sessionID = nil
            check("attention: \(provider) unknown identity clears old waits and completion", chat.activity == .idle && chat.lastTurnEndedAt == nil && center.state(of: chat.id)?.waits.isEmpty == true)
            center.terminalAttention(chat, reason: "notification: Approval requested: stale command")
            check("attention: \(provider) old signals cannot refill unknown identity", chat.activity == .idle)
            chat.sessionID = "new-session"
            center.poll()
            center.setRead(chat: chat, read: true)
            check("attention: \(provider) old completion is not marked seen under new session", chat.seenSessionID == "old-session" && chat.lastTurnEndedAt == nil)
            appendIdentityFixture(completion)
            check("attention: \(provider) new identity accepts a fresh completion", chat.activity == .doneUnseen)
            center.setRead(chat: chat, read: true)
            check("attention: \(provider) only new result gets new session watermark", chat.seenSessionID == "new-session")
        }
        let offsetFile = dir.appendingPathComponent("attention-record-offsets.jsonl")
        try? "a\n\nbroken-json\n\nlast\npartial".write(to: offsetFile, atomically: true, encoding: .utf8)
        let offsetTail = LineTail(url: offsetFile, from: .beginning)
        let offsetCenter = StatusCenter()
        let firstOffsets = offsetCenter.records(offsetTail.read(), tail: offsetTail).map { $0.1 }
        check("attention: empty and corrupt lines retain absolute completion offsets", firstOffsets == [2, 15, 21])
        let offsetHandle = try? FileHandle(forWritingTo: offsetFile)
        _ = try? offsetHandle?.seekToEnd()
        offsetHandle?.write(Data("\n\n".utf8))
        try? offsetHandle?.close()
        let secondOffsets = offsetCenter.records(offsetTail.read(), tail: offsetTail).map { $0.1 }
        check("attention: buffered partial line gets its original absolute offset", secondOffsets == [29])
        let provisionalModel = AppModel()
        let provisional = Chat(projectID: UUID(), agentID: "codex")
        provisional.status = .ended
        provisionalModel.chats = [provisional]
        let provisionalCenter = StatusCenter()
        provisionalCenter.notifier = NoticeRecorder()
        provisionalCenter.appIsActive = { false }
        provisionalCenter.start(model: provisionalModel, live: false)
        check("attention: provisional ended row without records stays ended", provisional.activity == .ended && provisional.lastTurnEndedAt == nil)

        let anonymousModel = AppModel()
        let anonymous = Chat(projectID: UUID(), agentID: "other")
        anonymousModel.chats = [anonymous]
        let anonymousCenter = StatusCenter()
        anonymousCenter.notifier = NoticeRecorder()
        anonymousCenter.appIsActive = { false }
        anonymousCenter.start(model: anonymousModel, live: false)
        anonymousCenter.terminalAttention(anonymous, reason: "notification: Agent turn complete")
        anonymousCenter.setRead(chat: anonymous, read: true)
        check("attention: absent native ID does not create a nil session watermark", anonymous.seenSessionID != nil)
    }
}
