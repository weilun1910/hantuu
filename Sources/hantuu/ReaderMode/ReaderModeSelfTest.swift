import AppKit
import SwiftUI
import WebKit

/// Self test for reader mode: the setting and per-chat flips, the message box's state for every
/// agent state, its keys, sending and Stop through a fake agent that records every byte, the
/// banner, peeking at the terminal, and offscreen snapshots in tmp/snapshots/.
///
/// `HANTUU_LIVE_READER_TEST=<folder> scripts/selftest.sh` also runs a real Claude Code chat in
/// that folder (one that Claude Code already trusts): one message through the message box, the
/// reply in the reader, and one Stop. It never answers a trust, update or permission prompt.
extension SelfTest {
    static func readerMode(_ dir: URL) {
        let rdir = dir.appendingPathComponent("reader-mode", isDirectory: true)
        Paths.ensure(rdir)
        readerModeSettings(rdir)
        readerModeLogic()
        readerModeNotices()
        readerModeRestoredInput()
        readerModeKeys()
        readerModeFakeAgent(rdir)
        readerModeSnapshots(rdir)
        readerModeRealAgent(rdir)
    }

    static func snapshotsFolder(_ dir: URL) -> URL {
        // <worktree>/tmp/selftest/reader-mode -> <worktree>/tmp/snapshots
        dir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("snapshots", isDirectory: true)
    }

    // MARK: The setting and per-chat flips

    static func readerModeSettings(_ dir: URL) {
        let file = dir.appendingPathComponent("chat-settings.json")
        let s = ChatSettings(file: file)
        let p = Project(path: dir.path)
        let a = Chat(projectID: p.id, agentID: "claude")
        let b = Chat(projectID: p.id, agentID: "codex")
        let other = Chat(projectID: p.id, agentID: "gemini")
        check("reader mode: off by default, so chats show their terminal", !s.showChatsAsReader && s.face(for: a) == .terminal && !FileManager.default.fileExists(atPath: file.path))

        s.showChatsAsReader = true
        let stored = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any]
        check("reader mode: the switch is stored in chat-settings.json", stored?["showChatsAsReader"] as? Bool == true, "\(String(describing: stored))")
        check("reader mode: on, Claude Code and Codex chats show the reader", s.face(for: a) == .reader && s.face(for: b) == .reader)
        check("reader mode: agents without a transcript keep their terminal", s.face(for: other) == .terminal)
        check("reader mode: the switch survives a relaunch", ChatSettings(file: file).showChatsAsReader)

        s.toggle(a)
        check("per-chat: flipping a chat shows its terminal whatever the setting says", s.face(for: a) == .terminal && s.face(for: b) == .reader)
        s.showChatsAsReader = false
        s.toggle(b)
        check("per-chat: with the setting off, a flipped chat shows the reader", s.face(for: b) == .reader && s.face(for: Chat(projectID: p.id, agentID: "claude")) == .terminal)
        check("per-chat: flips survive a relaunch", ChatSettings(file: file).face(for: b) == .reader)
        s.toggle(b)
        check("per-chat: flipping back to the default forgets the flip", s.flipped[b.id] == nil && s.face(for: b) == .terminal)
        s.forget(except: [b.id])
        check("per-chat: flips of removed chats are dropped", s.flipped.isEmpty, "\(s.flipped)")

