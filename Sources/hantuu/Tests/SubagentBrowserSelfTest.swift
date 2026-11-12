import AppKit
import Combine
import SwiftUI

extension SelfTest {
    static func subagentBrowser(_ dir: URL) {
        let base = dir.appendingPathComponent("subagent-browser", isDirectory: true)
        Paths.ensure(base)
        subagentNavigation(base)
        subagentPolling(base)
        subagentProviderMessages()
        subagentTranscripts(base)
        subagentSidebarSnapshots(dir, fixtureDirectory: base)
    }

    private static func subagentNavigation(_ base: URL) {
        var parent = SubagentInfo(id: "parent", title: "Review rendering")
        parent.state = .waiting
        parent.transcript = base.appendingPathComponent("parent.jsonl").path
        var child = SubagentInfo(id: "child", title: "Check scroll following")
        child.parentID = parent.id
        child.step = "Reading the renderer"
        var retired = SubagentInfo(id: "retired", title: "Finished research")
        retired.state = .done
        let model = AppModel()
        let project = Project(path: base.path)
        let chat = Chat(projectID: project.id, agentID: "claude")
        let other = Chat(projectID: project.id, agentID: "codex")
        model.projects = [project]
        model.chats = [chat, other]
        let agents = [parent, child, retired].map(SidebarSubagent.init)
        model.updateSubagents(agents, for: chat.id)
        check("subagent sidebar: only open agents count toward the chevron", model.subagentBrowser.count(for: chat.id) == 2)
        check("subagent sidebar: collapsed by default", !model.subagentBrowser.expanded.contains(chat.id))
        model.subagentBrowser.toggle(chat.id)
        check("subagent sidebar: expand", model.subagentBrowser.expanded.contains(chat.id))
        model.subagentBrowser.toggle(chat.id)
        check("subagent sidebar: collapse", !model.subagentBrowser.expanded.contains(chat.id))
        let rows = model.subagentBrowser.rows(for: chat.id)
        check("subagent sidebar: children appear directly below their parent", rows.map(\.id) == ["parent", "child"] && rows.map(\.depth) == [0, 1])
        model.selectSubagent(child.id, in: chat.id)
        check("subagent selection: keeps the parent's project and expands the row", model.selectedChatID == chat.id && model.currentProject?.id == project.id && model.subagentBrowser.selection?.agent.id == child.id && model.subagentBrowser.expanded.contains(chat.id))
        check("subagent selection: never becomes a numbered chat", model.sidebarOrder.map(\.id) == [chat.id, other.id] && model.globalIndex(of: other) == 1 && model.chats.count == 2)
        chat.pinnedAt = Date()
        check("subagent sidebar: pinning keeps the same tree and chat numbering", model.pinnedChats.map(\.id) == [chat.id] && model.subagentBrowser.rows(for: chat.id).map(\.id) == ["parent", "child"] && model.globalIndex(of: other) == 1)
        chat.pinnedAt = nil
        model.closeFocused(responder: nil)
        check("subagent selection: Cmd-W returns without closing or prompting for the parent", model.subagentBrowser.selection == nil && model.selectedChatID == chat.id && model.chats.count == 2)
        model.selectSubagent(parent.id, in: chat.id)
        parent.state = .done
        parent.transcript = nil
        child.state = .stopped
        model.updateSubagents([parent, child, retired].map(SidebarSubagent.init), for: chat.id)
        check("subagent retirement: no rows, chevron or count remain", model.subagentBrowser.count(for: chat.id) == 0 && model.subagentBrowser.rows(for: chat.id).isEmpty && !model.subagentBrowser.expanded.contains(chat.id))
        check("subagent retirement: selection keeps its transcript and Finished line", model.subagentBrowser.selection?.agent.detail == "Finished" && model.subagentBrowser.selection?.agent.transcript?.hasSuffix("parent.jsonl") == true)
        model.selectChat(index: 1)
        check("subagent retirement: the retained view drops on the next selection", model.subagentBrowser.selection == nil && model.selectedChatID == other.id)
        parent.state = .running
        model.updateSubagents([SidebarSubagent(parent)], for: chat.id)
        model.selectSubagent(parent.id, in: chat.id)
        check("subagent selection: back restores the parent", model.backFromSubagent() && model.selectedChatID == chat.id && model.subagentBrowser.selection == nil)
        model.selectSubagent(parent.id, in: chat.id)
        model.subagentBrowser.forget(chat.id)
        check("subagent selection: removing the parent forgets its subagents", model.subagentBrowser.selection == nil && model.subagentBrowser.open[chat.id] == nil)
        var notifications = 0
        let observation = model.$subagentBrowser.dropFirst().sink { _ in notifications += 1 }
        model.updateSubagents([], for: chat.id)
        model.updateSubagents([], for: chat.id)
        check("subagent sidebar: unchanged work does not republish", notifications == 0)
        observation.cancel()
    }

