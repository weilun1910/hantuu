import AppKit

extension SelfTest {
    static func queuedMessages(_ dir: URL) {
        func line(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        func queued(_ id: String, _ prompt: Any, origin: String = "human", mode: String = "prompt") -> Data {
            line(["type": "attachment", "uuid": id, "attachment": ["type": "queued_command", "prompt": prompt,
                  "origin": ["kind": origin], "commandMode": mode, "source_uuid": "source-" + id]])
        }
        var claude = ClaudeTranscriptParser()
        let a = claude.parse(line: queued("q1", "Use the smaller version"))
        check("queue: Claude human string attachments render as user messages", a.count == 1 && a[0].kind == .user && a[0].text == "Use the smaller version")
        let image: [String: Any] = ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "cGljdHVyZQ=="]]
        let b = claude.parse(line: queued("q2", [["type": "text", "text": "[Image #1] Use this"], image]))
        check("queue: Claude block prompts keep their images", b.count == 1 && b[0].images == ["data:image/png;base64,cGljdHVyZQ=="] && b[0].text == "[Image #1] Use this")
        for origin in ["task-notification", "peer", "coordinator"] {
            check("queue: non-human \(origin) stays hidden", claude.parse(line: queued(origin, "Internal message", origin: origin)).isEmpty)
        }
        check("queue: task notifications never become user messages", claude.parse(line: queued("task", "Internal message", mode: "task-notification")).isEmpty)
        let command = claude.parse(line: queued("cmd", "<command-name>/compact</command-name><command-args>keep tests</command-args>", mode: "command"))
        check("queue: delivered commands use the normal command notice", command.first?.kind == .notice && command.first?.text == "Ran /compact keep tests")
        let duplicate = claude.parse(line: line(["type": "user", "uuid": "source-q1", "message": ["content": "Use the smaller version"]]))
        check("queue: a regular line with the same source identity is not repeated", duplicate.isEmpty)
        let repeated = claude.parse(line: line(["type": "user", "uuid": "another", "message": ["content": "Use the smaller version"]]))
        check("queue: intentionally repeating the same text remains visible", repeated.count == 1)

        var pending = PendingReaderMessages()
        let old = ReaderEntry(id: "old", kind: .user, text: "Use this")
        pending.enqueue(id: "p1", text: "  Use this\r\n", files: [], agentID: "claude", existing: [old])
        check("queue: sending shows a pending user entry immediately", pending.entries.first?.pending == true && pending.entries.first?.text == "Use this")
        _ = pending.reconcile([old])
        check("queue: old matching history cannot consume a pending send", pending.entries.count == 1)
        pending.enqueue(id: "p2", text: "Use this", files: [], agentID: "claude", existing: [old])
        let delivered = ReaderEntry(id: "new", kind: .user, text: "Use this")
        let matched = pending.reconcile([delivered])
        check("queue: delivery consumes only the first matching pending send", matched.first?.replacesPendingID == "p1" && pending.entries.map(\.id) == ["p2"])
        _ = pending.reconcile([old, delivered])
        check("queue: replaying a delivery cannot consume a second identical send", pending.entries.map(\.id) == ["p2"])
        check("queue: restored input can identify a silent queue drop",
              pending.isRestored(in: "────────────────────\n❯ Use this\n────────────────────\n? for shortcuts"))
        check("queue: an empty input box is not a silent queue drop",
              !pending.isRestored(in: "────────────────────\n❯ \n────────────────────\n? for shortcuts"))
        pending.removeAll()
        check("queue: stopping discards pending sends", pending.isEmpty)

        let picture = ComposerMessage.OutgoingFile(path: dir.appendingPathComponent("queue picture.png").path, image: true)
        pending.enqueue(id: "pic", text: "Use this", files: [picture], agentID: "claude", existing: [])
        check("queue: pending pictures render from their local paths", pending.entries.first?.images == [picture.path])
        check("queue: image chips match a delivered block prompt", pending.reconcile(b).first?.replacesPendingID == "pic" && pending.isEmpty)
        let file = ComposerMessage.OutgoingFile(path: dir.appendingPathComponent("queue notes.txt").path, image: false)
        pending.enqueue(id: "file", text: "Read", files: [file], agentID: "claude", existing: [])
        let fileEntry = ReaderEntry(id: "file-delivery", kind: .user, text: "Read " + ShellEscape.escape(file.path))
        check("queue: escaped file paths match the outgoing text", pending.reconcile([fileEntry]).first?.replacesPendingID == "file")
        pending.enqueue(id: "image-only", text: nil, files: [picture], agentID: "codex", existing: [])
        let imageOnly = ReaderEntry(id: "image-delivery", kind: .user, text: "[Image #3]", images: ["data:image/png;base64,cGljdHVyZQ=="])
        check("queue: image-only sends match without relying on chip numbering", pending.reconcile([imageOnly]).first?.replacesPendingID == "image-only")
        pending.enqueue(id: "command", text: "/compact keep tests", files: [], agentID: "claude", existing: [])
        check("queue: a command notice acknowledges a pending command", pending.reconcile(command).first?.replacesPendingID == "command")
        pending.enqueue(id: "interrupted", text: "Do this next", files: [], agentID: "claude", existing: [])
        _ = pending.reconcile([ReaderEntry(id: "stop", kind: .notice, text: "Interrupted")])
        check("queue: a terminal interruption drops undelivered bubbles", pending.isEmpty)

