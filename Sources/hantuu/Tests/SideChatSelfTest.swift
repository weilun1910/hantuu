import AppKit
import SwiftUI
import Darwin

extension SelfTest {
    static func sideChats(_ workdir: URL) {
        let root = workdir.appendingPathComponent("side-chats")
        Paths.ensure(root)
        let args = (try? SideQuestionCommand.arguments(agent: "claude", session: "fixture-session")) ?? []
        check("side: Claude forks without saving a provider session", args.contains("--fork-session") && args.contains("--no-session-persistence") && args.contains("fixture-session"))
        check("side: Claude streams and disables tools, hooks and MCP", args.contains("--include-partial-messages") && args.contains("stream-json") && args.contains("--strict-mcp-config") && args.contains("{\"disableAllHooks\":true}") && args.contains("--disable-slash-commands") && args.contains("--tools") && args.contains(""))
        let codex = (try? SideQuestionCommand.arguments(agent: "codex", session: "fixture")) ?? []
        check("side: Codex uses ephemeral fork, never resume", codex.first == "exec" && codex.contains("--ephemeral") && codex.suffix(3) == ["fork", "fixture", "-"] && !codex.contains("resume"))
        check("side: Codex requests read-only tools and disables hooks and apps", codex.contains("read-only") && codex.contains("approval_policy=\"never\"") && codex.contains("hooks") && codex.contains("apps"))
        check("side: missing parent session is rejected", (try? SideQuestionCommand.arguments(agent: "claude", session: "")) == nil)
        check("side: reader btw takes its arguments", SideQuestionCommand.question("/btw explain this", agent: "claude", reader: true) == "explain this")
        check("side: bare btw opens the Side tab without a call", SideQuestionCommand.question("/btw", agent: "claude", reader: true) == "")
        check("side: multiline side questions never reach the hidden terminal", SideQuestionCommand.question("/btw explain\nthis too", agent: "claude", reader: true) == "explain\nthis too")
        check("side: native terminal commands are untouched", SideQuestionCommand.question("/btw explain this", agent: "claude", reader: false) == nil)
        check("side: Codex reader side and btw use the panel", SideQuestionCommand.question("/side explain this", agent: "codex", reader: true) == "explain this" && SideQuestionCommand.question("/btw explain this", agent: "codex", reader: true) == "explain this")
        check("side: unrelated reader text is untouched", SideQuestionCommand.question("Tell me about /btw", agent: "claude", reader: true) == nil)
        check("side: Codex native side command opens the terminal", ReaderCommandCatalog.builtins(agent: "codex").first(where: { $0.name == "side" })?.opensTerminal(arguments: "question") == true)

        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Caf\u00e9"}}}"#
        let complete = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Caf\u00e9"}]}}"#
        let finish = #"{"type":"result","is_error":false,"result":"Caf\u00e9"}"#
        var stream = SideAnswerStream()
        let wire = Data((delta + "\n" + complete + "\n" + finish).utf8)
        for byte in wire { stream.consume(Data([byte])) }
        stream.consume(Data(), eof: true)
        check("side: partial lines and final assistant do not duplicate streaming text", stream.answer == "Caf\u{00e9}" && stream.finished && stream.error == nil)
        var failed = SideAnswerStream()
        failed.consume(Data(#"{"type":"result","is_error":true,"errors":["Not signed in"]}"#.utf8), eof: true)
        check("side: model failures have a visible message", failed.error == "Not signed in" && failed.finished)
        var codexStream = SideAnswerStream()
        for event in [
            #"{"type":"item.updated","item":{"id":"a","type":"agent_message","text":"Part"}}"#,
            #"{"type":"item.completed","item":{"id":"a","type":"agent_message","text":"Complete"}}"#,
            #"{"type":"turn.completed","usage":{}}"#,
        ] { codexStream.consume(Data((event + "\n").utf8)) }
        check("side: Codex item updates replace rather than repeat text", codexStream.answer == "Complete" && codexStream.finished)

        let script = root.appendingPathComponent("fake-cli.sh")
        let scriptText = """
        #!/bin/sh
        cat > "$1"
        printf '%s\\n' '\(delta)'
        printf '%s\\n' '\(complete)'
        printf '%s\\n' '\(finish)'
        """
        try? scriptText.write(to: script, atomically: true, encoding: .utf8)
        let stdin = root.appendingPathComponent("stdin.txt")
        var logs: [String] = []
        let directory = root.appendingPathComponent("history")
        let store = SideChatStore(directory: directory, logger: { logs.append($0) })
        store.commandOverride = { _, _ in (URL(fileURLWithPath: "/bin/sh"), [script.path, stdin.path]) }
        let one = UUID(), two = UUID()
        let sent = store.ask(chat: one, agent: "claude", session: "fixture", executable: nil, folder: root.path, question: "A private question")
        let duplicate = store.ask(chat: one, agent: "claude", session: "fixture", executable: nil, folder: root.path, question: "Another")
        check("side: only one question runs per chat", sent && !duplicate && store.running.contains(one))
        check("side: fake CLI produces an answer", waitUntil(5) { !store.running.contains(one) } && store.histories[one]?.last?.state == .answered && store.histories[one]?.last?.answer == "Caf\u{00e9}")
        check("side: prompt goes to stdin", (try? String(contentsOf: stdin, encoding: .utf8)) == "A private question")
        check("side: one metadata-only log entry", logs.count == 1 && logs[0].contains("success=true") && !logs[0].contains("private") && !logs[0].contains("Caf"))
        let codexScript = root.appendingPathComponent("fake-codex.sh")
        try? """
        #!/bin/sh
        cat > "$1"
        printf '%s\\n' '{"type":"item.completed","item":{"id":"answer","type":"agent_message","text":"Codex fixture answer"}}'
        printf '%s\\n' '{"type":"turn.completed","usage":{}}'
        """.write(to: codexScript, atomically: true, encoding: .utf8)
        let codexChat = UUID()
        store.commandOverride = { _, _ in (URL(fileURLWithPath: "/bin/sh"), [codexScript.path, stdin.path]) }
        _ = store.ask(chat: codexChat, agent: "codex", session: "fixture", executable: nil, folder: root.path, question: "Codex question")
        check("side: fake Codex fork completes", waitUntil(5) { !store.running.contains(codexChat) } && store.histories[codexChat]?.last?.answer == "Codex fixture answer")
        check("side: Codex receives its side boundary on stdin", (try? String(contentsOf: stdin, encoding: .utf8))?.hasPrefix("Side conversation boundary.") == true)
        store.load(two)
        check("side: each chat has its own history", store.histories[two]?.isEmpty == true && store.histories[one]?.count == 1)
        let restored = SideChatStore(directory: directory, logger: { _ in })
        restored.load(one)
        check("side: history survives relaunch", restored.histories[one] == store.histories[one])
        let many = (0..<45).map { SideQuestion(question: "Question \($0)", answer: "Answer", state: .answered) }
        try? JSONEncoder().encode(many).write(to: directory.appendingPathComponent(two.uuidString + ".json"))
        let pruned = SideChatStore(directory: directory, logger: { _ in })
        pruned.load(two)
        check("side: history retains the newest forty", pruned.histories[two]?.count == 40 && pruned.histories[two]?.first?.question == "Question 5")

        let slow = root.appendingPathComponent("slow-cli.sh")
        try? ("#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '" + delta + "'\nexec /bin/sleep 20\n").write(to: slow, atomically: true, encoding: .utf8)
        store.commandOverride = { _, _ in (URL(fileURLWithPath: "/bin/sh"), [slow.path]) }
        _ = store.ask(chat: one, agent: "claude", session: "fixture", executable: nil, folder: root.path, question: "Stop fixture")
        check("side: partial answer arrives before process exits", waitUntil(4) { store.histories[one]?.last?.answer == "Caf\u{00e9}" } && store.running.contains(one))
        store.stop(one)
        check("side: Stop terminates only the side process", waitUntil(5) { !store.running.contains(one) } && store.histories[one]?.last?.state == .stopped)
        let wrapper = root.appendingPathComponent("wrapper-cli.sh")
        let childFile = root.appendingPathComponent("fixture-child.pid")
        try? ("#!/bin/sh\ncat >/dev/null\n/bin/sleep 20 &\necho $! >\"$1\"\nprintf '%s\\n' '" + delta + "'\nwait\n").write(to: wrapper, atomically: true, encoding: .utf8)
        store.commandOverride = { _, _ in (URL(fileURLWithPath: "/bin/sh"), [wrapper.path, childFile.path]) }
        _ = store.ask(chat: one, agent: "claude", session: "fixture", executable: nil, folder: root.path, question: "Wrapper fixture")
        check("side: wrapper fixture starts before Stop", waitUntil(4) { store.histories[one]?.last?.answer == "Caf\u{00e9}" })
        store.stop(one)
        check("side: inherited pipes cannot keep Stop waiting", waitUntil(4) { !store.running.contains(one) })
        if let raw = try? String(contentsOf: childFile, encoding: .utf8), let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGTERM) }
        store.forget(one)
        check("side: removing a chat drops its history file", store.histories[one] == nil && !FileManager.default.fileExists(atPath: directory.appendingPathComponent(one.uuidString + ".json").path))

        nativeSideFixtures(root)
        sideReaderRouting(root, script: script)
        sideSnapshots(root)
    }