        let mode = ReaderMode(settings: s)
        s.showChatsAsReader = true
        mode.peek(a)
        check("peek: a peeking chat shows its terminal for now", !mode.showsReader(a) && mode.face(of: a) == .reader)
        mode.toggle(a)
        check("peek: flipping a chat ends its peek", !mode.isPeeking(a) && mode.face(of: a) == .terminal)
        check("panel: the Reader tab is hidden only while the reader is the main area", mode.hidesPanelReader(selected: b) && !mode.hidesPanelReader(selected: a) && !mode.hidesPanelReader(selected: nil))
    }

    // MARK: The message box's state

    static func readerModeLogic() {
        func m(_ act: AgentActivity, _ detail: String = "", waiting: Bool = false, ready: Bool = true, ended: Bool = false,
               live: Bool = true, menu: ScreenMenu? = nil) -> ComposerMode {
            ComposerMode.resolve(.init(agentName: "Claude Code", ended: ended, live: live, activity: act, detail: detail,
                                       waiting: waiting, ready: ready, screenMenu: menu))
        }
        let perm = m(.needsPermission, "Wants to run Bash: npm test", waiting: true)
        check("banner: Needs permission shows the banner and blocks sending",
              perm == .blocked(title: "Claude Code needs your permission", detail: "Wants to run Bash: npm test") && !perm.canSend, "\(perm)")
        let ask = m(.needsAnswer, "Asks: Tea or coffee?", waiting: true)
        check("banner: a question menu shows the banner and blocks sending",
              ask == .blocked(title: "Claude Code is asking you", detail: "Asks: Tea or coffee?") && !ask.canSend, "\(ask)")
        let final = m(.needsAnswer, "Asks: Shall I commit?")
        check("banner: a question in the final message is answered in the message box", final == .asked(question: "Shall I commit?") && final.canSend, "\(final)")
        let work = m(.working, "Running Bash: swift build")
        check("working: the working line shows the detail, and sending still works", work == .working(detail: "Running Bash: swift build") && work.canSend && work.isWorking)
        check("ready: idle and finished chats can send", m(.idle) == .ready && m(.doneUnseen) == .ready)
        check("ended: no message box", m(.ended) == .none && m(.idle, ended: true) == .none && m(.idle, live: false) == .none)
        check("starting: nothing is sent before the agent draws its prompt", m(.idle, ready: false) == .starting && !ComposerMode.starting.canSend)
        let trust = TerminalScreen.analyze("""
         Claude Code

         Do you trust the files in this folder?

         /Users/test/project

         ❯ 1. Yes, proceed
           2. No, exit

         Enter to confirm · Esc to exit
        """)
        check("screen: a trust prompt is found and blocks sending", trust.menu == ScreenMenu(kind: .trust, line: "Do you trust the files in this folder?")
              && m(.idle, menu: trust.menu).isBlocked, "\(String(describing: trust.menu))")
        let idle = TerminalScreen.analyze("╭──────────────╮\n│ >            │\n╰──────────────╯\n  ? for shortcuts\n")
        check("screen: the agent's idle prompt counts as ready, with no menu", idle.ready && idle.menu == nil)
        let codexIdle = TerminalScreen.analyze("› Ask Codex to do anything\n\n  100% context left · ? for shortcuts")
        check("screen: Codex's prompt counts as ready", codexIdle.ready && codexIdle.menu == nil)
        let update = TerminalScreen.analyze("Update available! 0.50.0 -> 0.51.0\n› 1. Update now\n  2. Skip\n")
        check("screen: an update offer blocks sending", update.menu?.kind == .update)
        let old = TerminalScreen.analyze("Do you trust the files in this folder?\n" + (1...30).map { "line \($0) of the answer" }.joined(separator: "\n") + "\n? for shortcuts")
        check("screen: a menu phrase higher up in the output doesn't count", old.menu == nil && old.ready)
        check("message: trimmed, line endings made plain", ComposerMessage.prepare("  \n Explain this \r\n in two lines  \n\n") == "Explain this \n in two lines")
        check("message: an empty box sends nothing", ComposerMessage.prepare(" \n\t ") == nil)
        check("drop: files become shell-escaped paths", ComposerMessage.paths([URL(fileURLWithPath: "/tmp/a b/(1).png"), URL(fileURLWithPath: "/tmp/c.pdf")]) == #"/tmp/a\ b/\(1\).png /tmp/c.pdf"#)
        check("working line: elapsed time", Elapsed.text(since: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 74)) == "1m 14s")
    }

    static func readerModeRestoredInput() {
        let rule = String(repeating: "─", count: 60)
        let msg = "Write a 500-word short story about a lighthouse keeper. Don't use any tools."
        // Claude Code after a stop: the history, then the message back in the box between rules.
        let restored = "❯ Read notes.md\n● It says hi.\n\n\(rule)\n❯ \(msg)\n\(rule)\n  ⏵⏵ auto mode on (shift+tab to cycle)"
        let n = ComposerMessage.restoredLength(screen: restored, sent: [msg])
        check("stop: a message put back in Claude Code's box is cleared in full", n >= msg.unicodeScalars.count && n < msg.unicodeScalars.count + 10, "\(n)")
        let empty = "❯ \(msg)\n● Once upon a time\n\n\(rule)\n❯ \n\(rule)\n  ? for shortcuts"
        check("stop: the same text higher up in the history doesn't count", ComposerMessage.restoredLength(screen: empty, sent: [msg]) == 0)
        let pasted = "\(rule)\n❯ [Pasted text #1 +40 lines]\n\(rule)\n  ? for shortcuts"
        check("stop: a long message shown as pasted text is cleared too", ComposerMessage.restoredLength(screen: pasted, sent: [String(repeating: "x\n", count: 40)]) > 80)
        check("stop: two messages from one turn are both counted",
              ComposerMessage.restoredLength(screen: restored, sent: [msg, "and make it sad"]) >= msg.unicodeScalars.count + 15)
        check("stop: nothing sent this turn, nothing deleted", ComposerMessage.restoredLength(screen: restored, sent: []) == 0)
    }

    static func readerModeNotices() {
        check("notices: Claude's idle reminder isn't kept as a Needs you card",
              AppModel.isIdleNotice("Claude Code Claude is waiting for your input")
              && !AppModel.isIdleNotice("Claude Code Claude needs your permission to use Bash"))
    }

    // MARK: Keys in the message box

    static func keyEvent(_ code: UInt16, _ chars: String, mods: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)
    }

    static func readerModeKeys() {
        let w = makeWindow()
        let tv = ComposerTextView.make()
        tv.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        w.contentView?.addSubview(tv)
        defer { tv.removeFromSuperview() }
        w.makeFirstResponder(tv)
        var sends = 0, escapes = 0
        tv.onSend = { sends += 1 }
        tv.onEscape = { escapes += 1; return true }
        tv.text = "hello"
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        if let e = keyEvent(36, "\r", window: w) { tv.keyDown(with: e) }
        check("keys: Return sends", sends == 1 && tv.string == "hello", "sends=\(sends) text=\(tv.string.debugDescription)")
        if let e = keyEvent(36, "\r", mods: .shift, window: w) { tv.keyDown(with: e) }
        check("keys: Shift-Return adds a new line", sends == 1 && tv.string == "hello\n", tv.string.debugDescription)
        if let e = keyEvent(53, "\u{1b}", window: w) { tv.keyDown(with: e) }
        check("keys: Esc goes to Stop", escapes == 1)
        tv.text = "look at"
        tv.insertPaths([URL(fileURLWithPath: "/tmp/shot one.png")], at: 7)
        check("drop: dropped files are typed as escaped paths where they land", tv.string == #"look at /tmp/shot\ one.png "#, tv.string.debugDescription)
        let box = ComposerBox(frame: NSRect(x: 0, y: 0, width: 400, height: 50))
        let one = box.preferredHeight
        box.textView.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
        box.textView.text = (1...4).map { "line \($0)" }.joined(separator: "\n")
        let four = box.preferredHeight
        box.textView.text = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let many = box.preferredHeight
        let cap = ComposerBox.padTop + ComposerStyle.lineHeight * ComposerStyle.maxLines + ComposerBox.footer
        check("message box: two lines to start, grows with the text, up to a limit",
              abs(one - (ComposerBox.padTop + ComposerStyle.lineHeight * 2 + ComposerBox.footer)) < 0.5 && four > one && many > four && many <= cap + 0.5,
              "one=\(one) four=\(four) many=\(many)")
    }

    // MARK: Sending, Stop and the banner, through a fake agent

    /// A "chat" whose program shows an idle prompt line, turns on bracketed paste and records
    /// every byte it gets.
    static func recordingTerminal(_ g: GhosttyApp, dir: URL, file: URL) -> TerminalView {
        try? FileManager.default.removeItem(at: file)
        let script = "stty -icanon -icrnl -echo min 1 time 0; printf '\\033[?2004h'; printf '  ? for shortcuts\\n'; exec cat -u > \(ShellEscape.quote(file.path))"
        return TerminalView(app: g.app, launch: .init(workingDirectory: dir.path, command: "/bin/sh -c \(ShellEscape.quote(script))"), handlesChildExit: true)
    }

    static func readerModeFakeAgent(_ dir: URL) {
        guard let g = GhosttyApp.shared ?? GhosttyApp.start() else { check("reader mode: libghostty", false); return }
        let settings = ChatSettings(file: dir.appendingPathComponent("fake-chat-settings.json"))
        settings.showChatsAsReader = true
        let mode = ReaderMode(settings: settings)
        let model = AppModel()
        let project = Project(path: dir.path)
        model.projects = [project]
        let chat = Chat(projectID: project.id, agentID: "claude")
        let sent = dir.appendingPathComponent("sent.bin")
        let tv = recordingTerminal(g, dir: dir, file: sent)
        chat.terminal = tv
        model.chats = [chat]
        model.selectedChatID = chat.id

        let w = NSWindow(contentRect: NSRect(x: -6000, y: -4000, width: 900, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        w.contentView = host
        tv.frame = host.bounds
        host.addSubview(tv)
        let rm = ReaderModeController(model: model, mode: mode)
        var statusOverride: StatusState?
        rm.statusProvider = { _ in statusOverride }
        rm.install(in: host, top: host.topAnchor, above: tv)
        w.orderFrontRegardless()
        defer {
            tv.destroy()
            w.orderOut(nil)
        }
        let layout = rm.sync(selected: chat)
        check("reader mode: the main area shows the reader over the chat's terminal", layout.showsReader && !rm.root.isHidden && rm.reader != nil)
        let ready = waitUntil(10) { rm.refresh(); return rm.composerMode == .ready }
        check("reader mode: the message box is ready once the agent's prompt is up", ready, "\(rm.composerMode) screen=\(tv.activeScreenText().suffix(120).debugDescription)")
        _ = waitUntil(10) { rm.reader?.page.ready == true }

        // Keyboard: the terminal's focus request lands in the message box, and the reader page
        // never takes the keyboard.
        w.makeFirstResponder(rm.focusTarget(for: tv))
        check("focus: asking for the chat's terminal gives the keyboard to the message box", w.firstResponder === rm.composer.textView)
        if let wv = rm.reader?.page.webView {
            // A real click on the reader, through the window, the way AppKit hands out focus.
            let p = wv.convert(NSPoint(x: wv.bounds.midX, y: wv.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { w.sendEvent(e) }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            check("focus: clicking the reader keeps the keyboard in the message box", !wv.acceptsFirstResponder && w.firstResponder === rm.composer.textView,
                  "firstResponder=\(String(describing: w.firstResponder))")
            _ = w.makeFirstResponder(wv)
            check("focus: the reader page never becomes the first responder", w.firstResponder !== wv)
            w.makeFirstResponder(nil)
            (wv as? FocuslessWebView)?.onMouseDown?()
            check("focus: a click on the reader puts the keyboard back in the message box", w.firstResponder === rm.composer.textView)
        }

        func bytes() -> Data { (try? Data(contentsOf: sent)) ?? Data() }
        // Send: one bracketed paste, then a real Return.
        rm.composer.textView.text = "Explain the build script\nin two lines  \n\n"
        let ok = rm.send()
        let arrived = waitUntil(5) { bytes().last == 0x0D }
        let first = String(decoding: bytes(), as: UTF8.self)
        check("send: the message goes in as one bracketed paste, then Return", ok && arrived && first == "\u{1b}[200~Explain the build script\nin two lines\u{1b}[201~\r", first.debugDescription)
        check("send: the message box empties", rm.composer.textView.string.isEmpty)
        // The same through the keyboard: Return in the box.
        rm.composer.textView.text = "second message"
        if let e = keyEvent(36, "\r", window: w) { rm.composer.textView.keyDown(with: e) }
        _ = waitUntil(5) { String(decoding: bytes(), as: UTF8.self).hasSuffix("second message\u{1b}[201~\r") }
        check("send: Return in the message box sends it", String(decoding: bytes(), as: UTF8.self).hasSuffix("\u{1b}[200~second message\u{1b}[201~\r"), String(decoding: bytes(), as: UTF8.self).debugDescription)

        // Stop: Esc, only while working.
        let before = bytes().count
        check("stop: does nothing while the agent isn't working", rm.stop() == false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        check("stop: no Esc sent then", bytes().count == before)
        chat.activity = .working
        chat.activityDetail = "Running Bash: swift build"
        rm.refresh()
        check("working: the working line shows the detail", rm.composerMode == .working(detail: "Running Bash: swift build") && !rm.statusHost.isHidden && rm.status.mode.isWorking)
        check("stop: the send button turns into Stop while the box is empty", rm.composer.action.kind == .stop)
        check("accessibility: the button reads as Stop", rm.composer.action.isAccessibilityElement() && rm.composer.action.accessibilityRole() == .button
              && rm.composer.action.accessibilityLabel() == "Stop Claude Code", rm.composer.action.accessibilityLabel() ?? "nil")
        rm.composer.textView.text = "queued thought"
        check("stop: it's Send again once there's text to send", rm.composer.action.kind == .send && rm.composer.action.active)
        check("accessibility: the button reads as Send, and the paperclip as Add Files", rm.composer.action.accessibilityLabel() == "Send"
              && rm.composer.action.isAccessibilityEnabled() && rm.composer.attach.accessibilityRole() == .button
              && (rm.composer.attach.accessibilityLabel() ?? "").hasPrefix("Add files"))
        rm.composer.textView.text = ""
        let stopped = rm.stop()
        check("stop: sends Esc to the terminal", stopped && waitUntil(5) { bytes().count == before + 1 && bytes().last == 0x1B }, bytes().suffix(8).map { String(format: "%02x", $0) }.joined(separator: " "))
        if let e = keyEvent(53, "\u{1b}", window: w) { rm.composer.textView.keyDown(with: e) }
        check("stop: Esc in the message box stops a working agent", waitUntil(5) { bytes().count == before + 2 && bytes().last == 0x1B })
        // The fake agent's screen shows its prompt and no "esc to interrupt", like Claude Code
        // after a stop that its status never reported.
        rm.refresh()
        check("stop: once the screen shows the turn stopped, the working line goes even if the status lags",
              rm.composerMode == .ready && chat.activity == .working, "\(rm.composerMode)")
        check("screen: a running turn is seen on screen", TerminalScreen.analyze("✻ Thinking… (esc to interrupt)\n> \n  ? for shortcuts").busy
              && !TerminalScreen.analyze("> \n  ? for shortcuts").busy)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check("stop: nothing is deleted when the agent's box doesn't show what was sent", !bytes().suffix(from: before).contains(0x7F))
        let beforeBS = bytes().count
        tv.pressBackspace(times: 3)
        check("stop: Backspace reaches the terminal as DEL", waitUntil(5) { bytes().count == beforeBS + 3 && bytes().suffix(3).allSatisfy { $0 == 0x7F } },
              bytes().suffix(4).map { String(format: "%02x", $0) }.joined(separator: " "))

        // The banner: a permission prompt is waiting.
        chat.activity = .needsPermission
        chat.activityDetail = "Wants to run Bash: npm test"
        statusOverride = nil
        rm.refresh()
        check("banner: appears for Needs permission, with the detail", rm.composerMode == .blocked(title: "Claude Code needs your permission", detail: "Wants to run Bash: npm test")
              && !rm.statusHost.isHidden && rm.statusHost.frame.height >= 0)
        let held = bytes().count
        rm.composer.textView.text = "this must not reach a menu"
        let refused = rm.send() == false
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        check("banner: nothing is sent while the prompt waits, and the text stays", refused && bytes().count == held && rm.composer.textView.string == "this must not reach a menu")
        chat.activity = .needsAnswer
        chat.activityDetail = "Asks: Tea or coffee?"
        rm.refresh()
        check("banner: appears for a question menu too", rm.composerMode == .blocked(title: "Claude Code is asking you", detail: "Asks: Tea or coffee?"))
        statusOverride = StatusState()   // nothing in waits: the question is in its final message
        rm.refresh()
        check("asked: a final question is answered in the message box", rm.composerMode == .asked(question: "Tea or coffee?") && rm.composerMode.canSend)
        statusOverride = nil

        // Show Terminal: the live terminal comes up, and the reader returns once it carries on.
        chat.activity = .needsPermission
        chat.activityDetail = "Wants to run Bash: npm test"
        rm.refresh()
        rm.showTerminal()
        let peek = rm.sync(selected: chat)
        check("peek: Show Terminal swaps the live terminal in", peek.peeking && !peek.showsReader && rm.root.isHidden && !rm.peekBar.isHidden)
        rm.focusComposer()
        check("peek: the terminal keeps the keyboard while it's up", rm.focusTarget(for: tv) === tv)
        chat.activity = .working
        chat.activityDetail = "Running Bash: npm test"
        rm.refresh()
        rm.refresh()
        let back = rm.sync(selected: chat)
        check("peek: the reader comes back once the agent carries on", !back.peeking && back.showsReader && !mode.isPeeking(chat))

        // Ended: the reader stays, without the message box.
        chat.status = .ended
        chat.activity = .ended
        rm.refresh()
        check("ended: no message box, room for the Resume bar", rm.composerMode == .none && rm.composer.isHidden && rm.focusTarget(for: tv) == nil)
        chat.status = .running
    }

    // MARK: Snapshots

    static func snapshotTranscript(_ url: URL, project: String) {
        func line(_ o: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) }
        func user(_ id: String, _ text: String) -> String { line(["type": "user", "uuid": id, "message": ["role": "user", "content": text]]) }
        func text(_ id: String, _ t: String) -> String { line(["type": "assistant", "uuid": id, "message": ["role": "assistant", "content": [["type": "text", "text": t]]]]) }
        func tool(_ id: String, _ tid: String, _ name: String, _ input: [String: Any]) -> String {
            line(["type": "assistant", "uuid": id, "message": ["role": "assistant", "content": [["type": "tool_use", "id": tid, "name": name, "input": input]]]])
        }
        func result(_ id: String, _ tid: String, _ out: String) -> String {
            line(["type": "user", "uuid": id, "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": tid, "content": out]]]])
        }
        let lines = [
            user("u1", "Why does the build fail on a clean checkout?"),
            tool("a1", "t1", "Bash", ["command": "swift build", "description": "Build the package"]),
            result("r1", "t1", "error: vendor/GhosttyKit.xcframework not found"),
            tool("a2", "t2", "Read", ["file_path": project + "/Package.swift"]),
            result("r2", "t2", "// swift-tools-version: 6.2"),
            tool("a3", "t3", "Grep", ["pattern": "GhosttyKit", "path": project]),
            result("r3", "t3", "Package.swift"),
            text("a4", """
            The build fails because `vendor/GhosttyKit.xcframework` isn't there on a clean checkout. `Package.swift` points at it as a binary target:

            ```swift
            .binaryTarget(name: "GhosttyKit", path: "vendor/GhosttyKit.xcframework")
            ```

            It's made by `scripts/build-libghostty.sh`, which downloads Zig and the Ghostty source. Run it once and the build works. The first run takes a few minutes, and later builds skip it.
            """),
            user("u2", "Can you make build.sh say that, instead of failing with a linker error?"),
            tool("a5", "t5", "Edit", ["file_path": project + "/scripts/build.sh", "old_string": "set -e", "new_string": "set -e"]),
            result("r5", "t5", "ok"),
            text("a6", "Done. `scripts/build.sh` now stops early with a plain message when the framework is missing:\n\n```bash\nif [ ! -d vendor/GhosttyKit.xcframework ]; then\n  echo \"Run scripts/build-libghostty.sh first.\" >&2\n  exit 1\nfi\n```"),
        ]
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func readerModeSnapshots(_ dir: URL) {
        guard let g = GhosttyApp.shared ?? GhosttyApp.start() else { return }
        let out = snapshotsFolder(dir)
        Paths.ensure(out)
        Theme.configure(from: g)
        ActivityDot.fixedPhase = 0.45
        let shared = ChatSettings.shared
        let wasOn = shared.showChatsAsReader
        shared.showChatsAsReader = true
        defer {
            ActivityDot.fixedPhase = nil
            shared.showChatsAsReader = wasOn
        }

        let projectDir = dir.appendingPathComponent("hantuu", isDirectory: true)
        Paths.ensure(projectDir.appendingPathComponent("scripts"))
        try? "// swift-tools-version: 6.2\n".write(to: projectDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try? "#!/bin/bash\n".write(to: projectDir.appendingPathComponent("scripts/build.sh"), atomically: true, encoding: .utf8)
        let model = AppModel()
        let project = Project(path: projectDir.path)
        model.projects = [project]
        let chat = Chat(projectID: project.id, agentID: "claude")
        chat.terminalTitle = "Clean checkout build"
        let transcript = dir.appendingPathComponent("snapshot-transcript.jsonl")
        snapshotTranscript(transcript, project: projectDir.path)
        let f = TranscriptFollower(url: transcript, kind: .claude, baseDir: projectDir.path)
        f.poll()
        chat.follower = f
        chat.transcriptPath = transcript.path
        let tv = recordingTerminal(g, dir: dir, file: dir.appendingPathComponent("snapshot-sent.bin"))
        chat.terminal = tv
        model.chats = [chat]
        model.selectedChatID = chat.id

        let main = MainAreaController(model: model)
        let w = NSWindow(contentRect: NSRect(x: -7000, y: -4000, width: 960, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = main.view
        main.view.frame = NSRect(x: 0, y: 0, width: 960, height: 720)
        w.orderFrontRegardless()
        defer {
            tv.destroy()
            w.orderOut(nil)
        }
        let rm = main.readerMode
        main.sync()
        _ = waitUntil(10) { rm.reader?.page.ready == true }
        let ready = waitUntil(10) { rm.refresh(); return rm.composerMode == .ready }
        check("snapshot: reader mode is the main area for the chat", ready && !rm.root.isHidden, "\(rm.composerMode)")
        _ = waitUntil(5) { (js(rm.reader!.page, "document.querySelectorAll('section.entry').length") as? Int ?? 0) > 3 }
        w.makeFirstResponder(rm.composer.textView)

        func shot(_ name: String) -> Bool {
            main.sync()
            main.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            return render(main.view, to: out.appendingPathComponent(name))
        }
        let idle = shot("reader-mode-idle.png")
        if let page = rm.reader?.page {
            let summary = js(page, "(document.querySelector('.toolgroup .sumtext') || {}).textContent || ''") as? String ?? ""
            check("reader page: a run of tool calls folds into one summary line", summary == "Ran a command, read a file and 1 more", summary)
            let rel = js(page, "Array.from(document.querySelectorAll('.toolrows a.path')).map(a => a.textContent).join('|')") as? String ?? ""
            check("reader page: paths in the chat's folder read relative to it", rel.contains("Package.swift") && !rel.contains("/"), rel)
            let lang = js(page, "Array.from(document.querySelectorAll('.codeblock .codehead .lang')).map(l => l.textContent).join('|')") as? String ?? ""
            check("reader page: code blocks get a header with the language", lang == "swift|bash", lang)
            let bubble = js(page, "getComputedStyle(document.querySelector('.entry.user')).alignItems + '|' + getComputedStyle(document.querySelector('.entry.user > .label')).display") as? String ?? ""
            check("reader page: your messages are bubbles on the right, without a label", bubble == "flex-end|none", bubble)
            _ = js(page, "document.querySelector('.toolgroup .toolsum').click(); 0")
            let opened = js(page, "document.querySelector('.toolgroup').classList.contains('open') && getComputedStyle(document.querySelector('.toolgroup .toolrows')).display === 'block'") as? Bool ?? false
            check("reader page: clicking the summary shows the steps", opened)
            _ = js(page, "document.scrollingElement.scrollTop = 0; 0")
            _ = shot("reader-mode-steps-open.png")
            _ = js(page, "document.scrollingElement.scrollTop = document.scrollingElement.scrollHeight; 0")
            _ = js(page, "document.querySelector('.toolgroup .toolsum').click(); 0")
            let panel = WebPage(page: "reader.html", identifier: "selftest.reader.panel")
            panel.webView.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
            w.contentView?.addSubview(panel.webView)
            _ = waitUntil(10) { panel.ready }
            panel.call("reset", ["chatID": "p", "entries": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(f.entries)), "emptyText": ""])
            _ = waitUntil(3) { (js(panel, "document.querySelectorAll('section.entry').length") as? Int ?? 0) > 3 }
            let plain = js(panel, "document.querySelectorAll('.toolgroup, .codeblock, .meta').length === 0 && !document.body.classList.contains('main')") as? Bool ?? false
            check("reader page: the panel's Reader keeps its own look", plain)
            panel.webView.removeFromSuperview()
        }

        chat.activity = .working
        chat.activityDetail = "Running Bash: swift build"
        chat.activitySince = Date().addingTimeInterval(-14)
        rm.refresh()
        let working = shot("reader-mode-working.png")

        chat.activity = .needsPermission
        chat.activityDetail = "Wants to run Bash: npm test"
        rm.refresh()
        let needs = shot("reader-mode-needs-permission.png")

        chat.status = .ended
        chat.activity = .ended
        chat.activityDetail = "Ended"
        rm.refresh()
        let ended = shot("reader-mode-ended.png")
        chat.status = .running

        // A message that arrives live fades in, and is fully shown afterwards even here, where
        // the offscreen window may not run animations.
        model.readerAppend.send((chat.id, [ReaderEntry(id: "live-1", kind: .assistant, text: "Arrived while you were reading.")]))
        let shownLive = waitUntil(5) { (js(rm.reader!.page, "(() => { const e = document.querySelector('section.entry[data-id=\"live-1\"]'); return !!e && !e.classList.contains('fresh') && getComputedStyle(e).opacity === '1'; })()") as? Bool) == true }
        check("reader page: a message that arrives live ends up fully shown", shownLive)

        let form = NSHostingView(rootView: Form { ChatSettingsSection() }.formStyle(.grouped).environment(\.colorScheme, .dark))
        form.appearance = NSAppearance(named: .darkAqua)
        form.frame = NSRect(x: 0, y: 0, width: 520, height: 140)
        w.contentView?.addSubview(form)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let settingsShot = render(form, to: out.appendingPathComponent("reader-mode-settings.png"))
        form.removeFromSuperview()
        check("snapshot: reader mode idle, working, needs permission, ended and its setting in \(out.path)", idle && working && needs && ended && settingsShot)
    }

    // MARK: A real Claude Code chat

    static func readerModeRealAgent(_ dir: URL) {
        guard let folder = ProcessInfo.processInfo.environment["HANTUU_LIVE_READER_TEST"], !folder.isEmpty else { return }
        guard let g = GhosttyApp.shared ?? GhosttyApp.start() else { check("live reader: libghostty", false); return }
        setvbuf(stdout, nil, _IOLBF, 0)
        let out = snapshotsFolder(dir)
        let settings = ChatSettings(file: dir.appendingPathComponent("live-chat-settings.json"))
        settings.showChatsAsReader = true
        let mode = ReaderMode(settings: settings)
        let model = AppModel()
        let project = Project(path: folder)
        model.projects = [project]
        let center = StatusCenter()
        center.notifier = NoticeRecorder()
        center.appIsActive = { true }
        center.start(model: model, live: false)
        let chat = Chat(projectID: project.id, agentID: "claude")
        chat.sessionID = UUID().uuidString.lowercased()
        let argv = chat.agent.launchArguments(sessionID: chat.sessionID)
        let env = ["HANTUU_CHAT_ID": chat.id.uuidString].merging(AgentHooks.environment(for: chat.id)) { a, _ in a }
        let tv = TerminalView(app: g.app, launch: .init(workingDirectory: folder, command: LoginShell.surfaceCommand(argv), environment: env), handlesChildExit: true)
        let events = LiveEvents(chat: chat, center: center)
        tv.events = events
        chat.terminal = tv
        chat.startedAt = Date()
        model.chats = [chat]
        model.selectedChatID = chat.id
        print("      live reader: claude in \(folder)")

        let w = NSWindow(contentRect: NSRect(x: -8000, y: -4000, width: 960, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        let host = FillView(color: Theme.background)
        host.frame = NSRect(x: 0, y: 0, width: 960, height: 720)
        w.contentView = host
        tv.frame = host.bounds
        host.addSubview(tv)
        let rm = ReaderModeController(model: model, mode: mode)
        rm.statusProvider = { center.state(of: $0.id) }
        rm.install(in: host, top: host.topAnchor, above: tv)
        w.orderFrontRegardless()
        rm.sync(selected: chat)

        // Follow the transcript the way AppModel does.
        let discovery = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            center.poll()
            guard chat.follower == nil, let sid = chat.sessionID, let u = ClaudeTranscriptParser.locate(sessionID: sid, cwd: folder) else { return }
            chat.transcriptPath = u.path
            let f = TranscriptFollower(url: u, kind: .claude, baseDir: folder)
            f.onAppend = { fresh in model.readerAppend.send((chat.id, fresh)) }
            chat.follower = f
            f.start()
            model.readerReload.send(chat.id)
        }
        var modes: [String] = []
        func note() {
            let d = "\(rm.composerMode)"
            if modes.last != d { modes.append(d); print("      live reader: \(d)") }
        }
        func wait(_ t: TimeInterval, _ cond: () -> Bool) -> Bool {
            waitUntil(t) { rm.refresh(); note(); return cond() || chat.status == .ended }
        }
        defer {
            discovery.invalidate()
            chat.follower?.stop()
            print("      live reader: screen at the end:\n" + tv.activeScreenText().split(separator: "\n").suffix(10).map { "        | " + $0 }.joined(separator: "\n"))
            tv.destroy()   // ends only the agent this test started
            w.orderOut(nil)
        }

        let started = wait(90) { rm.composerMode == .ready || rm.composerMode.isBlocked }
        if rm.composerMode.isBlocked {
            check("live reader: Claude Code opened without a menu (left unanswered: \(rm.composerMode))", false, String(tv.activeScreenText().suffix(600)))
            return
        }
        check("live reader: Claude Code started and the message box is ready", started && rm.composerMode == .ready, "\(rm.composerMode)")
        guard rm.composerMode == .ready else { return }
        _ = wait(2) { false }

        // One message through the message box: typed, then Return.
        w.makeFirstResponder(rm.composer.textView)
        rm.composer.textView.text = "What is 17 plus 25? Reply with just the number."
        if let e = keyEvent(36, "\r", window: w) { rm.composer.textView.keyDown(with: e) }
        let worked = wait(60) { rm.composerMode.isWorking }
        let got = wait(60) {
            guard let p = chat.transcriptPath, let t = try? String(contentsOfFile: p, encoding: .utf8) else { return false }
            return t.contains("What is 17 plus 25?")
        }
        check("live reader: the agent got the message from the message box", got, String(tv.activeScreenText().suffix(400)))
        check("live reader: the working line showed while it answered", worked || modes.contains { $0.hasPrefix("working") }, "\(modes)")
        let replied = wait(120) {
            (js(rm.reader!.page, "Array.from(document.querySelectorAll('section.entry.assistant')).some(e => /\\b42\\b/.test(e.innerText))") as? Bool) == true
        }
        check("live reader: the reply shows in the reader", replied, String(tv.activeScreenText().suffix(400)))
        _ = wait(30) { rm.composerMode == .ready }
        _ = render(host, to: out.appendingPathComponent("reader-mode-live.png"))

        // Stop: a longer answer, interrupted with Esc.
        _ = wait(2) { false }
        rm.composer.textView.text = "Write a 400-word story about a lighthouse keeper. Don't use any tools."
        rm.send()
        let busy = wait(60) { rm.composerMode.isWorking }
        _ = wait(2) { false }
        let pressed = rm.stop()
        // Claude Code's own screen is the evidence: no "esc to interrupt" once it has stopped.
        let halted = wait(30) { !TerminalScreen.analyze(tv.activeScreenText()).busy }
        let shown = wait(10) { !rm.composerMode.isWorking }
        check("live reader: Stop interrupts the turn and the working line goes", busy && pressed && halted && shown,
              "busy=\(busy) pressed=\(pressed) halted=\(halted) mode=\(rm.composerMode) status=\(chat.activity.rawValue) \(chat.activityDetail)")
        print("      live reader: after Stop: \(chat.activity.rawValue) \(chat.activityDetail)")
        print("      live reader: transcript \(chat.transcriptPath ?? "none")")
    }
}
