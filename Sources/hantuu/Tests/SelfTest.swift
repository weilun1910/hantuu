import AppKit
import GhosttyKit
import PDFKit
import WebKit

/// `hantuu --self-test [--workdir <dir>]`: checks transcript parsing for both agents, file
/// discovery, path detection and routing, agent detection, the reader's rendering, and a
/// real libghostty surface that runs a short command, takes keyboard input, a paste and a
/// Cmd-click, and exits. Fixtures are synthetic and live only in the throwaway workdir.
enum SelfTest {
    private static var failures = 0
    private static var passes = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok {
            passes += 1
            print("ok    \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)  \(detail())")
        }
    }

    static func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return cond()
    }

    static func run(workdir: URL) -> Int32 {
        if let folder = ProcessInfo.processInfo.environment["HANTUU_LIVE"], !folder.isEmpty,
           LiveCheckRules.inside(URL(fileURLWithPath: folder), workdir) {
            check("live configuration: preserve probe folder", false,
                  "HANTUU_LIVE must be outside the self-test workdir, which is deleted at startup.")
            return 1
        }
        try? FileManager.default.removeItem(at: workdir)
        Paths.ensure(workdir)
        print("hantuu self test, workdir \(workdir.path)\n")

        readerRequests()
        readerRequestFiles(workdir)
        readerChecklist()
        readerEvidence()
        readerEvidenceLifetimes()
        readerHealthFixtures(workdir)
        readerEvidenceRendering(workdir)
        claudeParsing()
        codexParsing()
        queuedMessages(workdir)
        savedState(workdir)
        discovery(workdir)
        follower(workdir)
        sessionFollowing(workdir)
        transcriptRecovery(workdir)
        transcriptTiming(workdir)
        paths(workdir)
        misc()
        agentDetection()
        surface(workdir)
        reader(workdir)
        sessions(workdir) // Sessions/SessionSelfTest.swift
        review(workdir)
        panelGit(workdir)
        panelFeedback(workdir)
        panelFreshness(workdir)
        status(workdir)   // agent states, hooks, notifications, snapshots (Status/StatusSelfTest.swift)
        readerMode(workdir) // settings, the message box, Stop, the banner, snapshots (ReaderMode/ReaderModeSelfTest.swift)
        readerCommands(workdir)
        releaseSnapshots(workdir) // reader command menus and queued messages for the 2.2 release
        sideChats(workdir)
        agentWork(workdir)  // subagents, background tasks, the status they hold up, snapshots (Tests/AgentWorkSelfTest.swift)
        projectPanels(workdir)
        browserTab(workdir)
        subagentBrowser(workdir) // sidebar navigation and read-only child transcripts
        fileViewer(workdir) // the Code tab as a file viewer and editor (FileViewer/FileViewerSelfTest.swift)
        panelRecovery(workdir)
        usage(workdir)    // usage limits and the footer rings (Usage/UsageSelfTest.swift)
        keepAwake(workdir)  // the lid-shut switch, its limits, the crash check (Tests/KeepAwakeSelfTest.swift)
        liveChecksLogic(workdir)
        appLifetimes(workdir)
        liveChecks(workdir) // Real agents only when HANTUU_LIVE names a trusted probe folder.

        print("\n\(passes) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: Saved state (the sidebar survives updates)

    static func savedState(_ dir: URL) {
        // The shape builds before 2026-11-11 wrote: no pins, no pinnedExpanded.
        let p1 = UUID(), p2 = UUID(), c1 = UUID(), c2 = UUID()
        let old = """
        {"projects":[{"id":"\(p1)","path":"/tmp/a","expanded":true},{"id":"\(p2)","path":"/tmp/b","expanded":false}],
         "chats":[{"id":"\(c1)","projectID":"\(p1)","agentID":"claude","sessionID":"s1","title":"One","createdAt":"2026-11-08T10:00:00Z"},
                  {"id":"\(c2)","projectID":"\(p2)","agentID":"codex","title":"Two","createdAt":"2026-11-09T10:00:00Z","transcriptPath":"/tmp/t.jsonl"}],
         "defaultAgentID":"codex","sidebarVisible":true,"panelVisible":true,"panelTab":"Changes","sidebarWidth":260}
        """
        let s = SavedState.read(Data(old.utf8))
        check("state: an older state.json loads every project and chat",
              s?.projects.map(\.id) == [p1, p2] && s?.chats.map(\.id) == [c1, c2] && s?.defaultAgentID == "codex" && s?.panelTab == .changes && s?.projects[1].expanded == false,
              "\(String(describing: s))")
        check("state: pins start off for older chats", s?.chats.allSatisfy { $0.pinnedAt == nil } == true && s?.pinnedExpanded == nil)

        // A later build's extra field, a missing field, a broken chat and an unknown tab.
        let mixed = """
        {"projects":[{"id":"\(p1)","path":"/tmp/a","expanded":true}],
         "chats":[{"id":"\(c1)","projectID":"\(p1)","agentID":"claude","title":"One","createdAt":"2026-11-08T10:00:00Z","futureField":[1,2]},
                  {"id":"not-a-uuid","projectID":"\(p1)"}],
         "panelTab":"Reader","somethingNew":{"x":1}}
        """
        let m = SavedState.read(Data(mixed.utf8))
        check("state: a bad chat is skipped, the rest still load", m?.chats.map(\.id) == [c1] && m?.projects.count == 1, "\(String(describing: m?.chats.map(\.id)))")
        check("state: missing and unknown fields fall back to defaults", m?.defaultAgentID == "claude" && m?.panelTab == .overview && m?.sidebarVisible == true)

        // Pins round-trip.
        var withPin = SavedState()
        withPin.projects = [Project(id: p1, path: "/tmp/a")]
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        withPin.chats = [SavedChat(id: c1, projectID: p1, agentID: "claude", title: "One", createdAt: when, pinnedAt: when)]
        withPin.pinnedExpanded = false
        let back = (try? JSONEncoder.hantuu.encode(withPin)).flatMap(SavedState.read)
        check("state: a pinned chat stays pinned after a save", back?.chats.first?.pinnedAt == when && back?.pinnedExpanded == false)

        // A file that isn't readable at all is moved aside, never left to be saved over.
        let sdir = dir.appendingPathComponent("state-test")
        Paths.ensure(sdir)
        let file = sdir.appendingPathComponent("state.json")
        try? Data("{not json".utf8).write(to: file)
        let none = AppModel.readState(Data("{not json".utf8), dir: sdir)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sdir.path)) ?? []
        check("state: an unreadable state.json is moved aside, not overwritten", none == nil && !names.contains("state.json") && names.contains { $0.hasPrefix("state.unreadable-") }, "\(names)")
        try? Data(old.utf8).write(to: file)
        _ = AppModel.readState(Data(old.utf8), dir: sdir)
        check("state: a readable state.json is copied to state.previous.json at launch",
              (try? Data(contentsOf: sdir.appendingPathComponent("state.previous.json"))) == Data(old.utf8))

        // Keep awake: idle sleep is held while agents work, and let go a minute after.
        let ka = KeepAwake()
        let t0 = Date()
        ka.agentsWorking(false, now: t0)
        check("keep awake: nothing held while no agent works", !ka.preventingIdleSleep)
        ka.agentsWorking(true, now: t0)
        check("keep awake: idle sleep held while an agent works", ka.preventingIdleSleep)
        ka.agentsWorking(false, now: t0.addingTimeInterval(30))
        check("keep awake: still held just after the agent stops", ka.preventingIdleSleep)
        ka.agentsWorking(false, now: t0.addingTimeInterval(KeepAwake.workGrace + 1))
        check("keep awake: let go a minute after the last agent stops", !ka.preventingIdleSleep)

        // Close only asks when it would cut an agent off mid-task.
        let quiet = Chat(projectID: UUID(), agentID: "claude")
        let asks = AgentActivity.allCases.filter { a in quiet.activity = a; return AppModel.closingInterrupts(quiet) }
        check("close: asks only while the agent works or waits on you", Set(asks) == [.working, .background, .needsPermission, .needsAnswer], "\(asks)")

        // The installed hantuu's own saved sidebar, read only: this build must load all of it.
        let mine = Paths.home.appendingPathComponent("Library/Application Support/hantuu/state.json")
        if let data = try? Data(contentsOf: mine),
           let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let loaded = SavedState.read(data)
            let rawProjects = (raw["projects"] as? [Any])?.count ?? -1
            let rawChats = (raw["chats"] as? [Any])?.count ?? -1
            check("state: your installed hantuu's state.json loads in this build with every project and chat",
                  loaded?.projects.count == rawProjects && loaded?.chats.count == rawChats,
                  "raw \(rawProjects)/\(rawChats), loaded \(loaded?.projects.count ?? -1)/\(loaded?.chats.count ?? -1)")
        }
    }

    // MARK: Claude Code

    static let claudeFixture: [String] = [
        #"{"type":"summary","summary":"Study session","leafUuid":"x"}"#,
        #"{"type":"user","uuid":"u1","timestamp":"2026-11-04T10:00:00Z","message":{"role":"user","content":"Explain Bayes' rule with $P(A|B)$ and show `notes.md`"}}"#,
        #"{"type":"user","uuid":"m1","isMeta":true,"message":{"role":"user","content":"<system-reminder>hidden</system-reminder>"}}"#,
        #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"secret reasoning","signature":"s"},{"type":"text","text":"Bayes' rule:\n\n$$P(A\\mid B)=\\frac{P(B\\mid A)P(A)}{P(B)}$$"}]}}"#,
        #"{"type":"assistant","uuid":"a2","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la","description":"List files"}}]}}"#,
        #"{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"bash: boom\nmore","is_error":true}]}}"#,
        #"{"type":"assistant","uuid":"a3","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/tmp/plot.png"}}]}}"#,
        #"{"type":"user","uuid":"r2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo="}}]}]}}"#,
        #"{"type":"assistant","uuid":"a4","message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"AskUserQuestion","input":{"questions":[{"question":"Which proof?","header":"Proof","multiSelect":false,"options":[{"label":"Algebraic","description":"short"},{"label":"Visual"}]}]}}]}}"#,
        #"{"type":"user","uuid":"r3","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t9","content":"The user doesn't want to proceed with this tool use.","is_error":true}]}}"#,
        #"{"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"text","text":"What about this? [Image #1]"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo="}}]}}"#,
        #"{"type":"user","uuid":"c1","message":{"role":"user","content":"<command-name>/model</command-name>\n<command-args>opus</command-args>"}}"#,
        #"{"type":"user","uuid":"c2","message":{"role":"user","content":"<local-command-stdout>Set model</local-command-stdout>"}}"#,
        #"{"type":"user","uuid":"i1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
        #"{"type":"system","uuid":"s1","subtype":"api_error","level":"error","error":{"error":{"message":"Overloaded"}}}"#,
        #"{"type":"assistant","uuid":"a5","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"API Error: 529"}]}}"#,
        #"{"type":"assistant","uuid":"side","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent chatter"}]}}"#,
        #"{"type":"file-history-snapshot","messageId":"x","snapshot":{}}"#,
        "not json at all",
    ]

    static func claudeParsing() {
        var p = ClaudeTranscriptParser()
        var all: [ReaderEntry] = []
        for line in claudeFixture { all += p.parse(line: Data(line.utf8)) }
        let kinds = all.map(\.kind.rawValue)
        check("claude: user prompt kept as prose", all.first?.kind == .user && all.first?.text.contains("Bayes") == true)
        check("claude: published reasoning retained and meta hidden", all.contains { $0.kind == .reasoning && $0.text.contains("secret") } && !all.contains { $0.text.contains("hidden") })
        check("claude: assistant answer with LaTeX", all.contains { $0.kind == .assistant && $0.text.contains("\\frac") })
        check("claude: Bash collapsed to one line with the command", all.contains { $0.kind == .tool && $0.text == "List files" && $0.detail == "ls -la" })
        check("claude: failed tool stands out as an error", all.contains { $0.operation?.state == "failed" && $0.operation?.name == "Bash" && $0.operation?.output?.contains("boom") == true })
        check("claude: Read records the file", all.contains { $0.kind == .tool && $0.files == ["/tmp/plot.png"] })
        check("claude: image returned by a tool shown inline", all.contains { $0.images.first?.hasPrefix("data:image/png;base64,") == true && $0.kind == .tool })
        check("claude: AskUserQuestion becomes a question", all.contains { $0.kind == .question && $0.text.contains("Which proof?") && $0.text.contains("Algebraic") })
        check("claude: declined permission stays visible", all.contains { $0.operation?.state == "declined" })
        check("claude: pasted image kept with the prompt", all.contains { $0.kind == .user && $0.images.count == 1 })
        check("claude: slash command becomes a notice", all.contains { $0.kind == .notice && $0.text == "Ran /model opus" })
        check("claude: command output is a notice", all.contains { $0.kind == .notice && $0.text.contains("Set model") })
        check("claude: interruption noted", all.contains { $0.kind == .notice && $0.text == "Interrupted" })
        check("claude: API errors stand out", all.filter { $0.kind == .error }.count == 2, "kinds \(kinds)")
        check("claude: sidechain hidden", !all.contains { $0.text.contains("subagent chatter") })
        check("claude: project folder name mangling", ClaudeTranscriptParser.projectFolderName(for: "/Users/a/Desktop/🫣 Solo Projects") == "-Users-a-Desktop----Solo-Projects")
    }

    // MARK: Codex

    static let codexFixture: [String] = [
        #"{"timestamp":"2026-11-04T10:00:00.000Z","type":"session_meta","payload":{"id":"0199-abc","timestamp":"2026-11-04T10:00:00.000Z","cwd":"/tmp/proj","originator":"codex_cli_rs","cli_version":"0.160.0"}}"#,
        #"{"timestamp":"2026-11-04T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions instructions>x</permissions instructions>"}]}}"#,
        ##"{"timestamp":"2026-11-04T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /tmp/proj\n\nbe nice"}]}}"##,
        #"{"timestamp":"2026-11-04T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n<cwd>/tmp/proj</cwd>\n</environment_context>"}]}}"#,
        #"{"timestamp":"2026-11-04T10:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Summarise README.md"},{"type":"input_image","image_url":"data:image/png;base64,iVBORw0KGgo="}]}}"#,
        #"{"timestamp":"2026-11-04T10:00:02.500Z","type":"event_msg","payload":{"type":"user_message","message":"Summarise README.md"}}"#,
        #"{"timestamp":"2026-11-04T10:00:03.000Z","type":"response_item","payload":{"type":"reasoning","summary":[],"encrypted_content":"zzz"}}"#,
        #"{"timestamp":"2026-11-04T10:00:04.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"cat README.md\"]}","call_id":"c1"}}"#,
        #"{"timestamp":"2026-11-04T10:00:04.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"{\"cmd\":\"rg TODO\"}","call_id":"c2"}}"#,
        #"{"timestamp":"2026-11-04T10:00:05.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"hello"}}"#,
        #"{"timestamp":"2026-11-04T10:00:05.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch\n*** Update File: src/a.py\n@@\n-x\n+y\n*** End Patch","call_id":"c3"}}"#,
        #"{"timestamp":"2026-11-04T10:00:06.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"The README says **hi**."}]}}"#,
        #"{"timestamp":"2026-11-04T10:00:06.000Z","type":"event_msg","payload":{"type":"agent_message","message":"The README says **hi**."}}"#,
        #"{"timestamp":"2026-11-04T10:00:07.000Z","type":"event_msg","payload":{"type":"error","message":"stream disconnected"}}"#,
        #"{"timestamp":"2026-11-04T10:00:08.000Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#,
        #"{"timestamp":"2026-11-04T10:00:09.000Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
    ]

    static func codexParsing() {
        var p = CodexTranscriptParser()
        var all: [ReaderEntry] = []
        for line in codexFixture { all += p.parse(line: Data(line.utf8)) }
        let users = all.filter { $0.kind == .user }
        check("codex: injected context hidden, prompt kept once", users.count == 1 && users.first?.text == "Summarise README.md", "\(users.map(\.text))")
        check("codex: pasted image kept", users.first?.images.count == 1)
        check("codex: shell call collapsed with command", all.contains { $0.kind == .tool && $0.detail == "cat README.md" })
        check("codex: exec custom tool collapsed", all.contains { $0.kind == .tool && $0.detail == "rg TODO" })
        check("codex: apply_patch lists files", all.contains { $0.kind == .tool && $0.files == ["src/a.py"] && $0.operation?.patch?.contains("-x") == true })
        check("codex: answer shown once", all.filter { $0.kind == .assistant }.count == 1)
        check("codex: errors stand out", all.contains { $0.kind == .error && $0.text == "stream disconnected" })
        check("codex: interruption is a notice", all.contains { $0.kind == .notice && $0.text == "Turn interrupted" })
        check("codex: encrypted reasoning hidden and output retained", !all.contains { $0.text.contains("zzz") } && all.contains { $0.operation?.output == "hello" })

        // Tags Codex writes for its own UI, from a real 0.167 rollout.
        let cited = CodexTranscriptParser.answerEntries("Saved in the [course notes](/x/MEMORY.md).\n\n<oai-mem-citation>\n<citation_entries>\nMEMORY.md:1118-1122|note=[attempt first tutoring workflow]\n</citation_entries>\n<rollout_ids>\n01a0ca8d-965c-7f52-8b65-ac99fc83df95\n</rollout_ids>\n</oai-mem-citation>", id: "a", time: nil)
        check("codex: memory citation block hidden", cited.count == 1 && cited[0].kind == .assistant && cited[0].text == "Saved in the [course notes](/x/MEMORY.md).", "\(cited.map(\.text))")
        let cut = CodexTranscriptParser.answerEntries("Done.\n\n<oai-mem-citation>\n<citation_entries>", id: "a", time: nil)
        check("codex: unclosed memory citation hidden", cut.map(\.text) == ["Done."], "\(cut.map(\.text))")
        check("codex: citation-only answer shows nothing", CodexTranscriptParser.answerEntries("<oai-mem-citation></oai-mem-citation>", id: "a", time: nil).isEmpty)
        let planned = CodexTranscriptParser.answerEntries("Here's the plan.\n\n<proposed_plan>\n# Fix it\n- step one\n</proposed_plan>\n\nSay go.", id: "a", time: nil)
        check("codex: proposed plan becomes a plan card, prose kept in order",
              planned.map(\.kind) == [.assistant, .plan, .assistant] && planned[1].text == "# Fix it\n- step one" && Set(planned.map(\.id)).count == 3,
              "\(planned.map { "\($0.kind):\($0.text)" })")
        check("codex: tags in code stay when not Codex's", CodexTranscriptParser.answerEntries("Use `<b>` here.", id: "a", time: nil).first?.text == "Use `<b>` here.")
    }

    // MARK: Discovery

    static func discovery(_ dir: URL) {
        let fm = FileManager.default
        let root = dir.appendingPathComponent("claude-projects")
        let cwd = "/Users/test/Desktop/🫣 Solo Projects/demo"
        let folder = root.appendingPathComponent(ClaudeTranscriptParser.projectFolderName(for: cwd))
        Paths.ensure(folder)
        let sid = "1b0800ee-8729-43d7-b73c-e5ce507699dd"
        fm.createFile(atPath: folder.appendingPathComponent("\(sid).jsonl").path, contents: Data())
        check("claude: transcript found by --session-id", ClaudeTranscriptParser.locate(sessionID: sid, cwd: cwd, root: root)?.lastPathComponent == "\(sid).jsonl")
        let other = root.appendingPathComponent("-somewhere-else")
        Paths.ensure(other)
        fm.createFile(atPath: other.appendingPathComponent("abc.jsonl").path, contents: Data())
        check("claude: transcript found when the folder name differs", ClaudeTranscriptParser.locate(sessionID: "abc", cwd: cwd, root: root) != nil)

        let sessions = dir.appendingPathComponent("codex-sessions")
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let day = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        Paths.ensure(day)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = Date()
        func rollout(_ name: String, cwd: String, at: Date) -> URL {
            let u = day.appendingPathComponent("rollout-\(name).jsonl")
            let meta = #"{"timestamp":"\#(iso.string(from: at))","type":"session_meta","payload":{"id":"\#(name)","timestamp":"\#(iso.string(from: at))","cwd":"\#(cwd)"}}"# + "\n"
            fm.createFile(atPath: u.path, contents: Data(meta.utf8))
            return u
        }
        _ = rollout("old", cwd: "/tmp/proj", at: start.addingTimeInterval(-600))
        _ = rollout("elsewhere", cwd: "/tmp/other", at: start.addingTimeInterval(2))
        let mine = rollout("mine", cwd: "/tmp/proj", at: start.addingTimeInterval(3))
        let found = CodexTranscriptParser.locate(cwd: "/tmp/proj", after: start, excluding: [], root: sessions)
        check("codex: rollout matched by folder and start time", found?.0.path == mine.path && found?.1.id == "mine", "\(String(describing: found?.0.lastPathComponent))")
        let none = CodexTranscriptParser.locate(cwd: "/tmp/proj", after: start, excluding: [mine.path], root: sessions)
        check("codex: claimed rollouts are skipped", none == nil)
    }

    static func follower(_ dir: URL) {
        let url = dir.appendingPathComponent("follow.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data((claudeFixture[1] + "\n" + claudeFixture[3] + "\n").utf8))
        let f = TranscriptFollower(url: url, kind: .claude, baseDir: dir.path)
        let first = f.poll()
        check("follower: reads existing lines", first.count == 2)
        let h = try! FileHandle(forWritingTo: url)
        h.seekToEndOfFile()
        let line = claudeFixture[4]
        let mid = line.index(line.startIndex, offsetBy: 40)
        h.write(Data(line[..<mid].utf8))
        check("follower: waits for a complete line", f.poll().isEmpty)
        h.write(Data((String(line[mid...]) + "\n").utf8))
        try? h.close()
        let more = f.poll()
        check("follower: picks up the appended line only", more.count == 1 && more.first?.kind == .tool && f.entries.count == 3)
        check("follower: nothing new means nothing emitted", f.poll().isEmpty)
    }

    static func sessionFollowing(_ dir: URL) {
        let folder = dir.appendingPathComponent("session-switches")
        Paths.ensure(folder)
        let model = AppModel()
        model.transcriptLocations = TranscriptLocations(claude: folder, codex: folder)
        let project = Project(path: folder.path)
        model.projects = [project]
        let chat = Chat(projectID: project.id, agentID: "claude")
        chat.sessionID = "launched-session"
        model.chats = [chat]
        model.selectedChatID = chat.id
        let center = StatusCenter()
        center.notifier = NoticeRecorder()
        center.start(model: model, live: false)
        var reloads = 0
        let subscription = model.readerReload.sink { if $0 == chat.id { reloads += 1 } }
        defer {
            subscription.cancel()
            chat.discoveryTimer?.invalidate()
            chat.follower?.stop()
        }
        func transcript(_ name: String, text: String) -> URL {
            let url = folder.appendingPathComponent(name + ".jsonl")
            let obj: [String: Any] = ["type": "user", "uuid": name,
                                      "message": ["role": "user", "content": text]]
            var data = try! JSONSerialization.data(withJSONObject: obj)
            data.append(0x0A)
            try! data.write(to: url)
            return url
        }
        func hook(_ id: String?, path: URL, event: String = "SessionStart", source: String = "resume") -> Data {
            var obj: [String: Any] = ["hook_event_name": event, "source": source, "transcript_path": path.path]
            if let id { obj["session_id"] = id }
            return try! JSONSerialization.data(withJSONObject: obj)
        }
        let events = AgentHooks.eventsFile(for: chat.id)
        func emit(_ data: Data) {
            if !FileManager.default.fileExists(atPath: events.path) { try! Data().write(to: events) }
            let h = try! FileHandle(forWritingTo: events)
            h.seekToEndOfFile()
            h.write(data + Data([0x0A]))
            try! h.close()
            center.poll()
        }
        let resumed = transcript("resumed", text: "Earlier conversation history")
        emit(hook("resumed-session", path: resumed))
        check("reader session: SessionStart resume updates both saved identifiers",
              chat.sessionID == "resumed-session" && chat.transcriptPath == resumed.path)
        check("reader session: resume loads the earlier conversation without switching chats",
              waitUntil(5) { chat.allEntries.first?.text == "Earlier conversation history" } && reloads == 1)
        let first = chat.follower
        emit(hook("resumed-session", path: resumed, event: "UserPromptSubmit"))
        check("reader session: unchanged hooks keep the follower and its history", chat.follower === first && reloads == 1)

        let cleared = transcript("cleared", text: "Fresh conversation")
        chat.liveEntries = [ReaderEntry(id: "old-notice", kind: .notice, text: "Old notice")]
        emit(hook("cleared-session", path: cleared, source: "clear"))
        check("reader session: clear changes the session and replaces the old history",
              waitUntil(5) { chat.allEntries.map(\.text) == ["Fresh conversation"] }
              && chat.sessionID == "cleared-session" && chat.transcriptPath == cleared.path)

        let moved = transcript("moved", text: "History at the new path")
        emit(hook("cleared-session", path: moved, event: "UserPromptSubmit"))
        check("reader session: a transcript path change reloads even with the same session ID",
              waitUntil(5) { chat.allEntries.first?.text == "History at the new path" } && chat.transcriptPath == moved.path)
        let pathOnly = transcript("path-only", text: "Path without an ID")
        emit(hook(nil, path: pathOnly, event: "Stop"))
        check("reader session: a path-only hook preserves the resume ID",
              waitUntil(5) { chat.allEntries.first?.text == "Path without an ID" } && chat.sessionID == "cleared-session")
        model.save()
        let saved = (try? Data(contentsOf: Paths.stateFile)).flatMap(SavedState.read)
        check("reader session: state persists the active ID and path for Resume Chat",
              saved?.chats.first?.sessionID == "cleared-session" && saved?.chats.first?.transcriptPath == pathOnly.path
              && chat.agent.resumeArguments(sessionID: chat.sessionID!)?.contains("cleared-session") == true)

        // Replaying old hooks after a relaunch must settle on the last conversation.
        let restored = Chat(id: chat.id, projectID: project.id, agentID: "claude")
        restored.sessionID = "launched-session"
        let restoredModel = AppModel()
        restoredModel.projects = [project]
        restoredModel.chats = [restored]
        let restoredCenter = StatusCenter()
        restoredCenter.notifier = NoticeRecorder()
        restoredCenter.start(model: restoredModel, live: false)
        check("reader session: relaunch replay follows the latest session without reopening old histories",
              restored.sessionID == "cleared-session" && restored.transcriptPath == pathOnly.path
              && waitUntil(5) { restored.allEntries.first?.text == "Path without an ID" })
        restored.follower?.stop()

        // The same, for a chat whose agent ended while hantuu was closed.
        let ended = Chat(id: chat.id, projectID: project.id, agentID: "claude")
        ended.sessionID = "launched-session"
        ended.status = .ended
        let endedModel = AppModel()
        endedModel.projects = [project]
        endedModel.chats = [ended]
        let endedCenter = StatusCenter()
        endedCenter.notifier = NoticeRecorder()
        endedCenter.start(model: endedModel, live: false)
        check("reader session: an ended chat comes back on the conversation its agent ended in",
              ended.sessionID == "cleared-session" && ended.transcriptPath == pathOnly.path
              && waitUntil(5) { ended.allEntries.first?.text == "Path without an ID" })
        ended.follower?.stop()

        // A stale worker must never append its history to the new conversation, even late.
        emit(hook("resumed-session", path: resumed))
        emit(hook("cleared-session", path: cleared, source: "clear"))
        check("reader session: a rapid switch ignores the old follower's pending delivery",
              waitUntil(5) { chat.allEntries.map(\.text) == ["Fresh conversation"] }
              && !waitUntil(0.5) { chat.allEntries.map(\.text) != ["Fresh conversation"] })

        // /clear before the next message: Claude Code hasn't written the new transcript yet.
        let unwritten = folder.appendingPathComponent("unwritten.jsonl")
        emit(hook("unwritten-session", path: unwritten, source: "clear"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check("reader session: clear before the next message empties the reader and waits for the file",
              chat.allEntries.isEmpty && chat.follower?.url.path == unwritten.path && chat.sessionID == "unwritten-session"
              && ReaderController.emptyText(for: chat).contains("first message"),
              ReaderController.emptyText(for: chat))
        _ = transcript("unwritten", text: "First message after clear")
        check("reader session: the cleared conversation shows up once Claude Code writes it",
              waitUntil(5) { chat.allEntries.map(\.text) == ["First message after clear"] })
        check("reader session: malformed and subagent hooks cannot redirect the main conversation",
              HookLineParser.session(Data("not JSON".utf8)) == nil
              && HookLineParser.session(Data(#"{"hook_event_name":"SessionStart","agent_id":"child","session_id":"child-session","transcript_path":"/child.jsonl"}"#.utf8)) == nil)
    }

    /// Times a synthetic history on every run, and a real one when HANTUU_BENCHMARK_TRANSCRIPT
    /// names it. The real one is copied into the throwaway folder first and never changed.
    static func transcriptTiming(_ dir: URL) {
        let url = dir.appendingPathComponent("large-transcript.jsonl")
        let line = Data((#"{"type":"assistant","message":{"role":"assistant","content":""#
                         + String(repeating: "Conversation text. ", count: 900) + #""}}"# + "\n").utf8)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try! FileHandle(forWritingTo: url)
        var bytes = 0
        while bytes < 4_000_000 { h.write(line); bytes += line.count }
        try! h.close()
        timeTranscript(url, label: "synthetic 4 MB")
        try? FileManager.default.removeItem(at: url)
        if let path = ProcessInfo.processInfo.environment["HANTUU_BENCHMARK_TRANSCRIPT"], !path.isEmpty {
            let copy = dir.appendingPathComponent("real-transcript-copy.jsonl")
            do {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
                defer { try? FileManager.default.removeItem(at: copy) }
                timeTranscript(copy, label: "real transcript copy")
            } catch {
                check("follower timing: copies the requested transcript", false, error.localizedDescription)
            }
        }
    }

    private static func timeTranscript(_ url: URL, label: String) {
        let f = TranscriptFollower(url: url, kind: .claude, baseDir: url.deletingLastPathComponent().path)
        var delivered = false
        var onMain = false
        f.onAppend = { _ in delivered = true; onMain = Thread.isMainThread }
        // A heartbeat on main: its longest gap is the longest the app would have stopped responding.
        var last = Date()
        var stall: TimeInterval = 0
        let beat = Timer(timeInterval: 0.005, repeats: true) { _ in
            stall = max(stall, Date().timeIntervalSince(last))
            last = Date()
        }
        RunLoop.main.add(beat, forMode: .common)
        let start = Date()
        last = start
        f.start(follow: false)
        let attachTime = Date().timeIntervalSince(start)
        let finished = waitUntil(60) { delivered }
        let shown = Date().timeIntervalSince(start)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        beat.invalidate()
        check("follower timing: \(label) attaches without blocking main for 300 ms", attachTime < 0.3)
        check("follower timing: \(label) reads and parses off main, then delivers on main", finished && onMain && !f.lastReadWasOnMain)
        print(String(format: "      %@: %llu bytes, attach %.2f ms, read and parse %.0f ms off main, longest main stall %.0f ms, entries after %.0f ms, %d entries",
                     label, LineTail.size(of: url), attachTime * 1000, f.lastReadDuration * 1000, stall * 1000,
                     shown * 1000, f.entries.count))
    }

    // MARK: Paths and routing

    static func paths(_ dir: URL) {
        let fm = FileManager.default
        let proj = dir.appendingPathComponent("🫣 Solo Projects/demo app")
        let src = proj.appendingPathComponent("src")
        Paths.ensure(src)
        fm.createFile(atPath: src.appendingPathComponent("app.swift").path, contents: Data("let x = 1\n".utf8))
        fm.createFile(atPath: proj.appendingPathComponent("notes.md").path, contents: Data("# Notes\n".utf8))
        fm.createFile(atPath: proj.appendingPathComponent("README").path, contents: Data("plain text readme\n".utf8))
        fm.createFile(atPath: proj.appendingPathComponent("blob.bin").path, contents: Data([0, 1, 2, 0, 255]))
        let png = NSImage(size: NSSize(width: 4, height: 4))
        png.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); png.unlockFocus()
        if let tiff = png.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) {
            fm.createFile(atPath: proj.appendingPathComponent("plot one.png").path, contents: data)
        }
        let pdf = PDFDocument()
        pdf.insert(PDFPage(image: png)!, at: 0)
        pdf.write(to: proj.appendingPathComponent("paper.pdf"))

        let abs = proj.path
        let text = """
        I edited \(abs)/src/app.swift:12 and wrote `notes.md`.
        The chart is at "\(abs)/plot one.png", the paper is \(abs)/paper.pdf.
        See src/app.swift, ./README, and ./notes.md. Also e.g. 1.2.3 and and/or are not paths.
        Your home is ~/Library, and the binary is blob.bin.
        """
        let found = PathDetector.detect(in: text, base: abs)
        func has(_ suffix: String, _ kind: FileKind, line: Int? = nil) -> Bool {
            found.contains { $0.path.hasSuffix(suffix) && $0.kind == kind && (line == nil || $0.line == line) }
        }
        check("paths: absolute path with spaces and emoji, with :line", has("src/app.swift", .text, line: 12), "\(found.map { "\($0.match) -> \($0.kind)" })")
        check("paths: image path with a space in a quote", has("plot one.png", .image))
        check("paths: PDF", has("paper.pdf", .pdf))
        check("paths: relative names resolve against the project", has("notes.md", .text) && found.contains { $0.match == "src/app.swift" })
        check("paths: extensionless text file", has("/README", .text))
        check("paths: binary is not text", has("blob.bin", .other))
        check("paths: ~/ expands", found.contains { $0.match == "~/Library" && $0.kind == .directory })
        check("paths: no false positives", !found.contains { $0.match.contains("1.2.3") || $0.match == "and/or" })

        var routes: [FileRouter.Route] = []
        FileRouter.shared.recorder = { routes.append($0) }
        defer { FileRouter.shared.recorder = nil }
        let r = FileRouter.shared
        r.openFromTerminal("https://example.com/x", isOSC8: false, base: abs)
        r.openFromTerminal("src/app.swift:7", isOSC8: false, base: abs)
        r.openFromTerminal("notes.md:3:1", isOSC8: false, base: abs)
        r.openFromTerminal("\(abs)/plot one.png", isOSC8: false, base: abs)
        r.openFromTerminal("file://\(abs.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)/src/app.swift", isOSC8: true, base: nil)
        r.openFromTerminal("javascript:alert(1)", isOSC8: true, base: abs)
        r.open(abs, base: nil)
        check("route: web link to the browser", routes.first == .browser(URL(string: "https://example.com/x")!))
        check("route: code file to the Code tab at its line", routes.count > 1 && routes[1] == .code("\(abs)/src/app.swift", 7))
        check("route: README.md:3 style links", routes.count > 2 && routes[2] == .code("\(abs)/notes.md", 3))
        check("route: images open in the Code tab", routes.count > 3 && routes[3] == .code("\(abs)/plot one.png", nil))
        check("route: OSC 8 file URL", routes.count > 4 && routes[4] == .code("\(abs)/src/app.swift", nil))
        check("route: unsafe OSC 8 scheme ignored", routes.count == 6 && routes[5] == .finder(abs), "\(routes)")
    }

    // MARK: Small things

    static func misc() {
        check("drop: shell-escaped path", ShellEscape.escape("/a b/(c) it's.png") == #"/a\ b/\(c\)\ it\'s.png"#)
        check("launch: command runs through the login shell", LoginShell.surfaceCommand(["claude", "--session-id", "abc-1"])
              == "\(ShellEscape.quote(LoginShell.path)) -l -i -c \(ShellEscape.quote("printf '\\033[H\\033[2J'; exec claude --session-id abc-1"))")
        check("launch: inherited agent-session variables dropped", ProcessInfo.processInfo.environment.keys.allSatisfy { !$0.hasPrefix("CLAUDE") && !$0.hasPrefix("CODEX_") })
        let all = AgentCatalog.known.flatMap { $0.launchArguments(sessionID: "x") + ($0.resumeArguments(sessionID: "x") ?? []) }
        check("launch: no permission-bypass flags", !all.contains { $0.contains("dangerously") || $0.contains("bypass") || $0 == "--yolo" || $0.contains("full-auto") })
        let detectOut = "zsh: some warning\n\(AgentCatalog.beginMarker)\nclaude=/Users/x/.local/bin/claude\ncodex=/Users/x/.local/bin/codex\naider=aider: aliased to foo\n\(AgentCatalog.endMarker)\n"
        let parsed = AgentCatalog.parseDetectOutput(detectOut)
        check("agents: parse login-shell lookup", parsed == ["claude": "/Users/x/.local/bin/claude", "codex": "/Users/x/.local/bin/codex"])
        check("keep awake: reads SleepDisabled 1", KeepAwake.parseSleepDisabled("System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n standby 1\n") == true)
        check("keep awake: reads SleepDisabled 0", KeepAwake.parseSleepDisabled(" SleepDisabled\t\t0\n hibernatemode 3\n") == false)
        check("title: spinner glyphs stripped", Chat.cleanTitle("✳ Fix the login bug") == "Fix the login bug" && Chat.cleanTitle("⠂ Claude Code") == "Claude Code")
        check("codex: context block detection", CodexTranscriptParser.isContextBlock("<environment_context>\n<cwd>/x</cwd>\n</environment_context>") && !CodexTranscriptParser.isContextBlock("Fix <b> tags"))
    }

    static func agentDetection() {
        let found = AgentCatalog.detect(timeout: 15)
        print("      agents found: \(found.map { "\($0.id) at \($0.path ?? "?")" }.joined(separator: ", "))")
        check("agents: claude found through the login shell", found.contains { $0.id == "claude" })
        check("agents: codex found through the login shell", found.contains { $0.id == "codex" })
    }

    // MARK: A real Ghostty surface

    final class Recorder: TerminalEvents {
        var exitCode: Int?
        var titles: [String] = []
        var closeRequested = false
        func terminalTitleDidChange(_ view: TerminalView, title: String) { titles.append(title) }
        func terminalNeedsAttention(_ view: TerminalView, reason: String) {}
        func terminalChildDidExit(_ view: TerminalView, code: Int) { exitCode = code }
        func terminalRequestedClose(_ view: TerminalView, processAlive: Bool) { closeRequested = true }
        func terminalFocusDidChange(_ view: TerminalView, focused: Bool) {}
    }

    static var testWindow: NSWindow?

    static func makeWindow() -> NSWindow {
        if let testWindow { return testWindow }
        // Off screen and never activated, so the test doesn't take focus.
        let w = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 820, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.orderFrontRegardless()
        testWindow = w
        return w
    }

    static func type(_ text: String, into view: TerminalView, window: NSWindow) {
        let codes: [Character: UInt16] = ["a": 0, "b": 11, "c": 8, "\r": 36]
        for ch in text {
            let s = String(ch)
            guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: s, charactersIgnoringModifiers: s,
                                            isARepeat: false, keyCode: codes[ch] ?? 0),
                  let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: s, charactersIgnoringModifiers: s,
                                            isARepeat: false, keyCode: codes[ch] ?? 0) else { continue }
            view.keyDown(with: ev)
            view.keyUp(with: up)
        }
    }

    static func mouse(_ type: NSEvent.EventType, at p: NSPoint, in view: TerminalView, window: NSWindow, mods: NSEvent.ModifierFlags) -> NSEvent? {
        let winPoint = view.convert(NSPoint(x: p.x, y: view.frame.height - p.y), to: nil)
        return NSEvent.mouseEvent(with: type, location: winPoint, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    static func surface(_ dir: URL) {
        guard let g = GhosttyApp.start() else {
            check("surface: libghostty starts", false, "ghostty_init/app_new failed")
            return
        }
        check("surface: libghostty starts", true)
        // hantuu's look picks hantuu-light or hantuu-dark from the colour scheme, and the
        // window chrome reads both backgrounds from libghostty at start.
        let near: (NSColor, Int) -> Bool = { c, hex in
            abs(c.redComponent - CGFloat(hex) / 255) < 0.01 && abs(c.blueComponent - CGFloat(hex) / 255) < 0.01
        }
        check("terminal: hantuu's own look is the default, with a light and a dark theme",
              Paths.terminalTheme != nil && !TerminalSettings.shared.useGhosttyConfig
                && near(Theme.darkBackground, 0x16) && near(Theme.lightBackground, 0xF7),
              "theme=\(Paths.terminalTheme?.path ?? "missing") dark=\(Theme.darkBackground.hexString) light=\(Theme.lightBackground.hexString) diagnostics=\(g.diagnostics)")
        g.setColorScheme(dark: false)
        let lightOK = g.appScheme == GHOSTTY_COLOR_SCHEME_LIGHT && g.surfaceScheme == GHOSTTY_COLOR_SCHEME_LIGHT
        g.setColorScheme(dark: true)
        check("terminal: light and dark reach libghostty", lightOK && g.appScheme == GHOSTTY_COLOR_SCHEME_DARK
              && g.surfaceScheme == GHOSTTY_COLOR_SCHEME_DARK && near(Theme.darkBackground, 0x16) && near(Theme.lightBackground, 0xF7))
        let w = makeWindow()
        let rec = Recorder()
        let script = #"printf 'hantuu-selftest-%s\n' ok; printf '\033]0;selftest title\007'; echo 'https://example.com/hantuu-selftest-link-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; read -r line; echo "got:$line"; read -r p; echo "path:$p"; exit 3"#
        let cmd = "/bin/sh -c \(ShellEscape.quote(script))"
        let view = TerminalView(app: g.app, launch: .init(workingDirectory: dir.path, command: cmd), handlesChildExit: true)
        view.events = rec
        view.frame = w.contentView!.bounds
        view.autoresizingMask = [.width, .height]
        w.contentView!.addSubview(view)
        w.makeFirstResponder(view)

        check("surface: command output reaches the terminal grid", waitUntil(10) { view.screenText().contains("hantuu-selftest-ok") }, String(view.screenText().suffix(300)))
        check("surface: terminal title action", waitUntil(3) { rec.titles.contains("selftest title") }, "\(rec.titles)")

        // Cmd-click the URL line. Find it from the cursor's pixel position (one row above).
        var routes: [FileRouter.Route] = []
        FileRouter.shared.recorder = { routes.append($0) }
        _ = waitUntil(3) { view.cellSize.height > 0 }
        if let surface = view.surface {
            var x = 0.0, y = 0.0, cw = 0.0, ch = 0.0
            ghostty_surface_ime_point(surface, &x, &y, &cw, &ch)
            let cellH = view.cellSize.height > 0 ? Double(view.cellSize.height) : 16
            // ime_point's y is the bottom of the cursor row, in points. The URL is one row up.
            for dy in [-1.5, -2.5, -0.75, -1.25] where routes.isEmpty {
                let p = NSPoint(x: x + 120, y: y + dy * cellH)
                if let mv = mouse(.mouseMoved, at: p, in: view, window: w, mods: .command) { view.mouseMoved(with: mv) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                if let d = mouse(.leftMouseDown, at: p, in: view, window: w, mods: .command) { view.mouseDown(with: d) }
                if let u = mouse(.leftMouseUp, at: p, in: view, window: w, mods: .command) { view.mouseUp(with: u) }
                _ = waitUntil(0.6) { !routes.isEmpty }
            }
        }
        FileRouter.shared.recorder = nil
        check("surface: Cmd-click on a URL routes to the browser", routes.contains { if case .browser(let u) = $0 { return u.absoluteString.contains("hantuu-selftest-link") }; return false }, "\(routes)")

        type("abc\r", into: view, window: w)
        check("surface: typed keys reach the program", waitUntil(5) { view.screenText().contains("got:abc") }, String(view.screenText().suffix(200)))

        // Same path a drop uses: shell-escaped path, typed as a paste.
        view.pasteText(ShellEscape.escape("/tmp/a b.png"))
        type("\r", into: view, window: w)
        check("surface: drop-style paste of an escaped path", waitUntil(5) { view.screenText().contains(#"path:/tmp/a\ b.png"#) }, String(view.screenText().suffix(200)))

        // The command exits 3, but macOS /usr/bin/login (which libghostty runs every command
        // under) exits 0 regardless, so only the exit itself is reliable.
        check("surface: child exit reported", waitUntil(5) { rec.exitCode != nil }, "exit=\(String(describing: rec.exitCode))")
        view.destroy()
    }

    // MARK: Reader rendering

    static func js(_ page: WebPage, _ script: String) -> Any? {
        var result: Any?
        var done = false
        page.webView.evaluateJavaScript(script) { r, e in
            result = r ?? e.map { "error: \($0)" }
            done = true
        }
        _ = waitUntil(5) { done }
        return result
    }

    static func reader(_ dir: URL) {
        guard Paths.webRoot != nil else {
            check("reader: web assets found", false, "Resources/web missing")
            return
        }
        let w = makeWindow()
        let page = WebPage(page: "reader.html", identifier: "selftest.reader")
        page.webView.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        w.contentView?.addSubview(page.webView)
        check("reader: page loads from the bundle with no network", waitUntil(10) { page.ready })

        let proj = dir.appendingPathComponent("🫣 Solo Projects/demo app").path
        var p = ClaudeTranscriptParser()
        var entries: [ReaderEntry] = []
        let mathText = "Here: \\(\\alpha+\\beta\\) and \\[x^2\\] then\n\n```swift\nlet a = 1\n```\n\nchart at \(proj)/plot one.png and code in src/app.swift:12\n\n```\nsrc/app.swift\n```"
        let extraObj: [String: Any] = ["type": "assistant", "uuid": "zz", "message": ["role": "assistant", "content": [["type": "text", "text": mathText]]]]
        let extra = String(decoding: try! JSONSerialization.data(withJSONObject: extraObj), as: UTF8.self)
        for line in claudeFixture + [extra] { entries += p.parse(line: Data(line.utf8)) }
        for i in entries.indices { entries[i].links = PathDetector.detect(in: entries[i].text + "\n" + (entries[i].detail ?? ""), base: proj) }
        page.call("reset", ["chatID": "t1", "entries": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(entries)), "emptyText": ""])
        _ = waitUntil(3) { (js(page, "document.querySelectorAll('section.entry').length") as? Int ?? 0) > 0 }

        let katex = js(page, "document.querySelectorAll('.katex').length") as? Int ?? 0
        check("reader: LaTeX rendered with KaTeX ($, $$, \\( \\), \\[ \\])", katex >= 4, "katex=\(katex)")
        let hl = js(page, "document.querySelectorAll('pre.hljs .hljs-keyword').length") as? Int ?? 0
        check("reader: code blocks highlighted", hl >= 1)
        let pathLinks = js(page, "Array.from(document.querySelectorAll('a.path')).map(a=>a.dataset.path).join('|')") as? String ?? ""
        check("reader: existing file paths become links", pathLinks.contains("src/app.swift") && pathLinks.contains("plot one.png"), pathLinks)
        let inBlock = js(page, "Array.from(document.querySelectorAll('pre a.path')).length") as? Int ?? 0
        check("reader: paths inside plain code blocks are linked", inBlock >= 1)
        let imgs = js(page, "document.querySelectorAll('img.inline-image').length") as? Int ?? 0
        check("reader: image paths shown inline", imgs >= 1)
        _ = js(page, "document.querySelector('img.inline-image').scrollIntoView(); 0")
        let loaded = waitUntil(5) { (js(page, "Array.from(document.querySelectorAll('img.inline-image')).every(i=>i.complete && i.naturalWidth>0)") as? Bool) == true }
        check("reader: local image served through hantuu://file", loaded)
        let thinking = js(page, "document.body.innerText.includes('secret reasoning')") as? Bool ?? true
        check("reader: published reasoning starts collapsed", thinking == false && (js(page, "document.querySelector('.reasoning details')?.open === false") as? Bool == true))
        let tools = js(page, "document.querySelectorAll('.entry.tool details > summary').length") as? Int ?? 0
        check("reader: tool calls collapsed to single lines", tools >= 2)
        let standout = js(page, "document.querySelectorAll('.entry.error, .entry.question, .entry.attention').length") as? Int ?? 0
        check("reader: errors, questions and permission notes stand out", standout >= 5, "count=\(standout)")

        // Scroll rule: stay put when reading further up, stick to the bottom when at the bottom.
        let many = (0..<60).map { ReaderEntry(id: "fill\($0)", kind: .assistant, text: "Paragraph \($0) with enough words to wrap a little in a narrow reader window.") }
        page.call("append", ["chatID": "t1", "entries": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(many))])
        _ = waitUntil(2) { (js(page, "document.querySelectorAll('section.entry').length") as? Int ?? 0) > 60 }
        _ = js(page, "document.scrollingElement.scrollTop = 120; 0")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let one = [ReaderEntry(id: "late1", kind: .assistant, text: "A new message while you read above.")]
        page.call("append", ["chatID": "t1", "entries": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(one))])
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let top = js(page, "document.scrollingElement.scrollTop") as? Double ?? -1
        let pill = js(page, "document.getElementById('newpill').hidden") as? Bool ?? true
        check("reader: appending keeps your place when scrolled up", abs(top - 120) < 2 && pill == false, "scrollTop=\(top) pillHidden=\(pill)")
        _ = js(page, "document.scrollingElement.scrollTop = document.scrollingElement.scrollHeight; 0")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let two = [ReaderEntry(id: "late2", kind: .assistant, text: "Another message, read at the bottom.")]
        page.call("append", ["chatID": "t1", "entries": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(two))])
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let atBottom = js(page, "Math.abs(document.scrollingElement.scrollHeight - document.scrollingElement.scrollTop - window.innerHeight) < 4") as? Bool ?? false
        check("reader: appending sticks to the bottom when you're at the bottom", atBottom)
    }
}
