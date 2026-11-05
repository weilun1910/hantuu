import AppKit

/// `HANTUU_LIVE_AGENT=claude scripts/selftest.sh` (or `=codex`): runs a real agent in a real
/// libghostty surface, offscreen, with exactly the command line and environment a hantuu chat
/// gets, and watches StatusCenter move it through its states. Off by default: it costs a few
/// tiny prompts. It never approves anything: permission prompts and questions are dismissed
/// with Esc, in the agent's own terminal.
extension SelfTest {
    final class LiveEvents: TerminalEvents {
        let chat: Chat
        let center: StatusCenter
        init(chat: Chat, center: StatusCenter) { self.chat = chat; self.center = center }
        func terminalTitleDidChange(_ view: TerminalView, title: String) { chat.terminalTitle = title }
        func terminalNeedsAttention(_ view: TerminalView, reason: String) {
            print("      live: terminal says \(reason)")
            center.terminalAttention(chat, reason: reason)
        }
        func terminalChildDidExit(_ view: TerminalView, code: Int) { chat.status = .ended }
        func terminalRequestedClose(_ view: TerminalView, processAlive: Bool) { if !processAlive { chat.status = .ended } }
        func terminalFocusDidChange(_ view: TerminalView, focused: Bool) {}
    }

    static func key(_ code: UInt16, _ chars: String, into view: TerminalView, window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let ev = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: code) else { continue }
            if type == .keyDown { view.keyDown(with: ev) } else { view.keyUp(with: ev) }
        }
    }

    static func liveAgent(_ dir: URL) {
        guard let which = ProcessInfo.processInfo.environment["HANTUU_LIVE_AGENT"], ["claude", "codex"].contains(which) else { return }
        guard let g = GhosttyApp.shared ?? GhosttyApp.start() else { check("live: libghostty", false); return }
        setvbuf(stdout, nil, _IOLBF, 0)   // show progress as it happens
        let scratch = dir.deletingLastPathComponent().appendingPathComponent("agent-scratch", isDirectory: true)
        Paths.ensure(scratch)
        try? "hello from the hantuu status check\n".write(to: scratch.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)

        let model = AppModel()
        let project = Project(path: scratch.path)
        model.projects = [project]
        let center = StatusCenter()
        let rec = NoticeRecorder()
        center.notifier = rec
        center.appIsActive = { false }
        center.start(model: model, live: false)
        TerminalSignals.handler = { view, signal in
            print("      live: terminal signal \(signal)")
            center.terminal(view, signal)
        }
        defer { TerminalSignals.handler = nil }

        let chat = Chat(projectID: project.id, agentID: which)
        if which == "claude" { chat.sessionID = UUID().uuidString.lowercased() }
        let def = AgentCatalog.definition(which)
        var argv = def.launchArguments(sessionID: chat.sessionID)
        // Felix runs Claude in auto mode, where a harmless command never prompts. The check
        // asks for the stricter default mode so a prompt appears (and is then declined).
        if which == "claude" { argv += ["--permission-mode", "default"] }
        // Same for Codex: a read-only sandbox makes a write ask for approval.
        // Felix's own SessionStart hook in ~/.codex/hooks.json waits for review at startup.
        // The check must neither trust nor disable it, so this run turns hooks off for itself
        // only (hantuu's Codex signals don't use hooks).
        if which == "codex" {
            argv += ["-c", "approval_policy=\"on-request\"", "-c", "sandbox_mode=\"read-only\"", "-c", "features.hooks=false"]
        }
        let env = ["HANTUU_CHAT_ID": chat.id.uuidString].merging(AgentHooks.environment(for: chat.id)) { a, _ in a }
        let w = makeWindow()
        let view = TerminalView(app: g.app, launch: .init(workingDirectory: scratch.path, command: LoginShell.surfaceCommand(argv), environment: env),
                                handlesChildExit: true)
        let events = LiveEvents(chat: chat, center: center)
        view.events = events
        view.frame = w.contentView!.bounds
        w.contentView!.addSubview(view)
        w.makeFirstResponder(view)
        chat.terminal = view
        chat.startedAt = Date()
        model.chats = [chat]
        print("      live: \(which) in \(scratch.path), events \(AgentHooks.eventsFile(for: chat.id).path)")

        // A timeline of every state the chat passes through.
        var timeline: [(TimeInterval, AgentActivity, String)] = []
        let t0 = Date()
        func tick() {
            center.poll()
            if chat.transcriptPath == nil {
                if which == "claude", let sid = chat.sessionID, let u = ClaudeTranscriptParser.locate(sessionID: sid, cwd: scratch.path) {
                    chat.transcriptPath = u.path
                } else if which == "codex", let (u, _) = CodexTranscriptParser.locate(cwd: scratch.path, after: chat.startedAt, excluding: []) {
                    chat.transcriptPath = u.path
                }
            }
            let last = timeline.last
            if last?.1 != chat.activity || last?.2 != chat.activityDetail {
                timeline.append((Date().timeIntervalSince(t0), chat.activity, chat.activityDetail))
                print(String(format: "      live: %6.1fs  %@  %@", Date().timeIntervalSince(t0), chat.activity.rawValue, chat.activityDetail))
            }
        }
        func wait(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
            // An agent that exits early ends the wait instead of running out the clock.
            waitUntil(timeout) { tick(); return cond() || chat.activity == .ended } && cond()
        }
        func send(_ text: String) {
            view.pasteText(text)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            type("\r", into: view, window: w)
        }
        func blocked() -> Bool {
            let s = view.screenText().lowercased()
            return s.contains("do you trust") || s.contains("trust the files") || s.contains("trust this folder") || s.contains("trust the contents")
                || s.contains("allow codex to work in this folder")
        }
        defer {
            if chat.status != .ended { view.destroy() }   // only the process this test started
            print("      live: screen at the end:\n" + view.screenText().split(separator: "\n").suffix(12).map { "        | " + $0 }.joined(separator: "\n"))
        }

        // Ready: hooks report a session start (Claude), or the TUI has drawn (Codex).
        let ready = wait(60) {
            if blocked() { return true }
            if which == "claude" { return center.state(of: chat.id)?.structured == true }
            return view.screenText().contains("›") || view.screenText().lowercased().contains("context left")
        }
        if blocked() {
            check("live \(which): stopped at a folder-trust prompt (not accepting it)", false, "trust it once yourself, then rerun")
            return
        }
        check("live \(which): started, hooks reporting", ready, view.screenText().suffix(400).description)
        guard ready else { return }
        _ = wait(3) { false }
        func screen(_ label: String) {
            print("      live: screen \(label):\n" + view.screenText().split(separator: "\n").suffix(16).map { "        | " + $0 }.joined(separator: "\n"))
        }
        screen("before the first prompt")

        if which == "claude" {
            send("Use the Bash tool to run exactly this command: touch hantuu-probe.txt. Do nothing else.")
            let working = wait(60) { chat.activity == .working }
            check("live claude: prompt -> Working", working)
            let perm = wait(120) { chat.activity == .needsPermission }
            check("live claude: Bash -> Needs permission, quoting the command", perm && chat.activityDetail.hasPrefix("Wants to run Bash: touch"), chat.activityDetail)
            let notifiedPerm = rec.posted.last.map { !$0.isDone && $0.body.hasPrefix("Wants to run Bash: touch") } ?? false
            check("live claude: one notification for it", notifiedPerm, "\(rec.posted)")
            _ = wait(1) { false }
            key(53, "\u{1b}", into: view, window: w)   // Esc: decline, in the agent's own terminal
            let declined = wait(30) { chat.activity == .idle }
            check("live claude: Esc at the prompt -> Idle, Interrupted (from the transcript)", declined && chat.activityDetail == "Interrupted", chat.activityDetail)

            _ = wait(2) { false }
            send("Reply with just the single word: finished. Don't use any tools.")
            let w2 = wait(60) { chat.activity == .working }
            let done = wait(120) { chat.activity == .doneUnseen }
            check("live claude: plain answer -> Working, then Done, unseen", w2 && done)
            let doneNote = rec.posted.last
            check("live claude: Done notification quotes the reply", doneNote?.isDone == true && doneNote?.body.lowercased().contains("finished") == true, "\(String(describing: doneNote))")

            _ = wait(2) { false }
            send("Use the AskUserQuestion tool to ask me one question: tea or coffee? Then stop.")
            let asked = wait(120) { chat.activity == .needsAnswer }
            check("live claude: AskUserQuestion -> Needs answer", asked && chat.activityDetail.hasPrefix("Asks:"), chat.activityDetail)
            _ = wait(1) { false }
            key(53, "\u{1b}", into: view, window: w)
            _ = wait(30) { chat.activity == .idle }

            send("/exit")
            let ended = wait(30) { chat.activity == .ended }
            check("live claude: /exit -> Ended", ended)
        } else {
            send("Run exactly this shell command and nothing else: touch hantuu-probe.txt")
            let working = wait(90) { chat.activity == .working }
            check("live codex: prompt -> Working (rollout task_started)", working)
            guard working else { screen("after the prompt"); return }
            let perm = wait(240) { chat.activity.isNeeds || chat.activity == .doneUnseen }
            check("live codex: approval prompt -> Needs permission (OSC 9)", chat.activity == .needsPermission && chat.activityDetail.hasPrefix("Wants to"), "\(chat.activity.rawValue) \(chat.activityDetail)")
            _ = perm
            if chat.activity.isNeeds {
                key(53, "\u{1b}", into: view, window: w)   // decline, in Codex's own terminal
                _ = wait(60) { !chat.activity.isNeeds }
                check("live codex: declining leaves Needs permission", !chat.activity.isNeeds, chat.activity.rawValue)
                _ = wait(60) { chat.activity != .working }
            }
            _ = wait(3) { false }
            send("Reply with just the single word: finished. Don't run anything.")
            let w2 = wait(90) { chat.activity == .working }
            let done = wait(240) { chat.activity == .doneUnseen }
            check("live codex: plain answer -> Working, then Done, unseen", w2 && done, chat.activity.rawValue)
            let fromNotify = (try? String(contentsOf: AgentHooks.eventsFile(for: chat.id), encoding: .utf8))?.contains("agent-turn-complete") == true
            check("live codex: notify wrote the turn end to HANTUU_EVENTS", fromNotify)
            send("/quit")
            check("live codex: /quit -> Ended", wait(30) { chat.activity == .ended })
        }
        print("      live: notifications that would have been posted:")
        for n in rec.posted { print("        \(n.isDone ? "done " : "needs") \(n.title) | \(n.body)") }
    }
}