    private static func subagentPolling(_ base: URL) {
        let fx = WorkFixture.make(base.appendingPathComponent("claude-work"), now: Date())
        let model = AppModel()
        let project = Project(path: base.path)
        let chat = Chat(projectID: project.id, agentID: "claude")
        chat.transcriptPath = fx.transcript.path
        chat.startedAt = fx.processStart
        model.projects = [project]
        model.chats = [chat]
        let watch = BackgroundWatch()
        watch.codexRoot = base.appendingPathComponent("codex-fixtures")
        var deliveries = 0
        var deliveredOnMain = true
        watch.deliverSubagents = { _, _ in deliveries += 1; deliveredOnMain = deliveredOnMain && Thread.isMainThread }
        watch.start(model: model)
        watch.stop()
        check("subagent polling: unselected chats publish their nested agents on main", waitUntil(10) { deliveries > 0 } && deliveredOnMain && model.selectedChatID == nil && model.subagentBrowser.rows(for: chat.id).contains { $0.depth == 1 })
        let first = deliveries
        var ticked = false
        watch.tick(now: fx.now) { ticked = true }
        check("subagent polling: a quiet poll does not publish again", waitUntil(10) { ticked } && deliveries == first)
        let open = model.subagentBrowser.open[chat.id] ?? []
        check("subagent polling: finished and old-process work is absent", !open.contains { [WorkFixture.a3, WorkFixture.a4, WorkFixture.a5, "toolu_OLD"].contains($0.id) })
        model.selectSubagent(WorkFixture.a2, in: chat.id)
        ticked = false
        watch.tick(now: fx.now.addingTimeInterval(BackgroundRules.quietAgent + 1)) { ticked = true }
        check("subagent polling: stale rules remove rows and retain the selected final state", waitUntil(10) { ticked } && model.subagentBrowser.count(for: chat.id) == 0 && model.subagentBrowser.selection?.agent.state == .stale)

        // Child rollouts, including grandchildren, are always confined to this fixture root.
        let root = base.appendingPathComponent("codex-fixtures")
        let now = Date()
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let day = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        func event(_ type: String, _ payload: [String: Any]) -> String {
            WorkFixture.line(["timestamp": WorkFixture.iso.string(from: now), "type": type, "payload": payload])
        }
        let file = day.appendingPathComponent("rollout-test-child.jsonl")
        let grand = day.appendingPathComponent("rollout-test-grandchild.jsonl")
        WorkFixture.write(file, [
            event("session_meta", ["id": "child"]),
            event("event_msg", ["type": "task_started"]),
            event("event_msg", ["type": "item_completed", "item": ["type": "SubAgentActivity", "kind": "started", "agent_path": "/root/review/check", "agent_thread_id": "grandchild"]]),
            event("event_msg", ["type": "task_complete"]),
        ])
        WorkFixture.write(grand, [event("session_meta", ["id": "grandchild"]), event("event_msg", ["type": "task_started"]),
                                  event("response_item", ["type": "function_call", "name": "exec_command", "arguments": "{\"cmd\":\"rg reader Sources\"}"])])
        var agent = SubagentInfo(id: "/root/review", agentID: "child", title: "Review")
        agent.startedAt = now
        let tracker = AgentWorkTracker()
        tracker.codexRoot = root
        let work = tracker.update(AgentWork(subagents: [agent]), transcript: base.appendingPathComponent("rollout-parent.jsonl"), kind: .codex, processStart: now.addingTimeInterval(-60), sidebarOnly: true)
        check("subagent polling: Codex children discover their own children", work.subagents.count == 2 && work.subagents.last?.parentID == agent.id && work.subagents.last?.transcript == grand.path && work.subagents.last?.step?.contains("rg reader") == true)
        check("subagent polling: Codex parent waits while its child is working", work.subagents.first?.state == .waiting)
        WorkFixture.append(grand, [event("event_msg", ["type": "task_complete"])])
        let done = tracker.update(AgentWork(subagents: [agent]), transcript: base.appendingPathComponent("rollout-parent.jsonl"), kind: .codex, processStart: now.addingTimeInterval(-60), sidebarOnly: true)
        check("subagent polling: Codex child completion retires the whole finished branch", done.subagents.allSatisfy { !$0.state.isActive })
    }

