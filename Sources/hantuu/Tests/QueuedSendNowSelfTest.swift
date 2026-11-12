import AppKit

extension SelfTest {
    static func queuedSendNow(_ dir: URL) {
        check("send now: Claude uses the documented universal chord",
              QueuedSendNow.action(agentID: "claude")?.keys == [
                TerminalKeyStroke(keyCode: 7, codepoint: 120, modifiers: .control),
                TerminalKeyStroke(keyCode: 1, codepoint: 115, modifiers: .control),
              ])
        check("send now: Codex promotes pending Enter steers with Escape",
              QueuedSendNow.action(agentID: "codex")?.keys == [TerminalKeyStroke(keyCode: 53, codepoint: 27)])
        check("send now: unsupported agents have no action", QueuedSendNow.action(agentID: "other") == nil)
        check("send now: Codex requires its actual Escape promotion hint",
              QueuedSendNow.available(agentID: "codex", screen: "Messages to be submitted after next tool call\n(press esc to interrupt and send immediately)") &&
              !QueuedSendNow.available(agentID: "codex", screen: "esc to interrupt") &&
              !QueuedSendNow.available(agentID: "codex", screen: "ctrl+c to interrupt and send immediately"))
        check("send now: Claude requires its native queue hint",
              QueuedSendNow.available(agentID: "claude", screen: "ctrl+enter to send now") &&
              !QueuedSendNow.available(agentID: "claude", screen: "esc to interrupt"))
        for hint in ["Press up to edit queued messages",
                     "Press up to select a queued message, then Enter to edit it",
                     "Press up to edit queued messages, Enter to send them immediately",
                     "Press up to select a queued message to edit, or Enter to send them now"] {
            check("send now: Claude native queue placeholder enables the action",
                  QueuedSendNow.available(agentID: "claude", screen: "────────\n❯ " + hint + "\n────────\nesc to interrupt"))
            check("send now: quoted queue placeholder cannot enable the action",
                  !QueuedSendNow.available(agentID: "claude", screen: hint + "\n────────\n❯ \n────────\nesc to interrupt"))
        }
        check("send now: Claude editing a selected queue item is not a promotion hint",
              !QueuedSendNow.available(agentID: "claude", screen: "❯ Press Enter to edit selected message"))
        check("send now: Codex wrapped promotion hint remains eligible",
              QueuedSendNow.available(agentID: "codex", screen: "Messages to be submitted after next tool call\n(press esc to interrupt and\nsend immediately)") &&
              !QueuedSendNow.available(agentID: "codex", screen: "Queued follow-up inputs\nesc to interrupt"))
        for agent in ["claude", "codex", "other"] {
            var pending = PendingReaderMessages()
            pending.sendNowEnabled = true
            for id in ["one", "two"] {
                pending.enqueue(id: id, text: id, files: [], agentID: agent, existing: [])
            }
            check("send now: \(agent) hides the action until terminal submission", pending.entries.allSatisfy { $0.sendNowLabel == nil })
            for id in ["one", "two"] { pending.markSubmitted(id: id) }
            let supported = agent != "other"
            check("send now: \(agent) only offers supported pending actions",
                  pending.entries.allSatisfy { ($0.sendNowLabel == "Send queue now") == supported })
            let requested = pending.requestDelivery(id: "two")
            check("send now: \(agent) promotes the entire supported queue", requested == supported &&
                  pending.entries.allSatisfy { ($0.deliveryRequested == true) == supported && $0.sendNowLabel == nil })
            check("send now: \(agent) cannot repeat the same request", !pending.requestDelivery(id: "two"))
            if supported {
                check("send now: \(agent) temporary restored input does not cancel delivery",
                      !pending.isRestored(in: "────────────────────\n❯ one\n────────────────────\n? for shortcuts"))
            }
            _ = pending.reconcile([ReaderEntry(id: "interrupt", kind: .notice, text: "Turn interrupted")])
            check("send now: \(agent) retains requested deliveries across native interruption", pending.entries.count == 2 && pending.entries.allSatisfy { $0.pendingState == "Delivery unconfirmed" })
            let delivered = pending.reconcile([ReaderEntry(id: "delivered-one", kind: .user, text: "one"),
                                               ReaderEntry(id: "delivered-two", kind: .user, text: "two")])
            check("send now: \(agent) reconciles each acknowledgement once", pending.isEmpty &&
                  delivered.compactMap(\.replacesPendingID) == ["one", "two"])
        }
        var combined = PendingReaderMessages()
        combined.sendNowEnabled = true
        for id in ["first", "second"] {
            combined.enqueue(id: id, text: id, files: [], agentID: "codex", existing: [])
            combined.markSubmitted(id: id)
        }
        _ = combined.requestDelivery(id: "first")
        let merged = combined.reconcile([ReaderEntry(id: "merged", kind: .user, text: "first\nsecond")])
        check("send now: a combined Codex acknowledgement consumes the entire promoted batch",
              combined.isEmpty && merged.first?.replacesPendingIDs == ["first", "second"])
        queuedSendNowRendering()
        for agent in ["claude", "codex"] { queuedSendNowTerminal(dir, agent: agent) }
    }