        let project = UUID()
        let first = Chat(projectID: project, agentID: "claude")
        let second = Chat(projectID: project, agentID: "codex")
        first.pendingMessages.enqueue(id: "first", text: "First chat", files: [], agentID: "claude", existing: [])
        second.pendingMessages.enqueue(id: "second", text: "Second chat", files: [], agentID: "codex", existing: [])
        check("queue: chats own separate pending messages", first.pendingMessages.entries.first?.text == "First chat" && second.pendingMessages.entries.first?.text == "Second chat")
        first.status = .ended
        check("queue: ending one chat drops only its queue", first.pendingMessages.isEmpty && second.pendingMessages.entries.count == 1)

        var codex = CodexTranscriptParser()
        let rollout: [[String: Any]] = [
            ["type": "event_msg", "payload": ["type": "task_started"]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Working"]]]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": "Change direction"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Change direction"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Changed"]]]],
        ]
        let entries = rollout.flatMap { codex.parse(line: line($0)) }
        check("queue: Codex mid-turn messages retain transcript order without event duplicates", entries.map(\.text) == ["Working", "Change direction", "Changed"])
        pending.enqueue(id: "codex", text: "Change direction", files: [], agentID: "codex", existing: [])
        check("queue: Codex delivery replaces its pending bubble", pending.reconcile(entries).contains { $0.replacesPendingID == "codex" } && pending.isEmpty)
        pending.enqueue(id: "codex-image", text: "Use this", files: [picture], agentID: "codex", existing: [])
        let wrapped = ReaderEntry(id: "wrapped", kind: .user, text: "<image name=[Image #1] path=\"/tmp/picture.png\">\n\n</image>\n\n[Image #1] Use this", images: ["data:image/png;base64,cGljdHVyZQ=="])
        check("queue: Codex image wrappers do not prevent matching", pending.reconcile([wrapped]).first?.replacesPendingID == "codex-image")
        queuedMessageRendering()
    }

    static func queuedMessageRendering() {
        guard Paths.webRoot != nil else { check("queue: web assets found", false); return }
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let page = WebPage(page: "reader.html?layout=main", identifier: "selftest.queue")
        page.webView.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        window.contentView?.addSubview(page.webView)
        guard waitUntil(10, { page.ready }) else { check("queue: reader loads", false); return }
        _ = js(page, """
            window.hantuu.reset({chatID:'queue', entries:[], pending:[{id:'pending',kind:'user',text:'Next thought',pending:true}]});
            window.queueBubble = document.querySelector('.entry.pending');
            0
            """)
        check("queue: the reader renders a visible Queued label", js(page, "document.querySelector('.queued-label').textContent === 'Queued' && getComputedStyle(document.querySelector('.queued-label')).display !== 'none'") as? Bool == true)
        _ = js(page, """
            window.hantuu.append({chatID:'queue', entries:[{id:'assistant',kind:'assistant',text:'Still working'}], pending:[{id:'pending',kind:'user',text:'Next thought',pending:true}]});
            0
            """)
        check("queue: new transcript output stays before the pending bubble", js(page, "document.getElementById('entries').lastElementChild === window.queueBubble") as? Bool == true)
        _ = js(page, """
            window.hantuu.append({chatID:'queue', entries:[{id:'delivered',kind:'user',text:'Next thought',replacesPendingID:'pending'}], pending:[]});
            0
            """)
        check("queue: delivery keeps the same bubble and removes its label", js(page, "document.querySelector('[data-id=delivered]') === window.queueBubble && !document.querySelector('.queued-label') && document.querySelectorAll('.entry.user').length === 1") as? Bool == true)
        _ = js(page, """
            window.hantuu.pending({chatID:'queue',pending:[{id:'stop-me',kind:'user',text:'Stopped',pending:true}]});
            window.hantuu.pending({chatID:'another-chat',pending:[]});
            0
            """)
        check("queue: another chat cannot remove the visible pending bubble", js(page, "document.querySelectorAll('.entry.pending').length === 1") as? Bool == true)
        _ = js(page, "window.hantuu.pending({chatID:'queue',pending:[]}); 0")
        check("queue: dropping pending entries leaves delivered entries intact", js(page, "!document.querySelector('.entry.pending') && document.querySelectorAll('.entry').length === 2") as? Bool == true)
    }
}