    private static func sideReaderRouting(_ root: URL, script: URL) {
        guard let ghostty = GhosttyApp.shared ?? GhosttyApp.start() else { check("side: recording terminal is available", false); return }
        for agent in ["claude", "codex"] {
            let model = AppModel()
            let project = Project(path: root.path)
            let chat = Chat(projectID: project.id, agentID: agent)
            chat.sessionID = "fixture"
            model.projects = [project]
            model.chats = [chat]
            model.selectedChatID = chat.id
            let terminalBytes = root.appendingPathComponent("\(agent)-terminal.bin")
            let terminal = recordingTerminal(ghostty, dir: root, file: terminalBytes)
            chat.terminal = terminal
            let store = SideChatStore(directory: root.appendingPathComponent("route-\(agent)"), logger: { _ in })
            model.sideChats = store
            store.commandOverride = { _, _ in (URL(fileURLWithPath: "/bin/sh"), [script.path, root.appendingPathComponent("\(agent)-prompt.txt").path]) }
            let settings = ChatSettings(file: root.appendingPathComponent("\(agent)-reader-settings.json"))
            settings.showChatsAsReader = true
            let mode = ReaderMode(settings: settings)
            let controller = ReaderModeController(model: model, mode: mode, commandCatalog: ReaderCommandCatalog(home: root))
            controller.statusProvider = { _ in nil }
            let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 700, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
            window.contentView = host
            terminal.frame = host.bounds
            host.addSubview(terminal)
            controller.install(in: host, top: host.topAnchor, above: terminal)
            window.orderFrontRegardless()
            _ = controller.sync(selected: chat)
            _ = waitUntil(5) { terminal.activeScreenText().contains("shortcuts") }
            let before = (try? Data(contentsOf: terminalBytes)) ?? Data()
            controller.composer.textView.text = agent == "claude" ? "/btw Explain this" : "/side Explain this"
            check("side: \(agent) reader command routes to Side", controller.send() && model.panelTab == .side && model.panelVisible && controller.composer.textView.string.isEmpty)
            _ = waitUntil(5) { !store.running.contains(chat.id) }
            check("side: \(agent) reader side command never types into the parent", ((try? Data(contentsOf: terminalBytes)) ?? Data()) == before && store.histories[chat.id]?.count == 1)
            terminal.destroy()
            window.orderOut(nil)
        }
    }