    private static func queuedSendNowRendering() {
        guard Paths.webRoot != nil else { check("send now: web assets found", false); return }
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let page = WebPage(page: "reader.html?layout=main", identifier: "selftest.send-now")
        page.webView.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        window.contentView?.addSubview(page.webView)
        guard waitUntil(10, { page.ready }) else { check("send now: reader loads", false); return }
        _ = js(page, """
            window.hantuu.reset({chatID:'queue',entries:[{id:'done',kind:'user',text:'Done'}],pending:[
              {id:'supported',kind:'user',text:'Next',pending:true},
              {id:'unsupported',kind:'user',text:'Other',pending:true}]});
            window.queueBubble = document.querySelector('[data-id=supported]'); 0
            """)
        check("send now: unconfirmed native queue has no button", js(page, "!document.querySelector('.send-now')") as? Bool == true)
        _ = js(page, """
            window.hantuu.append({chatID:'queue',entries:[{id:'work',kind:'tool',text:'Running',operation:{name:'Shell',state:'running'}}],pending:[
              {id:'supported',kind:'user',text:'Next',pending:true,sendNowLabel:'Send queue now'},
              {id:'unsupported',kind:'user',text:'Other',pending:true}]}); 0
            """)
        check("send now: late native hint survives parity rendering without replacing its bubble",
              js(page, "document.querySelector('.parity-entry') !== null && document.querySelector('[data-id=supported]') === window.queueBubble && window.queueBubble.querySelector('.send-now') !== null") as? Bool == true)
        check("send now: only supported pending bubbles have a native button",
              js(page, "document.querySelectorAll('button.send-now').length === 1 && document.querySelector('.send-now').tabIndex === 0 && document.querySelector('.send-now').textContent === 'Send queue now'") as? Bool == true)
        check("send now: queue buttons can receive keyboard focus",
              js(page, "window.hantuu.focusQueue() && document.activeElement.classList.contains('send-now')") as? Bool == true)
        _ = js(page, """
            window.hantuu.pending({chatID:'queue',pending:[{id:'supported',kind:'user',text:'Next',pending:true,deliveryRequested:true}]}); 0
            """)
        check("send now: Delivering replaces Queued without rebuilding the bubble",
              js(page, "document.querySelector('[data-id=supported]') === window.queueBubble && window.queueBubble.querySelector('.queued-label').textContent === 'Delivering' && !document.querySelector('.send-now')") as? Bool == true)
        _ = js(page, """
            window.hantuu.append({chatID:'queue',entries:[{id:'received',kind:'user',text:'Next',replacesPendingID:'supported'}],pending:[]}); 0
            """)
        check("send now: transcript acknowledgement removes the delivery state",
              js(page, "document.querySelector('[data-id=received]') === window.queueBubble && !document.querySelector('.queued-label') && !document.querySelector('.send-now')") as? Bool == true)
        _ = js(page, """
            window.hantuu.pending({chatID:'queue',pending:[{id:'a',kind:'user',text:'A',pending:true},{id:'b',kind:'user',text:'B',pending:true}]});
            window.hantuu.append({chatID:'queue',entries:[{id:'merged',kind:'user',text:'A and B',replacesPendingIDs:['a','b']}],pending:[]}); 0
            """)
        check("send now: combined delivery renders one canonical bubble",
              js(page, "document.querySelector('[data-id=merged]').textContent.includes('A and B') && !document.querySelector('[data-id=a]') && !document.querySelector('[data-id=b]') && !document.querySelector('.entry.pending')") as? Bool == true)
    }