    /// Sanitized shapes from Claude Code 2.1.322 and Codex 0.167.1 child transcripts.
    private static func subagentProviderMessages() {
        func parse(_ parser: inout ClaudeTranscriptParser, _ object: [String: Any]) -> [ReaderEntry] {
            parser.parse(line: Data(WorkFixture.line(object).utf8))
        }
        func claude(_ id: String, _ type: String, _ content: Any) -> [String: Any] {
            ["uuid": id, "type": type, "isSidechain": true, "agentId": "fixture-child",
             "sessionId": "fixture-parent", "message": ["role": type, "content": content]]
        }
        var parser = ClaudeTranscriptParser(scope: .subagent)
        let task = claude("task", "user", "Inspect the child conversation")
        let initial = parse(&parser, task)
        check("subagent Claude: initial plain-string task is attributed to the parent", initial.first?.kind == .user && initial.first?.author == "Parent")
        var meta = claude("reminder", "user", "<system-reminder>Use the final-report tool.</system-reminder>")
        meta["isMeta"] = true
        check("subagent Claude: injected reminders and request bookkeeping stay hidden",
              parse(&parser, meta).isEmpty &&
              parse(&parser, ["type": "api-request-blob", "message": ["content": "internal fixture"]]).isEmpty &&
              parse(&parser, ["type": "attachment", "attachment": ["type": "agent_status"]]).isEmpty)
        let handback = claude("report", "assistant", [
            ["type": "tool_use", "id": "handback", "name": "SubagentHandback",
             "input": ["message": "The **child report** is complete.\n\n- Checked the renderer."]]
        ])
        let report = parse(&parser, handback)
        check("subagent Claude: SubagentHandback renders its full report as an answer",
              report.count == 1 && report.first?.kind == .assistant &&
              report.first?.text == "The **child report** is complete.\n\n- Checked the renderer." && report.first?.id == "report-0")
        let receipt = claude("receipt", "user", [
            ["type": "tool_result", "tool_use_id": "handback", "content": [["type": "text", "text": "Report delivered to your caller."]]]
        ])
        check("subagent Claude: handback receipt does not duplicate the answer", parse(&parser, receipt).isEmpty)
        let failure = claude("failure", "user", [
            ["type": "tool_result", "tool_use_id": "handback", "is_error": true, "content": "Delivery failed"]
        ])
        check("subagent Claude: handback delivery errors remain visible", parse(&parser, failure).first?.kind == .error)
        let empty = claude("empty", "assistant", [["type": "tool_use", "name": "SubagentHandback", "input": ["message": " "]]])
        check("subagent Claude: malformed handback retains a tool row", parse(&parser, empty).first?.kind == .tool)
        let plain = claude("plain", "assistant", [["type": "text", "text": "An ordinary final answer"]])
        check("subagent Claude: ordinary final text is still supported", parse(&parser, plain).first?.text == "An ordinary final answer")
        var main = ClaudeTranscriptParser()
        check("subagent Claude: the parent reader still excludes child messages",
              parse(&main, task).isEmpty && parse(&main, handback).isEmpty)

        func codex(_ type: String, _ payload: [String: Any]) -> Data {
            Data(WorkFixture.line(["type": type, "timestamp": "2026-11-11T12:00:00Z", "payload": payload]).utf8)
        }
        func inbound(_ text: String, recipient: String = "/root/child") -> Data {
            codex("response_item", ["type": "agent_message", "id": "message-id", "author": "/root", "recipient": recipient,
                                    "content": [["type": "input_text", "text": text],
                                                ["type": "encrypted_content", "encrypted_content": "opaque-fixture"]]])
        }
        let metadata = codex("session_meta", ["id": "child", "thread_source": "subagent", "parent_thread_id": "parent",
                                              "source": ["subagent": ["thread_spawn": ["agent_path": "/root/child", "parent_thread_id": "parent", "depth": 1]]]])
        var child = CodexTranscriptParser(scope: .subagent)
        _ = child.parse(line: metadata)
        let prompt = "Message Type: NEW_TASK\nTask name: /root/child\nSender: /root\nPayload:\nCheck the child reader"
        let first = child.parse(line: inbound(prompt))
        check("subagent Codex: task text renders with its sender and without internal envelope",
              first.count == 1 && first.first?.kind == .user && first.first?.text == "Check the child reader" && first.first?.author == "/root")
        let followup = child.parse(line: inbound("Message Type: MESSAGE\nSender: /root\nPayload:\nCheck the final output too"))
        check("subagent Codex: followups have distinct entries", followup.first?.kind == .user && followup.first?.id != first.first?.id)
        check("subagent Codex: messages for another child stay out", child.parse(line: inbound("Unrelated task", recipient: "/root/other")).isEmpty)
        let output = codex("response_item", ["type": "message", "role": "assistant", "phase": "final_answer",
                                            "content": [["type": "output_text", "text": "Final child answer"]]])
        check("subagent Codex: final answer renders once without the completion echo",
              child.parse(line: output).map(\.text) == ["Final child answer"] &&
              child.parse(line: codex("event_msg", ["type": "task_complete", "last_agent_message": "Final child answer"])).isEmpty)
        let opaque = child.parse(line: codex("response_item", ["type": "agent_message", "author": "/root", "recipient": "/root/child",
            "content": [["type": "encrypted_content", "encrypted_content": "opaque-fixture"]]]))
        check("subagent Codex: encrypted payload has an explicit unavailable notice", opaque.first?.kind == .notice &&
              opaque.first?.contentUnavailable == "encrypted-agent-message" && opaque.first?.text.contains("opaque-fixture") == false)
        let headerOnly = child.parse(line: inbound("Message Type: NEW_TASK\nTask name: /root/child\nSender: /root\nPayload:\n"))
        check("subagent Codex: encrypted task never renders an empty internal envelope", headerOnly.count == 1 &&
              headerOnly.first?.contentUnavailable == "encrypted-agent-message" && headerOnly.first?.text.contains("Payload:") == false)
        check("subagent Codex: malformed messages stay hidden",
              child.parse(line: codex("response_item", ["type": "agent_message", "content": [["type": "input_text", "text": "Missing sender"]]])).isEmpty)
        var bounded = CodexTranscriptParser(scope: .subagent)
        check("subagent Codex: a bounded tail can read followups without metadata", bounded.parse(line: inbound(prompt)).first?.text == "Check the child reader")
        check("subagent Codex: unknown envelopes and mismatched sender text are preserved",
              CodexTranscriptParser.agentMessageText(prompt, author: "/root/other") == prompt &&
              CodexTranscriptParser.agentMessageText("Plain task text", author: "/root") == "Plain task text")
        var parent = CodexTranscriptParser()
        check("subagent Codex: main scope does not import child task envelopes", parent.parse(line: inbound(prompt)).isEmpty)
        let legacy = child.parse(line: codex("response_item", ["type": "message", "role": "user",
                                                               "content": [["type": "input_text", "text": "Legacy child task"]]]))
        check("subagent Codex: ordinary user-message tasks remain supported", legacy.first?.text == "Legacy child task" && legacy.first?.author == "Parent")
    }