    private static func nativeSideFixtures(_ root: URL) {
        let folder = root.appendingPathComponent("rollouts/2026/11/11")
        Paths.ensure(folder)
        let url = folder.appendingPathComponent("rollout-fixture-side.jsonl")
        let meta = #"{"type":"session_meta","payload":{"id":"side-child","cwd":"/Users/example/project","forked_from_id":"parent","attached_thread":true}}"#
        let inherited = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Parent task"}]}}"#
        let boundary = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Side conversation boundary.\nInherited history is reference only."}]}}"#
        let question = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Why a fork?"}]}}"#
        let answer = #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"A **separate** conversation."}]}}"#
        let bytes = Data(([meta, inherited, boundary, question, answer].joined(separator: "\n") + "\n").utf8)
        try? bytes.write(to: url)
        let ordinary = folder.appendingPathComponent("rollout-ordinary.jsonl")
        try? Data((meta.replacingOccurrences(of: "\"attached_thread\":true", with: "\"attached_thread\":false") + "\n").utf8).write(to: ordinary)
        let index = NativeSideChatIndex(root: root.appendingPathComponent("rollouts"))
        check("side: attached rollouts are matched to their exact parent", index.scan(parent: "PARENT").map(\.id) == ["side-child"] && index.scan(parent: "other").isEmpty)
        check("side: an ordinary fork is not a side conversation", NativeSideChat.read(ordinary) == nil)
        let follower = TranscriptFollower(url: url, kind: .codex, baseDir: root.path, scope: .side)
        _ = follower.poll()
        check("side: native reader hides copied parent history and boundary", follower.entries.map(\.text) == ["Why a fork?", "A **separate** conversation."])
        let second = answer.replacingOccurrences(of: "A **separate** conversation.", with: "Live follow-up") + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(second.utf8)); try? handle.close()
        }
        _ = follower.poll()
        check("side: native rollout follows live", follower.entries.last?.text == "Live follow-up")
        check("side: following only reads the provider file", (try? Data(contentsOf: url)) == bytes + Data(second.utf8))
        follower.stop()
    }

    private static func sideSnapshots(_ root: URL) {
        let model = AppModel()
        let project = Project(path: root.path)
        let chat = Chat(projectID: project.id, agentID: "claude")
        chat.sessionID = "fixture-session"
        model.projects = [project]
        model.chats = [chat]
        model.selectedChatID = chat.id
        model.panelVisible = true
        model.panelTab = .side
        let directory = root.appendingPathComponent("visual-history")
        Paths.ensure(directory)
        let store = SideChatStore(directory: directory, logger: { _ in })
        model.sideChats = store
        let panel = SidePanelController(model: model, store: store, codexRoot: root.appendingPathComponent("rollouts"))
        let container = FillView(color: Theme.chrome)
        let header = ChromeHostingView(rootView: PanelHeader().environmentObject(model))
        let views: [NSView] = [header, panel.root]
        for view in views { view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor), header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 73),
            panel.root.topAnchor.constraint(equalTo: header.bottomAnchor), panel.root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panel.root.trailingAnchor.constraint(equalTo: container.trailingAnchor), panel.root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 560, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        panel.sync(active: true)
        check("side: reader page loads", waitUntil(8) { panel.reader.page.ready })
        panel.state.selection = "previous-native-selection"
        model.openSideQuestions(in: chat)
        check("side: a reader question returns from native history to its own answers", waitUntil(3) { panel.state.selection.isEmpty && panel.state.focusGeneration > 0 })
        let shots = snapshotDir(root.deletingLastPathComponent())
        func snapshot(_ name: String) {
            for dark in [false, true] {
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                _ = waitUntil(0.2) { false }
                check("snapshot: side \(name) \(dark ? "dark" : "light")", render(container, to: shots.appendingPathComponent("side-tab-\(name)-\(dark ? "dark" : "light").png")))
            }
        }
        snapshot("empty")
        let answered = Chat(projectID: project.id, agentID: "claude")
        let records = [
            SideQuestion(question: "Why keep a separate conversation?", answer: "It leaves the main task running while you ask **a quick question**.", state: .answered),
            SideQuestion(question: "Can you show the formula and code?", answer: "$$P(A|B)=\\frac{P(B|A)P(A)}{P(B)}$$\n\n```swift\nlet answer = 42\n```", state: .answered),
        ]
        try? JSONEncoder().encode(records).write(to: directory.appendingPathComponent(answered.id.uuidString + ".json"))
        model.chats.append(answered)
        model.selectedChatID = answered.id
        panel.sync(active: true)
        check("side: answers render markdown, code and KaTeX", waitUntil(5) {
            (js(panel.reader.page, "document.querySelectorAll('.md strong').length > 0 && document.querySelectorAll('pre code').length > 0 && document.querySelectorAll('.katex').length > 0") as? Bool) == true
        })
        snapshot("answered")
        let slow = root.appendingPathComponent("snapshot-cli.sh")
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"The parent conversation keeps running while this answer arrives..."}}}"#
        try? ("#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '" + delta + "'\nexec /bin/sleep 20\n").write(to: slow, atomically: true, encoding: .utf8)
        store.commandOverride = { _, _ in (URL(fileURLWithPath: "/bin/sh"), [slow.path]) }
        answered.sessionID = "fixture"
        _ = model.askSideQuestion("What happens while this streams?", in: answered)
        check("side: selected chat opens the Side tab", model.panelTab == .side && model.panelVisible)
        check("side: streamed answer reaches the reader", waitUntil(4) {
            (js(panel.reader.page, "document.body.textContent.includes('while this answer arrives')") as? Bool) == true
        })
        snapshot("streaming")
        window.setContentSize(NSSize(width: 360, height: 700))
        snapshot("narrow")
        store.stop(answered.id)
        _ = waitUntil(5) { !store.running.contains(answered.id) }
        panel.sync(active: false)
    }
}