    private static func queuedSendNowTerminal(_ dir: URL, agent: String) {
        guard let ghostty = GhosttyApp.shared ?? GhosttyApp.start() else { check("send now: libghostty", false); return }
        let file = dir.appendingPathComponent("send-now-" + agent + ".bin")
        let hint = agent == "codex" ? "(press esc to interrupt and send immediately)" : "❯ Press up to edit queued messages"
        let prompt = "? for shortcuts\nesc to interrupt\n" + hint + "\n"
        let script = "stty raw -echo; printf %s " + ShellEscape.quote(prompt) + "; exec cat -u > " + ShellEscape.quote(file.path)
        let terminal = TerminalView(app: ghostty.app, launch: .init(workingDirectory: dir.path,
                                    command: "/bin/sh -c " + ShellEscape.quote(script)), handlesChildExit: true)
        let model = AppModel()
        let project = Project(path: dir.path)
        let chat = Chat(projectID: project.id, agentID: agent)
        chat.terminal = terminal
        chat.activity = .working
        model.projects = [project]
        model.chats = [chat]
        model.selectedChatID = chat.id
        let settings = ChatSettings(file: dir.appendingPathComponent("send-now-" + agent + ".json"))
        settings.showChatsAsReader = true
        let controller = ReaderModeController(model: model, mode: ReaderMode(settings: settings),
                                              commandCatalog: ReaderCommandCatalog(home: dir))
        controller.statusProvider = { _ in nil }
        let window = makeWindow()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        window.contentView = host
        terminal.frame = host.bounds
        host.addSubview(terminal)
        controller.install(in: host, top: host.topAnchor, above: terminal)
        defer { terminal.destroy(); window.orderOut(nil) }
        _ = controller.sync(selected: chat)
        let ready = waitUntil(10) {
            controller.refresh()
            return controller.composerMode.isWorking && terminal.activeScreenText().contains(hint) && controller.reader?.page.ready == true
        }
        guard ready, let page = controller.reader?.page else { check("send now: \(agent) fake terminal ready", false); return }
        for id in ["first", "second"] {
            chat.pendingMessages.enqueue(id: id, text: id, files: [], agentID: agent, existing: [])
            chat.pendingMessages.markSubmitted(id: id)
        }
        controller.refresh()
        func bytes() -> Data { (try? Data(contentsOf: file)) ?? Data() }
        check("send now: \(agent) stale chat and message identities are rejected",
              !controller.sendNow(chatID: UUID(), id: "first") && !controller.sendNow(chatID: chat.id, id: "missing") && bytes().isEmpty)
        chat.activity = .needsPermission
        controller.refresh()
        check("send now: \(agent) permission menus cannot be answered by the action",
              !controller.sendNow(chatID: chat.id, id: "first") && bytes().isEmpty)
        chat.activity = .working
        controller.refresh()
        let shown = waitUntil(5) { js(page, "document.querySelectorAll('.send-now').length") as? Int == 2 }
        check("send now: \(agent) shows one action on each queued bubble", shown)
        if let event = keyEvent(48, "\t", mods: .shift, window: window) { controller.composer.textView.keyDown(with: event) }
        check("send now: \(agent) Shift-Tab reaches a queue action",
              waitUntil(3) { (page.webView as? FocuslessWebView)?.allowsQueueFocus == true &&
                  js(page, "document.activeElement.classList.contains('send-now')") as? Bool == true })
        _ = js(page, "document.querySelector('.send-now').click(); 0")
        let expected = Data(agent == "claude" ? [0x18, 0x13] : [0x1b])
        check("send now: \(agent) button sends only the native key bytes", waitUntil(5) { bytes() == expected }, bytes().description)
        check("send now: \(agent) marks both bubbles Delivering", chat.pendingMessages.entries.allSatisfy { $0.deliveryRequested == true })
        check("send now: \(agent) ignores repeated clicks", !controller.sendNow(chatID: chat.id, id: "second") && bytes() == expected)
        let delivered = chat.pendingMessages.reconcile([ReaderEntry(id: "interrupted", kind: .notice, text: "Interrupted"),
                                                        ReaderEntry(id: "real-first", kind: .user, text: "first"),
                                                        ReaderEntry(id: "real-second", kind: .user, text: "second")])
        model.readerAppend.send((chat.id, delivered))
        check("send now: \(agent) reconciles real entries after interruption", chat.pendingMessages.isEmpty &&
              waitUntil(5) { js(page, "document.querySelectorAll('.entry.user').length === 2 && !document.querySelector('.entry.pending')") as? Bool == true })
        chat.pendingMessages.enqueue(id: "shortcut", text: "shortcut", files: [], agentID: agent, existing: delivered)
        chat.pendingMessages.markSubmitted(id: "shortcut")
        controller.refresh()
        controller.composer.textView.text = "Keep this draft"
        let event = keyEvent(agent == "claude" ? 36 : 53, agent == "claude" ? "\r" : "\u{1b}",
                             mods: agent == "claude" ? .control : [], window: window)
        if let event { controller.composer.textView.keyDown(with: event) }
        check("send now: \(agent) composer shortcut preserves its draft and sends the native action",
              waitUntil(5) { bytes() == expected + expected } && controller.composer.textView.text == "Keep this draft" &&
              chat.pendingMessages.entries.first?.deliveryRequested == true)

        // The default reader Queue stays editable until its own Send now action is used.
        // The screen can report work before the structured activity hook catches up.
        chat.pendingMessages = PendingReaderMessages()
        chat.activity = .idle
        controller.refresh()
        let mark = bytes().count
        controller.composer.textView.text = "local waiting message"
        let queued = controller.send()
        let localID = chat.pendingMessages.entries.first?.id
        check("send now: \(agent) default Queue creates a bubble without terminal bytes", queued &&
              localID.map { chat.pendingMessages.stage(id: $0) == .waiting } == true && bytes().count == mark)
        check("queue: \(agent) busy screen holds Queue before activity catches up", queued && chat.activity == .idle && chat.pendingMessages.firstWaitingID == localID)
        chat.activity = .working
        controller.refresh()
        controller.composer.textView.text = "Preserve this next draft"
        let localButton = waitUntil(5) {
            js(page, "Array.from(document.querySelectorAll('.queue-action')).some(b => b.textContent === 'Send now')") as? Bool == true
        }
        check("send now: \(agent) waiting bubble has Send now", localButton)
        if localButton {
            _ = js(page, "Array.from(document.querySelectorAll('.queue-action')).find(b => b.textContent === 'Send now').click(); 0")
        }
        let promoted = waitUntil(5) { chat.pendingMessages.entries.first?.deliveryRequested == true && !controller.isTyping &&
            Data(bytes().dropFirst(mark)) == Data("local waiting message\r".utf8) + expected }
        let newBytes = Data(bytes().dropFirst(mark))
        check("send now: \(agent) local action submits once then uses native promotion", promoted &&
              newBytes == Data("local waiting message\r".utf8) + expected && controller.composer.textView.string == "Preserve this next draft")
        chat.pendingMessages = PendingReaderMessages()
        let steerMark = bytes().count
        controller.composer.textView.text = "explicit steer"
        controller.composer.textView.onAlternateSend?()
        check("send now: \(agent) alternate send explicitly steers", waitUntil(5) { !controller.isTyping && Data(bytes().dropFirst(steerMark)) == Data("explicit steer\r".utf8) } &&
              Data(bytes().dropFirst(steerMark)) == Data("explicit steer\r".utf8) && chat.pendingMessages.entries.first.map { chat.pendingMessages.stage(id: $0.id) == .sent } == true)

        chat.pendingMessages = PendingReaderMessages()
        controller.composer.textView.text = "keyboard waiting message"
        let keyboardQueued = controller.send()
        let keyboardMark = bytes().count
        let localShortcut = keyEvent(agent == "claude" ? 36 : 53, agent == "claude" ? "\r" : "\u{1b}",
                                     mods: agent == "claude" ? .control : [], window: window)
        if let localShortcut { controller.composer.textView.keyDown(with: localShortcut) }
        if agent == "claude" {
            check("send now: Claude Control-Return promotes the local queue", keyboardQueued && waitUntil(5) {
                Data(bytes().dropFirst(keyboardMark)) == Data("keyboard waiting message\r".utf8) + expected &&
                    chat.pendingMessages.entries.first?.deliveryRequested == true
            })
        } else {
            check("queue: Codex Escape keeps Stop behavior for input still held locally", keyboardQueued && waitUntil(5) {
                Data(bytes().dropFirst(keyboardMark)) == Data([0x1b])
            } && chat.pendingMessages.queuePaused && chat.pendingMessages.firstWaitingID != nil)
        }
    }
}