    private static func subagentTranscripts(_ base: URL) {
        let claude = base.appendingPathComponent("sidechain.jsonl")
        func message(_ id: String, _ type: String, _ content: Any) -> String {
            WorkFixture.line(["uuid": id, "type": type, "isSidechain": true, "message": ["role": type, "content": content]])
        }
        let lines = [message("prompt", "user", "Check the child reader"),
                     message("answer", "assistant", [["type": "text", "text": "The child reader renders **Markdown**."],
                                                        ["type": "tool_use", "id": "read", "name": "Read", "input": ["file_path": "Sources/Reader.swift"]]]),
                     message("result", "user", [["type": "tool_result", "tool_use_id": "read", "content": "A fixture tool result"]])]
        WorkFixture.write(claude, lines)
        let normal = TranscriptFollower(url: claude, kind: .claude, baseDir: base.path)
        check("subagent reader: ordinary readers still omit sidechains", normal.poll().isEmpty)
        let follower = TranscriptFollower(url: claude, kind: .claude, baseDir: base.path, scope: .subagent)
        let entries = follower.poll()
        check("subagent reader: sidechain prompt, answer, call and result are kept", entries.map(\.kind) == [.user, .assistant, .tool, .tool] && entries.last?.operation?.output == "A fixture tool result" && follower.entries.count == 3)
        check("subagent reader: a second poll never duplicates entries", follower.poll().isEmpty)
        WorkFixture.append(claude, [message("later", "assistant", "New child output")])
        check("subagent reader: follows only new complete lines", follower.poll().map(\.text) == ["New child output"])
        let splitReport = Data((message("split", "assistant", [["type": "tool_use", "id": "split-handback", "name": "SubagentHandback", "input": ["message": "A report written in two parts"]]]) + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: claude) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            let half = splitReport.count / 2
            try? handle.write(contentsOf: splitReport.prefix(half))
            check("subagent reader: a partial handback waits for its newline", follower.poll().isEmpty)
            try? handle.write(contentsOf: splitReport.dropFirst(half))
            check("subagent reader: the completed handback arrives once", follower.poll().map(\.text) == ["A report written in two parts"] && follower.poll().isEmpty)
        } else {
            check("subagent reader: partial-write fixture opens", false)
        }
        WorkFixture.write(claude, [message("reset", "user", "Replacement sidechain")])
        _ = follower.poll()
        check("subagent reader: truncation preserves sidechain mode", follower.entries.count == 1 && follower.entries.first?.text == "Replacement sidechain")
        WorkFixture.write(claude, lines)

        let codex = base.appendingPathComponent("child-rollout.jsonl")
        let codexLines = [
            #"{"type":"session_meta","payload":{"id":"child","parent_thread_id":"parent","thread_source":"subagent","agent_path":"/root/child"}}"#,
            #"{"type":"response_item","payload":{"type":"agent_message","author":"/root","recipient":"/root/child","content":[{"type":"input_text","text":"Message Type: NEW_TASK\nSender: /root\nPayload:\nCheck Codex rendering"},{"type":"encrypted_content","encrypted_content":"opaque-fixture"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"Codex child answer"}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"pwd\"}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","output":"Fixture command output"}}"#,
        ]
        WorkFixture.write(codex, codexLines)
        let child = TranscriptFollower(url: codex, kind: .codex, baseDir: base.path, scope: .subagent)
        check("subagent reader: Codex child rollout keeps prompt, answer, tools and results", child.poll().map(\.kind) == [.user, .assistant, .tool, .tool])

        let large = base.appendingPathComponent("large-child.jsonl")
        WorkFixture.write(large, [lines[0]] + (0..<3500).map { message("large-\($0)", "assistant", String(repeating: "x", count: 1000)) })
        let tail = TranscriptFollower(url: large, kind: .claude, baseDir: base.path, scope: .subagent)
        var delivered = false
        tail.onAppend = { _ in delivered = Thread.isMainThread }
        tail.start(follow: false)
        check("subagent reader: large attachments parse off main with a bounded tail", waitUntil(10) { delivered } && !tail.lastReadWasOnMain && tail.entries.count < 2500 && tail.entries.first?.kind == .user && tail.entries.contains { $0.id == "tail-notice" })

        let model = AppModel()
        let project = Project(path: base.path)
        let chat = Chat(projectID: project.id, agentID: "claude")
        model.projects = [project]
        model.chats = [chat]
        var agent = SubagentInfo(id: "reader", title: "Inspect the reader")
        model.updateSubagents([SidebarSubagent(agent)], for: chat.id)
        model.selectSubagent(agent.id, in: chat.id)
        let window = makeWindow()
        guard let host = window.contentView else { check("subagent reader: test window exists", false); return }
        let controller = SubagentReaderController(model: model)
        controller.install(in: host, top: host.topAnchor)
        controller.sync()
        let page = controller.reader.page
        check("subagent reader: read-only view has no native message box", !controller.root.subviews.contains { $0 is ComposerBox })
        check("subagent reader: selection can precede transcript discovery", waitUntil(10) {
            page.ready && (js(page, "document.body.textContent.includes('Waiting for this subagent')") as? Bool) == true
        })
        agent.transcript = claude.path
        model.updateSubagents([SidebarSubagent(agent)], for: chat.id)
        controller.sync()
        check("subagent reader: the real reader renders a Claude sidechain", waitUntil(10) { page.ready && (js(page, "document.body.textContent.includes('Check the child reader') && document.querySelector('strong') !== null") as? Bool) == true })
        agent.state = .done
        agent.transcript = nil
        model.updateSubagents([SidebarSubagent(agent)], for: chat.id)
        controller.sync()
        WorkFixture.append(claude, [message("final", "assistant", [["type": "tool_use", "id": "final-handback", "name": "SubagentHandback", "input": ["message": "Final **child output**"]]])])
        let handbackVisible = "Array.from(document.querySelectorAll('section.entry.assistant')).filter(e => e.textContent.includes('Final child output')).length === 1"
        check("subagent reader: retirement retains the path and renders a late handback", !controller.root.isHidden && model.subagentBrowser.selection?.agent.detail == "Finished" && waitUntil(5) { (js(page, handbackVisible) as? Bool) == true },
              "hidden=\(controller.root.isHidden) selection=\(String(describing: model.subagentBrowser.selection)) pageReady=\(page.ready) rendered=\(String(describing: js(page, handbackVisible)))")
        controller.reader.reload()
        check("subagent reader: reload preserves one complete handback answer", waitUntil(5) { (js(page, handbackVisible) as? Bool) == true })
        _ = model.backFromSubagent()
        controller.sync()
        check("subagent reader: navigation hides the finished view", controller.root.isHidden)
        model.updateSubagents([SidebarSubagent(SubagentInfo(id: "escape", title: "Escape test"))], for: chat.id)
        model.selectSubagent("escape", in: chat.id)
        controller.sync()
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            check("subagent reader: Esc returns to the parent", controller.handle(event) == nil && model.subagentBrowser.selection == nil)
        }
        controller.sync()
        let codexChat = Chat(projectID: project.id, agentID: "codex")
        model.chats.append(codexChat)
        agent.state = .running
        agent.transcript = codex.path
        model.updateSubagents([SidebarSubagent(agent)], for: codexChat.id)
        model.selectSubagent(agent.id, in: codexChat.id)
        controller.sync()
        check("subagent reader: the real reader renders a Codex task and child answer", waitUntil(5) {
            (js(page, "document.body.textContent.includes('Check Codex rendering') && document.body.textContent.includes('Codex child answer') && document.querySelector('.sender-label').textContent === 'From /root' && !document.body.textContent.includes('opaque-fixture') && !document.body.textContent.includes('Message Type:')") as? Bool) == true
        })
        agent.state = .done
        model.updateSubagents([SidebarSubagent(agent)], for: codexChat.id)
        controller.sync()
        WorkFixture.append(codex, [
            #"{"type":"response_item","payload":{"type":"agent_message","author":"/root","recipient":"/root/child","content":[{"type":"input_text","text":"Check the last result too"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"Codex final result"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Codex final result"}}"#,
        ])
        check("subagent reader: retired Codex selection follows the final message once", waitUntil(5) {
            (js(page, "document.body.textContent.includes('Check the last result too') && Array.from(document.querySelectorAll('section.entry.assistant')).filter(e => e.textContent.includes('Codex final result')).length === 1") as? Bool) == true
        })
        WorkFixture.append(codex, [
            #"{"type":"response_item","payload":{"type":"agent_message","author":"/root","recipient":"/root/child","content":[{"type":"input_text","text":"Message Type: MESSAGE\nSender: /root\nPayload:\n"},{"type":"encrypted_content","encrypted_content":"opaque-fixture"}]}}"#,
        ])
        check("subagent reader: encrypted message explains unavailable text without exposing payload", waitUntil(5) {
            (js(page, "document.querySelectorAll('.entry.notice[data-content-unavailable=\"encrypted-agent-message\"]').length === 1 && !document.body.textContent.includes('opaque-fixture') && !document.body.textContent.includes('Payload:')") as? Bool) == true
        })
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "[", charactersIgnoringModifiers: "[", isARepeat: false, keyCode: 33) {
            check("subagent reader: Cmd-[ returns to the parent", controller.handle(event) == nil && model.subagentBrowser.selection == nil)
        }
        controller.sync()
        controller.root.removeFromSuperview()
    }
}


extension SelfTest {
    /// One ordinary chat establishes the title column beside collapsed and expanded trees.
    private static func subagentSidebarSnapshots(_ dir: URL, fixtureDirectory: URL) {
        let out = dir.deletingLastPathComponent().appendingPathComponent("snapshots", isDirectory: true)
        Paths.ensure(out)
        Theme.configure(from: GhosttyApp.shared)
        let previousPhase = ActivityDot.fixedPhase
        let previousPulse = ActivityDot.backgroundPulses
        ActivityDot.fixedPhase = 0.45
        ActivityDot.backgroundPulses = false
        defer {
            ActivityDot.fixedPhase = previousPhase
            ActivityDot.backgroundPulses = previousPulse
        }

        let model = AppModel()
        let project = Project(path: fixtureDirectory.appendingPathComponent("Reader").path)
        model.projects = [project]
        func chat(_ title: String, activity: AgentActivity, detail: String) -> Chat {
            let chat = Chat(projectID: project.id, agentID: "claude")
            chat.terminalTitle = title
            chat.activity = activity
            chat.activityDetail = detail
            return chat
        }
        let ordinary = chat("Review the changes", activity: .idle, detail: "Ready")
        let collapsed = chat("Research file previews", activity: .background, detail: "2 agents running in background")
        let expanded = chat("Improve the reader", activity: .background, detail: "2 agents running in background")
        model.chats = [ordinary, collapsed, expanded]
        model.updateSubagents([
            SidebarSubagent(SubagentInfo(id: "formats", title: "Compare file formats")),
            SidebarSubagent(SubagentInfo(id: "media", title: "Review media handling")),
        ], for: collapsed.id)
        var running = SubagentInfo(id: "render", title: "Check rendering")
        running.step = "Reading the renderer"
        var waiting = SubagentInfo(id: "previews", title: "Review previews")
        waiting.state = .waiting
        var nested = SubagentInfo(id: "pdf", title: "Check PDF previews")
        nested.parentID = waiting.id
        nested.step = "Running preview checks"
        model.updateSubagents([running, waiting, nested].map(SidebarSubagent.init), for: expanded.id)
        model.selectSubagent(nested.id, in: expanded.id)

        let window = makeWindow()
        func render<V: View>(_ content: V, size: NSSize, name: String, dark: Bool) -> Bool {
            let host = NSHostingView(rootView: AnyView(content.environmentObject(model).environment(\.colorScheme, dark ? .dark : .light)))
            host.sizingOptions = []
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: size)
            window.contentView?.addSubview(host)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            defer { host.removeFromSuperview() }
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
            return (try? png.write(to: out.appendingPathComponent(name))) != nil
        }

        let section = ProjectSection(project: project)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.hChrome)
        for dark in [true, false] {
            let appearance = dark ? "dark" : "light"
            for narrow in [false, true] {
                let width = narrow ? "narrow" : "normal"
                let sidebarName = "sidebar-subagents-\(width)-\(appearance).png"
                let headerName = "main-subagent-header-\(width)-\(appearance).png"
                let sidebar = render(section, size: NSSize(width: narrow ? 200 : 260, height: 300), name: sidebarName, dark: dark)
                let header = render(ChatHeader(), size: NSSize(width: narrow ? 420 : 760, height: 40), name: headerName, dark: dark)
                check("snapshot: subagent sidebar and header at \(width) width in \(appearance) mode", sidebar && header)
            }
        }
        print("      subagent snapshots in \(out.path)")
    }
}
