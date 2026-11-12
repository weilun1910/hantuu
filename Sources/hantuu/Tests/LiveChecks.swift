import AppKit
import Combine
import GhosttyKit
import Darwin

/// Opt-in checks against installed CLIs. The ordinary self test only exercises the pure
/// parsing and selection rules below. No fixture test launches an agent or reads its home.
enum LiveCheckRules {
    static let agents = ["claude", "codex"]
    static let features = ["slash", "queued", "send-now", "relaunch", "subagents", "reader", "review", "sidebar", "side", "composer", "command-arguments"]

    /// Codex walks ancestors itself, so a Git ceiling environment variable is insufficient.
    static func gitAncestor(_ folder: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        var current = folder.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        for _ in 0..<256 {
            if exists(current.appendingPathComponent(".git")) { return current }
            guard current.path != "/" else { return nil }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            // URL can append ".." at the root instead of returning the same URL.
            guard parent.path.count < current.path.count else { return nil }
            current = parent
        }
        return nil
    }

    /// Missing, incomplete and wrong answers remain failures even after a process exits.
    static func sideAnswerFailure(completed: Bool, answer: SideQuestion?, token: String) -> String? {
        guard completed else { return "No answer before timeout." }
        guard let answer else { return "The side question produced no result." }
        guard answer.state == .answered else { return answer.error ?? "The side question did not finish successfully." }
        guard answer.answer.contains(token) else { return "The side answer did not contain the parent token." }
        return nil
    }

    /// Flush resource checkpoints so an externally killed run retains its last boundary.
    static func checkpoint(_ label: String) {
        var usage = rusage()
        let result = getrusage(RUSAGE_SELF, &usage)
        let peak = result == 0 ? String(usage.ru_maxrss) : "unavailable"
        print("live checkpoint: \(label) pid=\(getpid()) uptime=\(ProcessInfo.processInfo.systemUptime) peak_rss_bytes=\(peak)")
        fflush(stdout)
    }

    static func codexModel(for feature: String, configured: String?) -> String {
        configured ?? (["subagents", "send-now"].contains(feature) ? "gpt-6.1-sol" : "gpt-6-luna")
    }

    static func selection(_ value: String?, allowed: [String]) -> [String]? {
        guard let value else { return allowed }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !parts.isEmpty, parts.allSatisfy({ allowed.contains($0) }) else { return nil }
        return allowed.filter { parts.contains($0) }
    }

    /// Only rows with a description count, never the bare slash in the input box, a path,
    /// or a command mentioned in prose. Capture each page before comparing the catalogue.
    static func commands(on screen: String) -> Set<String> {
        Set(CommandMenuScreen.rows(screen).map(\.name))
    }

    /// Selection styling is absent from Ghostty's text capture. Keep moving through a
    /// whole viewport before treating unchanged text as the end of a short list.
    struct PopupScan {
        private var first: Set<String>?
        private var previous: Set<String> = []
        private var leftFirst = false
        private var unchanged = 0
        private(set) var commands: Set<String> = []

        mutating func observe(_ visible: Set<String>) -> Bool {
            guard !visible.isEmpty else { return false }
            commands.formUnion(visible)
            if first == nil { first = visible }
            if visible != first { leftFirst = true }
            if leftFirst && visible == first { return true }
            unchanged = visible == previous ? unchanged + 1 : 0
            previous = visible
            return unchanged >= max(16, visible.count * 2)
        }
    }

    static func canQueue(screenBusy: Bool, turnActive: Bool, startedAt: Date?, sentAt: Date,
                         typing: Bool, composerWorking: Bool) -> Bool {
        let freshTurn = turnActive && startedAt.map { $0 >= sentAt } == true
        return (screenBusy || freshTurn) && !typing && composerWorking
    }

    /// Claude's long-response probes wait for generated output before injecting input.
    /// Codex uses a fresh busy turn and still must expose its native Send now action.
    static func countOutputStarted(_ screen: String) -> Bool {
        screen.range(of: #"(?m)^[ \t]*[0-9]+ - this is the next number in the sequence\.[ \t]*$"#,
                     options: .regularExpression) != nil
    }

    static func featureEnabled(_ name: String, output: String) -> Bool? {
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.first == name, let last = words.last else { continue }
            if last == "true" { return true }
            if last == "false" { return false }
        }
        return nil
    }

    /// Trust, approval and update prompts are never answered, even when a picker was
    /// expected. Generic menus are allowed only during suggestion or model inspection.
    static func blocker(_ screen: String, allowingMenu: Bool = false) -> String? {
        let state = TerminalScreen.analyze(screen)
        if let menu = state.menu, menu.kind != .menu || !allowingMenu { return menu.title(agent: "Agent") }
        let tail = screen.split(whereSeparator: \.isNewline).suffix(24).joined(separator: "\n").lowercased()
        let approvals = ["do you want to proceed", "would you like to run", "allow this tool", "allow once",
                         "yes, allow", "approve this", "requires approval", "permission required",
                         "sign in to", "log in to", "select login method"]
        if approvals.contains(where: tail.contains) { return "Permission or sign-in prompt" }
        return nil
    }

    static func inside(_ child: URL, _ parent: URL) -> Bool {
        let c = child.standardizedFileURL.resolvingSymlinksInPath().path
        let p = parent.standardizedFileURL.resolvingSymlinksInPath().path
        return c == p || c.hasPrefix(p + "/")
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Following is about new transcript identity, even when a model repeats old prose.
    static func replyAfter(_ prompt: String, entries: [ReaderEntry], previousIDs: Set<String>) -> ReaderEntry? {
        guard let index = entries.lastIndex(where: { $0.kind == .user && $0.text == prompt && !previousIDs.contains($0.id) }) else { return nil }
        return entries.dropFirst(index + 1).first {
            $0.kind == .assistant && !previousIDs.contains($0.id) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

extension SelfTest {
    static func liveChecksLogic(_ dir: URL) {
        check("live checks: defaults cover both agents and all features",
              LiveCheckRules.selection(nil, allowed: LiveCheckRules.agents) == ["claude", "codex"] &&
              LiveCheckRules.selection(nil, allowed: LiveCheckRules.features) == LiveCheckRules.features)
        check("live checks: invalid selectors fail instead of silently running everything",
              LiveCheckRules.selection("", allowed: LiveCheckRules.agents) == nil &&
              LiveCheckRules.selection("claude,typo", allowed: LiveCheckRules.agents) == nil)
        check("live checks: selectors trim, deduplicate and retain stable order",
              LiveCheckRules.selection("codex, claude,codex", allowed: LiveCheckRules.agents) == ["claude", "codex"])
        var sideAnswer = SideQuestion(question: "Fixture")
        sideAnswer.state = .answered
        sideAnswer.answer = "fixture-token"
        check("live checks: a completed side answer has no timeout diagnostic", LiveCheckRules.sideAnswerFailure(completed: true, answer: sideAnswer, token: "fixture-token") == nil)
        check("live checks: a side timeout fails even with stale answer text", LiveCheckRules.sideAnswerFailure(completed: false, answer: sideAnswer, token: "fixture-token") != nil)
        check("live checks: a missing side answer fails", LiveCheckRules.sideAnswerFailure(completed: true, answer: nil, token: "fixture-token") != nil)
        check("live checks: the wrong side answer fails", LiveCheckRules.sideAnswerFailure(completed: true, answer: sideAnswer, token: "different-token") != nil)
        sideAnswer.state = .failed
        check("live checks: a failed side answer cannot pass on matching text", LiveCheckRules.sideAnswerFailure(completed: true, answer: sideAnswer, token: "fixture-token") != nil)
        let claude = "❯ /cost    Show usage\n  /model   Choose model\n❯ /\nRead /tmp/file now"
        let codex = "/status  Session information\n/model  Select model\n› /re\n/tmp/file  a path"
        check("live checks: suggestion rows exclude prompts, prose and file paths",
              LiveCheckRules.commands(on: claude) == ["cost", "model"] &&
              LiveCheckRules.commands(on: codex) == ["status", "model"])
        check("live checks: multi-agent gate distinguishes off from unknown",
              LiveCheckRules.featureEnabled("multi_agent", output: "multi_agent stable true\nmulti_agent_v2 stable false") == true &&
              LiveCheckRules.featureEnabled("multi_agent", output: "multi_agent stable false") == false &&
              LiveCheckRules.featureEnabled("multi_agent", output: "unexpected output") == nil)
        check("live checks: an available but disabled v2 flag can be enabled for one process",
              LiveCheckRules.featureEnabled("multi_agent_v2", output: "multi_agent stable true\nmulti_agent_v2 experimental false") == false)
        var scan = LiveCheckRules.PopupScan()
        let firstPage = Set((1...8).map { "command\($0)" })
        let nextPage = Set((2...9).map { "command\($0)" })
        var stoppedEarly = scan.observe(firstPage)
        for _ in 0..<8 { stoppedEarly = scan.observe(firstPage) || stoppedEarly }
        check("live checks: highlight-only moves do not end a popup scan", !stoppedEarly)
        check("live checks: scrolling collects commands beyond the first viewport", !scan.observe(nextPage) && scan.commands.count == 9)
        check("live checks: a full wrap ends popup traversal", scan.observe(firstPage))
        var short = LiveCheckRules.PopupScan()
        var finishedShort = false
        for _ in 0..<20 { finishedShort = short.observe(["model", "status"]) || finishedShort }
        check("live checks: a short unscrollable popup terminates after full traversals", finishedShort)
        var empty = LiveCheckRules.PopupScan()
        check("live checks: an empty capture cannot prove popup completion", !empty.observe([]))
        let sentAt = Date(timeIntervalSince1970: 100)
        check("live checks: a fresh turn can prove busy without an interrupt hint",
              LiveCheckRules.canQueue(screenBusy: false, turnActive: true, startedAt: sentAt, sentAt: sentAt,
                                      typing: false, composerWorking: true))
        check("live checks: Send now waits for generated count output",
              LiveCheckRules.countOutputStarted("Working\n  1 - this is the next number in the sequence.\n") &&
              !LiveCheckRules.countOutputStarted("Use this line format: <integer> - this is the next number in the sequence.") &&
              !LiveCheckRules.countOutputStarted("Working\nI will start counting."))
        check("live checks: stale turn state cannot prove a new turn is busy",
              !LiveCheckRules.canQueue(screenBusy: false, turnActive: true, startedAt: sentAt.addingTimeInterval(-1),
                                       sentAt: sentAt, typing: false, composerWorking: true))
        check("live checks: busy evidence waits until the first paste finishes",
              !LiveCheckRules.canQueue(screenBusy: true, turnActive: true, startedAt: sentAt, sentAt: sentAt,
                                       typing: true, composerWorking: true))
        check("live checks: idle and unready composers never qualify for queueing",
              !LiveCheckRules.canQueue(screenBusy: false, turnActive: false, startedAt: sentAt, sentAt: sentAt,
                                       typing: false, composerWorking: true) &&
              !LiveCheckRules.canQueue(screenBusy: true, turnActive: true, startedAt: sentAt, sentAt: sentAt,
                                       typing: false, composerWorking: false))
        check("live checks: trust, update and approval remain blocked inside expected pickers",
              ["Do you trust this folder?", "Update available. Update now", "Would you like to run this command?"].allSatisfy {
                  LiveCheckRules.blocker($0, allowingMenu: true) != nil
              })
        check("live checks: only an explicitly expected ordinary menu permits navigation",
              LiveCheckRules.blocker("Choose model\nEnter to select") != nil &&
              LiveCheckRules.blocker("Choose model\nEnter to select", allowingMenu: true) == nil)
        check("live checks: path containment respects folder boundaries",
              LiveCheckRules.inside(dir.appendingPathComponent("live/data"), dir) &&
              !LiveCheckRules.inside(URL(fileURLWithPath: dir.path + "-other/data"), dir))
        check("live checks: diagnostics stay on one line", LiveCheckRules.oneLine("a\nb\t c") == "a b c")
        let oldReply = ReaderEntry(id: "old-answer", kind: .assistant, text: "Repeated answer")
        let newPrompt = ReaderEntry(id: "new-prompt", kind: .user, text: "Second prompt")
        let newReply = ReaderEntry(id: "new-answer", kind: .assistant, text: "Repeated answer")
        let priorIDs: Set<String> = [oldReply.id]
        check("live checks: relaunch requires a new prompt and a new reply identity",
              LiveCheckRules.replyAfter(newPrompt.text, entries: [oldReply, newPrompt], previousIDs: priorIDs) == nil &&
              LiveCheckRules.replyAfter(newPrompt.text, entries: [newReply, newPrompt], previousIDs: priorIDs) == nil &&
              LiveCheckRules.replyAfter(newPrompt.text, entries: [oldReply, newPrompt, newReply], previousIDs: priorIDs)?.id == newReply.id)
        check("live checks: repeated old identity cannot prove relaunch following",
              LiveCheckRules.replyAfter(newPrompt.text, entries: [newPrompt, oldReply], previousIDs: priorIDs) == nil)
        check("live checks: side feature is selectable for both agents",
              LiveCheckRules.selection("side", allowed: LiveCheckRules.features) == ["side"])
        let fakeRoot = URL(fileURLWithPath: "/fixture/project")
        var nestedProbes = 0
        let nestedAncestor = LiveCheckRules.gitAncestor(fakeRoot.appendingPathComponent("tmp/fresh"), exists: {
            nestedProbes += 1
            return $0.path == "/fixture/project/.git" || nestedProbes > 16
        })
        check("live checks: nested folders find their Git ancestor in three probes",
              nestedAncestor?.path == fakeRoot.path && nestedProbes == 3)
        var noGitProbes = 0
        let noGitAncestor = LiveCheckRules.gitAncestor(URL(fileURLWithPath: "/private/var/folders/fixture/T/side-fresh"), exists: { _ in
            noGitProbes += 1
            // Force a failing result after the budget so a regression cannot hang the test.
            return noGitProbes > 16
        })
        check("live checks: a temp-style path without Git stops promptly",
              noGitAncestor == nil && noGitProbes > 0 && noGitProbes <= 16)
        var rootProbes = 0
        let rootAncestor = LiveCheckRules.gitAncestor(URL(fileURLWithPath: "/"), exists: { _ in
            rootProbes += 1
            return rootProbes > 1
        })
        check("live checks: the filesystem root without Git stops after one probe",
              rootAncestor == nil && rootProbes == 1)
        let gitFixture = dir.appendingPathComponent("live-git-fixture", isDirectory: true)
        let nested = gitFixture.appendingPathComponent("tmp/fresh", isDirectory: true)
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        // Worktrees use a .git file, which counts just like a repository's .git directory.
        try? Data("gitdir: /fixture/metadata\n".utf8).write(to: gitFixture.appendingPathComponent(".git"))
        check("live checks: a real nested fixture finds its worktree Git ancestor",
              LiveCheckRules.gitAncestor(nested)?.path == gitFixture.standardizedFileURL.resolvingSymlinksInPath().path)
        check("live checks: a separate side directory has no synthetic project ancestor",
              LiveCheckRules.gitAncestor(URL(fileURLWithPath: "/fixture/side"), exists: { $0.path == "/fixture/project/.git" }) == nil)
        check("live checks: child probe uses Sol unless its model is explicitly overridden",
              LiveCheckRules.codexModel(for: "subagents", configured: nil) == "gpt-6.1-sol" &&
              LiveCheckRules.codexModel(for: "queued", configured: nil) == "gpt-6-luna" &&
              LiveCheckRules.codexModel(for: "send-now", configured: nil) == "gpt-6.1-sol" &&
              LiveCheckRules.codexModel(for: "subagents", configured: "gpt-6-astra") == "gpt-6-astra")
    }

    static func liveChecks(_ dir: URL) {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["HANTUU_LIVE"], !raw.isEmpty else { return }
        guard let agents = LiveCheckRules.selection(env["HANTUU_LIVE_AGENTS"], allowed: LiveCheckRules.agents),
              let features = LiveCheckRules.selection(env["HANTUU_LIVE_FEATURES"], allowed: LiveCheckRules.features) else {
            check("live configuration: selectors", false, "Use claude,codex and slash,queued,send-now,relaunch,subagents,reader,review,sidebar,side,composer,command-arguments.")
            return
        }
        let folder = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard raw.hasPrefix("/"), FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              !LiveCheckRules.inside(folder, dir) else {
            check("live configuration: probe folder", false, "HANTUU_LIVE must be an existing absolute trusted folder outside the self-test workdir, which is deleted at startup.")
            return
        }
        guard LiveCheckRules.inside(Paths.dataDir, dir), SessionHelper.executable != nil,
              ProcessInfo.processInfo.environment["HANTUU_NO_PMSET"] == "1" else {
            check("live configuration: isolated app data and session helper", false,
                  "Run scripts/selftest.sh without HANTUU_DATA_DIR; hantuu-session and HANTUU_NO_PMSET=1 are required.")
            return
        }
        guard GhosttyApp.shared != nil || GhosttyApp.start() != nil else {
            check("live configuration: libghostty", false)
            return
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let found = AgentCatalog.detect()
        for agent in agents {
            guard found.contains(where: { $0.id == agent }) else {
                for feature in features { check("live \(agent) \(feature): installed CLI", false, "Executable not found in the login shell.") }
                continue
            }
            let version = LiveCheckRules.oneLine(LoginShell.run(agent + " --version", timeout: 15))
            check("live \(agent) setup: installed version \(version.isEmpty ? "unavailable" : version)", !version.isEmpty)
            // Pin the delegation API only for the subagent probe, without changing the
            // user's config. A model's metadata can override the older multi_agent flag.
            let multiAgent = agent == "codex" && features.contains("subagents")
                ? LiveCheckRules.featureEnabled("multi_agent_v2", output: LoginShell.run("codex features list", timeout: 15)) : true
            for feature in features {
                if agent == "codex", feature == "subagents", multiAgent == nil {
                    check("live codex subagents: v2 feature gate", false,
                          "codex features list did not expose multi_agent_v2. No prompt sent; this probe requires the v2 spawn_agent API.")
                    continue
                }
                LiveCheckRules.checkpoint("\(agent) \(feature) start")
                autoreleasepool {
                    let probe = LiveCheckSession(agent: agent, feature: feature, folder: folder, dir: dir,
                                                 codexModel: LiveCheckRules.codexModel(for: feature, configured: env["HANTUU_LIVE_CODEX_MODEL"]), agents: found)
                    defer { probe.finish() }
                    guard probe.start() else { return }
                    switch feature {
                    case "slash": probe.slash()
                    case "queued": probe.queued()
                    case "send-now": probe.sendNow()
                    case "relaunch": probe.relaunch()
                    case "subagents": probe.subagents()
                    case "reader": probe.readerParity()
                    case "review": probe.reviewFeedback()
                    case "sidebar": probe.sidebar()
                    case "side": probe.sideQuestions()
                    case "composer": probe.composerParity()
                    case "command-arguments": probe.commandArguments()
                    default: break
                    }
                }
                LiveCheckRules.checkpoint("\(agent) \(feature) cleaned up")
            }
        }
    }
}

/// Each feature has its own chat and helper PID. Failure never carries a menu into the
/// next feature. App data stays in the self test. The reader probe also creates one uniquely
/// named text file in the explicitly selected probe folder; CLIs write their own transcripts.
private final class LiveCheckSession {
    let agent: String
    let feature: String
    let folder: URL
    let dir: URL
    let codexModel: String
    private var model: AppModel?
    private let discoveredAgents: [AgentDefinition]
    private var chatID: UUID?
    private var info: SessionInfo?
    private var center: StatusCenter?
    private var watcher: BackgroundWatch?
    private var reader: ReaderModeController?
    private var childReader: SubagentReaderController?
    private var mode: ReaderMode?
    private var focus: AnyCancellable?
    private var window: NSWindow?
    private var host: FillView?
    private var failure: String?
    private var finished = false

    var chat: Chat? { model?.selectedChat }
    var terminal: TerminalView? { chat?.terminal }
    var screen: String { terminal?.activeScreenText() ?? "" }

    init(agent: String, feature: String, folder: URL, dir: URL, codexModel: String, agents: [AgentDefinition]) {
        self.agent = agent
        self.feature = feature
        self.folder = folder
        self.dir = dir
        self.codexModel = codexModel
        self.discoveredAgents = agents
    }

    private func report(_ name: String, _ ok: Bool, _ detail: String = "") {
        let seen = LiveCheckRules.oneLine(detail)
        SelfTest.check("live \(agent) \(feature): \(name)" + (ok && !seen.isEmpty ? " - " + seen : ""), ok,
                       LiveCheckRules.oneLine(failure ?? detail))
    }

    private func safe(allowingMenu: Bool = false) -> Bool {
        if failure != nil { return false }
        if let reason = LiveCheckRules.blocker(screen, allowingMenu: allowingMenu) {
            failure = "\(reason) left unanswered in \(folder.path). Trust that probe folder manually if needed. \(String(screen.suffix(450)))"
        } else if chat?.status == .ended || terminal?.processExited != false {
            failure = "Agent exited. \(String(screen.suffix(450)))"
        } else if chat?.activity == .needsPermission {
            failure = "Permission request left unanswered in \(folder.path)."
        }
        return failure == nil
    }

    private func tick() {
        center?.poll()
        reader?.refresh()
    }

    private func wait(_ seconds: TimeInterval, allowingMenu: Bool = false, until condition: () -> Bool) -> Bool {
        let completed = SelfTest.waitUntil(seconds) {
            self.tick()
            return !self.safe(allowingMenu: allowingMenu) || condition()
        }
        return completed && failure == nil
    }

    private func pause(_ seconds: TimeInterval, allowingMenu: Bool = false) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        return wait(seconds + 0.5, allowingMenu: allowingMenu) { Date() >= end }
    }

    func start() -> Bool {
        autoreleasepool { startSession() }
    }

    private func startSession() -> Bool {
        guard SessionHelper.prepare() else { report("private helper directory", false); return false }
        let app = AppModel()
        app.agents = discoveredAgents
        model = app
        let project = Project(path: folder.path)
        let chat = Chat(projectID: project.id, agentID: agent)
        if agent == "claude" { chat.sessionID = UUID().uuidString.lowercased() }
        app.projects = [project]
        app.chats = [chat]
        app.selectedChatID = chat.id
        chatID = chat.id
        var argv = chat.agent.launchArguments(sessionID: chat.sessionID)
        argv += agent == "claude" ? ["--model", "haiku"]
            : ["--model", codexModel, "-c", "model_reasoning_effort=\"low\""]
        if agent == "codex", feature == "subagents" {
            argv += ["-c", "features.multi_agent_v2=true"]
        }
        app.launch(chat, argv: argv, in: project)
        mount()
        if agent == "codex", feature == "subagents" {
            report("v2 delegation enabled for this process", true, "features.multi_agent_v2=true; no saved configuration changed.")
        }
        let ready = wait(90) {
            let state = TerminalScreen.analyze(self.screen)
            return state.ready && !state.busy && self.reader?.composerMode == .ready
        }
        info = SessionHelper.info(chat.id)
        report("started in trusted folder with session helper", ready && info != nil,
               ready && info != nil ? "model=\(agent == "claude" ? "haiku" : codexModel) helper=\(info!.pid) agent=\(info!.child)"
               : "No ready prompt or helper after 90 seconds. \(String(screen.suffix(450)))")
        return ready && info != nil
    }

    private func mount() {
        autoreleasepool { mountViews() }
    }

    private func mountViews() {
        guard let app = model, let chat = app.selectedChat, let terminal = chat.terminal else { return }
        let w = NSWindow(contentRect: NSRect(x: -8000, y: -4000, width: 1100, height: 780),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        let host = FillView(color: Theme.background)
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 780)
        w.contentView = host
        terminal.frame = host.bounds
        host.addSubview(terminal)
        window = w
        self.host = host
        let center = StatusCenter()
        center.notifier = SelfTest.NoticeRecorder()
        center.appIsActive = { true }
        center.start(model: app, live: false)
        self.center = center
        let settings = ChatSettings(file: dir.appendingPathComponent("live-\(chat.id)-settings.json"))
        settings.showChatsAsReader = true
        let mode = ReaderMode(settings: settings)
        self.mode = mode
        let rm = ReaderModeController(model: app, mode: mode)
        rm.commandDiscoveryEnabled = false
        rm.statusProvider = { [weak center] in center?.state(of: $0.id) }
        rm.permitsSubmit = { [weak self] _ in
            guard let self else { return false }
            // The command's own completion list is expected before submitting /model.
            return self.safe(allowingMenu: !LiveCheckRules.commands(on: self.screen).isEmpty)
        }
        reader = rm
        rm.install(in: host, top: host.topAnchor, above: terminal)
        rm.onLayoutChange = { [weak self] in self?.layout() }
        focus = app.focusRequest.sink { [weak self] view in
            guard let self else { return }
            self.layout()
            if let target = self.reader?.focusTarget(for: view) { self.window?.makeFirstResponder(target) }
        }
        let watcher = BackgroundWatch()
        // A short child can finish between the ordinary two-second polls.
        watcher.interval = 0.1
        watcher.deliver = { [weak center] id, summary in center?.backgroundChanged(id, summary) }
        watcher.start(model: app)
        self.watcher = watcher
        w.orderFrontRegardless()
        layout()
    }

    private func layout() {
        guard let chat, let reader else { return }
        let layout = reader.sync(selected: chat)
        terminal?.setVisible(!layout.showsReader)
        host?.layoutSubtreeIfNeeded()
    }

    private func unmount() {
        watcher?.stop()
        watcher = nil
        childReader?.root.removeFromSuperview()
        childReader = nil
        _ = reader?.sync(selected: nil)
        reader?.root.removeFromSuperview()
        reader?.peekBar.removeFromSuperview()
        reader = nil
        mode = nil
        focus = nil
        center = nil
        if let app = model {
            for chat in app.chats {
                chat.discoveryTimer?.invalidate()
                chat.discoveryTimer = nil
                chat.follower?.stop()
                chat.follower = nil
                chat.transcriptRecovery = nil
                chat.terminal?.events = nil
                chat.terminal?.destroy()
                chat.terminal = nil
            }
        }
        window?.orderOut(nil)
        window?.close()
        window = nil
        host = nil
        model = nil
    }

    func finish() {
        guard !finished else { return }
        finished = true
        // Capture IDs before detaching. The helper owns and signals only this session's
        // process group. Never kill a process by executable name.
        let owned = chatID.flatMap(SessionHelper.info) ?? info
        unmount()
        if let id = chatID { _ = SessionHelper.killNow(id) }
        func gone() -> Bool {
            if let id = chatID, SessionHelper.info(id) != nil { return false }
            guard let owned else { return true }
            return kill(owned.child, 0) != 0 && kill(owned.pid, 0) != 0
        }
        var stopped = SelfTest.waitUntil(8, gone)
        if !stopped, let id = chatID, let owned, let current = SessionHelper.info(id),
           current.pid == owned.pid, current.child == owned.child {
            // The socket request failed, but this session still proves ownership of the
            // PID. SIGTERM makes the helper stop its own child group and wait for it.
            kill(owned.pid, SIGTERM)
            stopped = SelfTest.waitUntil(8, gone)
        }
        report("cleanup stopped owned helper and agent PIDs", stopped,
               "helper=\(owned?.pid ?? -1) agent=\(owned?.child ?? -1).")
    }

    private func send(_ text: String) -> Bool {
        guard safe(), let reader else { return false }
        reader.refresh()
        reader.composer.textView.text = text
        return reader.send()
    }

    private func body(_ selector: String = "document.body") -> String {
        guard let page = reader?.reader?.page else { return "" }
        return SelfTest.js(page, "\(selector).innerText") as? String ?? ""
    }

    private func countUser(_ prompt: String, pending: Bool = false) -> Int {
        guard let page = reader?.reader?.page,
              let data = try? JSONEncoder().encode(prompt), let literal = String(data: data, encoding: .utf8) else { return -1 }
        let selector = pending ? "section.entry.user.pending" : "section.entry.user:not(.pending)"
        return (SelfTest.js(page, "Array.from(document.querySelectorAll('\(selector)')).filter(e => e.innerText.includes(\(literal))).length") as? NSNumber)?.intValue ?? -1
    }

    private func reply(_ token: String) -> Bool {
        guard let chat, let page = reader?.reader?.page,
              let data = try? JSONEncoder().encode(token), let literal = String(data: data, encoding: .utf8) else { return false }
        let rendered = SelfTest.js(page,
            "Array.from(document.querySelectorAll('section.entry.assistant')).some(e => e.innerText.includes(\(literal)))") as? Bool
        return chat.allEntries.contains { $0.kind == .assistant && $0.text.contains(token) } && rendered == true
    }

    private func arrowDown() {
        guard let surface = terminal?.surface else { return }
        var key = ghostty_input_key_s()
        key.keycode = 125
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.text = nil
        key.unshifted_codepoint = 0
        key.composing = false
        key.action = GHOSTTY_ACTION_PRESS
        _ = ghostty_surface_key(surface, key)
        key.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, key)
    }

    func slash() {
        var observed = Set<String>()
        var bounded = false
        // Selection highlighting is not present in activeScreenText. Repeated text is
        // expected while Down moves within one viewport, so it cannot end the traversal.
        for prefix in ["/"] {
            guard safe(), let terminal else { report("suggestion scan", false); return }
            terminal.typeCommandText(prefix)
            guard pause(0.6, allowingMenu: true) else { report("suggestion scan", false); return }
            var traversal = CommandMenuTraversal()
            while !traversal.finished && !traversal.capped {
                guard safe(allowingMenu: true) else { report("suggestion scan", false); return }
                traversal.observe(CommandMenuScreen.rows(screen))
                if traversal.finished || traversal.capped { break }
                arrowDown()
                guard pause(0.15, allowingMenu: true) else { report("suggestion scan", false); return }
            }
            observed.formUnion(traversal.commands.map(\.name))
            bounded = bounded || traversal.capped
            terminal.pressEscape()
            terminal.pressBackspace(times: prefix.count)
            guard wait(3, allowingMenu: true, until: { CommandMenuScreen.emptyInput(self.screen, agent: self.agent) }) else {
                let capture = dir.appendingPathComponent("live-" + agent + "-slash-cleanup.json")
                let details: [String: Any] = ["screen": screen, "lines": screen.components(separatedBy: "\n"),
                                             "input": CommandMenuScreen.input(screen, agent: agent) ?? "unrecognized"]
                if let data = try? JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted]) { try? data.write(to: capture) }
                report("cleared suggestions", false, "input=\(CommandMenuScreen.input(screen, agent: agent) ?? "unrecognized"); full capture=\(capture.path); \(String(screen.suffix(600)))"); return
            }
        }
        report("suggestions paged without submitting", !observed.isEmpty && !bounded,
               "Observed \(observed.sorted().joined(separator: ",")); traversal cap reached=\(bounded).")
        guard !observed.isEmpty, !bounded, failure == nil, let chat, let reader else { return }
        // Exercise production discovery separately. Comparing the static table to a live
        // menu cannot account for account skills or feature gates.
        let inputBeforeDiscovery = CommandMenuScreen.input(screen, agent: agent)
        reader.commandDiscoveryEnabled = true
        reader.composer.textView.text = "/"
        reader.composer.textView.setSelectedRange(NSRange(location: 1, length: 0))
        reader.composer.textView.updateCommands()
        reader.composer.textView.onCommandQuery?()
        if CommandMenuProbe.supportsAutomaticHarvest(agent: agent) {
            let discovered = wait(100, allowingMenu: true) { reader.hasObservedCommands && !reader.isDiscoveringCommands }
            report("reader harvests its idle menu and restores input", discovered && CommandMenuScreen.emptyInput(screen, agent: agent),
                   "identity waiting=\(chat.codexIdentityWaiting), probe active=\(reader.isDiscoveringCommands), composer=\(reader.composerMode); " + String(screen.suffix(450)))
            guard discovered else { return }
            let names = Set(reader.composer.textView.commandCatalog.filter { $0.sigil == "/" && $0.aliasOf == nil }.map(\.name))
            report("TUI commands present in reader", observed.subtracting(names).isEmpty,
                   "Missing in reader: \(observed.subtracting(names).sorted().joined(separator: ",")).")
            report("reader commands observed in TUI", names.subtracting(observed).isEmpty,
                   "Not observed in TUI: \(names.subtracting(observed).sorted().joined(separator: ",")).")
        } else {
            let loaded = wait(10) { !reader.composer.textView.commandCatalog.isEmpty }
            let settled = pause(1)
            report("automatic harvest disabled; catalogue leaves terminal input unchanged",
                   loaded && settled && !reader.isDiscoveringCommands && !reader.hasObservedCommands &&
                   inputBeforeDiscovery != nil && CommandMenuScreen.input(screen, agent: agent) == inputBeforeDiscovery &&
                   reader.composer.textView.string == "/")
        }
        reader.composer.textView.text = ""

        let sent = send("/model")
        let peeked = sent && wait(15, allowingMenu: true) {
            self.mode?.isPeeking(chat) == true && TerminalScreen.analyze(self.screen).menu != nil &&
                self.screen.lowercased().contains("model") && CommandMenuScreen.rows(self.screen).isEmpty &&
                CommandMenuScreen.input(self.screen, agent: self.agent) != "/model"
        }
        report("/model opens the real picker and peeks terminal", peeked, String(screen.suffix(450)))
        guard peeked, safe(allowingMenu: true) else { return }
        dismissPicker()
        let returned = wait(15, allowingMenu: true) {
            TerminalScreen.analyze(self.screen).menu == nil && self.mode?.showsReader(chat) == true &&
                self.window?.firstResponder === self.reader?.composer.textView
        }
        report("Esc returns to reader with composer focus", returned, String(screen.suffix(450)))
        guard returned else { return }

        // A harmless local command with arguments must execute once and clear its input.
        let title = "slash-check-" + UUID().uuidString.prefix(8).lowercased()
        let rename = "/rename " + title
        let renamed = send(rename) && wait(15, allowingMenu: true) {
            reader.isTyping == false && CommandMenuScreen.emptyInput(self.screen, agent: self.agent) &&
                (self.screen.contains(title) || chat.terminalTitle.contains(title)) && !TerminalScreen.analyze(self.screen).busy
        }
        report("/rename with arguments executes and clears the input", renamed,
               "input review=\(chat.pendingMessages.inputNeedsReview), pending=\(chat.pendingMessages.entries.map { $0.pendingState ?? "unknown" }), title=\(chat.terminalTitle); " + String(screen.suffix(450)))
        guard renamed else { return }

        // /cost is absent from Claude 2.1.322's menu. /status exists in both providers.
        let command = "/status"
        let before = Set(chat.allEntries.map(\.id))
        let commandSent = send(command)
        let shown = commandSent && wait(15, allowingMenu: true) {
            let added = chat.allEntries.filter { !before.contains($0.id) }
            let rendered = added.contains { $0.kind == .notice && !$0.text.hasPrefix("Ran /") && self.body().contains($0.text) }
            let markers = ["context", "session", "token", "usage", "version", "model"]
            let terminalOutput = markers.contains { self.screen.lowercased().contains($0) }
            return rendered || (self.mode?.isPeeking(chat) == true && terminalOutput && self.reader?.isTyping == false &&
                CommandMenuScreen.input(self.screen, agent: self.agent) != command)
        }
        let notices = chat.allEntries.filter { !before.contains($0.id) && $0.kind == .notice }.map(\.text).joined(separator: " | ")
        report("\(command) exposes local output", shown, "reader notices=\(notices); terminal peek=\(mode?.isPeeking(chat) == true); \(String(screen.suffix(450)))")
        report("reader presentation for local command", shown,
               notices.isEmpty ? "Terminal peek; no transcript notice." : notices)
    }

    private func dismissPicker() {
        let wasReasoning = TerminalScreen.codexPicker(screen) == .reasoning
        terminal?.pressEscape()
        if wasReasoning {
            let parentPicker = wait(5, allowingMenu: true) { TerminalScreen.codexPicker(self.screen) != .reasoning }
            if parentPicker, TerminalScreen.codexPicker(screen) == .model { terminal?.pressEscape() }
        }
    }

    func queued() {
        let first = "Without tools or file access, write every integer from 1 to 400, one per line. After each integer write: this is the next number in the sequence. Do not abbreviate, summarize, or skip any lines. Finish with done."
        let token = "queue" + UUID().uuidString.prefix(8).lowercased()
        let second = "Without tools, reply only \(token)."
        let sentAt = Date()
        let sent = send(first)
        var queued = false
        var busyScreen = ""
        var evidence = ""
        let busy = sent && wait(60) {
            guard let chat = self.chat else { return false }
            let state = self.center?.state(of: chat.id)
            let screenBusy = TerminalScreen.analyze(self.screen).busy
            guard LiveCheckRules.canQueue(screenBusy: screenBusy, turnActive: state?.turnActive == true,
                                          startedAt: state?.turnStartedAt, sentAt: sentAt,
                                          typing: self.reader?.isTyping != false,
                                          composerWorking: self.reader?.composerMode.isWorking == true) else { return false }
            busyScreen = String(self.screen.suffix(450))
            evidence = "screen busy=\(screenBusy), turn active=\(state?.turnActive == true)"
            // Send during this poll, before logging or asking WebKit for rendered text.
            queued = self.send(second)
            return true
        }
        report("first turn is busy before second send", busy, evidence + "; " + (busy ? busyScreen : String(screen.suffix(450))))
        guard busy, let chat else { return }
        let pending = chat.pendingMessages.entries.filter { $0.text == second && $0.pending == true }
        report("second send immediately enters pending queue", queued && pending.count == 1,
               "send accepted=\(queued), input review=\(chat.pendingMessages.inputNeedsReview), mode=\(String(describing: reader?.composerMode)), matching pending entries=\(pending.count).")
        let shown = wait(3) { self.countUser(second, pending: true) == 1 && self.body().contains("Queued") && self.body().contains("Send now") }
        report("reader shows one queued message with Send now", shown, String(body().suffix(450)))
        let delivered = wait(240) {
            chat.allEntries.filter { $0.kind == .user && $0.text == second }.count == 1 &&
                !chat.pendingMessages.entries.contains { $0.text == second } && self.reply(token)
        }
        report("queued send becomes one real user message and receives reply", delivered,
               "users=\(chat.allEntries.filter { $0.kind == .user && $0.text == second }.count), pending=\(chat.pendingMessages.entries.count).")
        report("reader has no duplicate after queue delivery",
               delivered && countUser(first) == 1 && countUser(second) == 1 && countUser(second, pending: true) == 0,
               "first=\(countUser(first)) second=\(countUser(second)) pending=\(countUser(second, pending: true)).")
    }

    func sideQuestions() {
        guard let app = model, let chat, let host,
              let executable = app.agents.first(where: { $0.id == agent })?.path,
              FileManager.default.isExecutableFile(atPath: executable) else {
            report("side CLI is available", false)
            return
        }
        let token = "side" + UUID().uuidString.prefix(8).lowercased()
        let parentPrompt = "Remember the token \(token). Reply only ready. Do not use tools."
        guard send(parentPrompt) else { report("parent prompt sent", false); return }
        let parentReady = wait(90) {
            self.reply("ready") && self.reader?.composerMode == .ready && chat.sessionID != nil && chat.transcriptPath != nil
        }
        report("tiny parent answer rendered and session discovered", parentReady)
        guard parentReady, let session = chat.sessionID, let transcript = chat.transcriptPath else { return }
        guard pause(0.5) else { return }
        let parentEntries = chat.allEntries
        let beforeTranscript = try? Data(contentsOf: URL(fileURLWithPath: transcript))
        let parentInput = reader?.composer.textView.string
        let store = app.sideChats
        // Only the live probe pins cheaper models. The production command remains unchanged.
        store.commandOverride = { provider, arguments in
            var args = arguments
            if provider == "claude" { args += ["--model", "haiku"] }
            else { args.insert(contentsOf: ["--model", self.codexModel, "-c", "model_reasoning_effort=\"low\""], at: 1) }
            return (URL(fileURLWithPath: executable), args)
        }
        let panel = SidePanelController(model: app)
        panel.root.frame = NSRect(x: 540, y: 0, width: 560, height: 700)
        host.addSubview(panel.root)
        panel.sync(active: true)
        var observedStream = false
        let subscription = store.$histories.sink { histories in
            if let last = histories[chat.id]?.last, last.state == .streaming && last.answer.contains(token) {
                observedStream = true
            }
        }
        // The parent remains in the trusted probe project. Only the side process changes
        // directory, reproducing a fork requested from a folder with no Git ancestor.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("hantuu-live-side-" + UUID().uuidString.lowercased(), isDirectory: true)
        defer {
            store.stop(chat.id)
            let stopped = SelfTest.waitUntil(5) { !store.running.contains(chat.id) }
            report("side process stopped before cleanup", stopped)
            subscription.cancel()
            store.commandOverride = nil
            panel.sync(active: false)
            panel.root.removeFromSuperview()
            if stopped { try? FileManager.default.removeItem(at: temp) }
        }
        func renderedAnswer() -> Bool {
            guard let data = try? JSONEncoder().encode(token), let literal = String(data: data, encoding: .utf8) else { return false }
            let count = store.histories[chat.id]?.filter { !$0.answer.isEmpty }.count ?? 0
            return (SelfTest.js(panel.reader.page,
                "(() => { const rows = Array.from(document.querySelectorAll('section.entry.assistant')); return rows.length === \(count) && rows.slice(-1).some(e => e.innerText.includes(\(literal))); })()") as? Bool) == true
        }
        func awaitAnswer(_ name: String, after previousIDs: Set<UUID>) -> Bool {
            let completed = wait(90) {
                guard let last = store.histories[chat.id]?.last, !previousIDs.contains(last.id) else { return false }
                return !store.running.contains(chat.id)
            }
            let latest = store.histories[chat.id]?.last
            let last = latest.flatMap { previousIDs.contains($0.id) ? nil : $0 }
            let error = LiveCheckRules.sideAnswerFailure(completed: completed, answer: last, token: token)
            let answered = error == nil
            report(name + " answers from the forked parent", answered, error ?? "")
            let rendered = answered && wait(10) { renderedAnswer() }
            report(name + " streams into the Side tab", rendered && observedStream && app.panelTab == .side)
            return answered && rendered
        }
        let firstQuestionIDs = Set((store.histories[chat.id] ?? []).map(\.id))
        guard send("/btw What token did I ask you to remember? Reply only the token. Do not use tools.") else {
            report("reader routes side question", false)
            return
        }
        guard awaitAnswer("chat folder", after: firstQuestionIDs) else { return }
        do { try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true) }
        catch { report("fresh non-git folder created", false, error.localizedDescription); return }
        let outsideGit = LiveCheckRules.gitAncestor(temp) == nil
        report("fresh side folder has no Git ancestor", outsideGit)
        guard outsideGit else { return }
        observedStream = false
        let secondQuestionIDs = Set((store.histories[chat.id] ?? []).map(\.id))
        let asked = store.ask(chat: chat.id, agent: agent, session: session, executable: executable,
                              folder: temp.path, question: "Repeat the token from the parent conversation. Reply only that token. Do not use tools.")
        report("side command starts in a fresh non-git folder", asked)
        guard asked, awaitAnswer("fresh non-git folder", after: secondQuestionIDs) else { return }
        report("side answers leave parent transcript and input unchanged",
               beforeTranscript != nil && beforeTranscript == (try? Data(contentsOf: URL(fileURLWithPath: transcript)))
                && chat.allEntries == parentEntries && reader?.composer.textView.string == parentInput
                && chat.sessionID == session)
    }

    func sendNow() {
        let token = "received" + UUID().uuidString.prefix(8).lowercased()
        let finished = "finished" + UUID().uuidString.prefix(8).lowercased()
        let count = agent == "codex" ? 400 : 2000
        let first = "Without tools or file access, write every integer from 1 to \(count), one per line. Use exactly this line format: <integer> - this is the next number in the sequence. Do not abbreviate, summarize, or skip any lines. Finish with \(finished)."
        let second = "Stop counting now. Without tools, reply only \(token)."
        guard let chat else { return }
        func completedCount() -> Bool {
            chat.allEntries.contains { $0.kind == .assistant && $0.text.contains(finished) }
        }
        let sentAt = Date()
        let sent = send(first)
        var queued = false
        var busyEvidence = ""
        let busy = sent && wait(60) {
            let state = self.center?.state(of: chat.id)
            let screenBusy = TerminalScreen.analyze(self.screen).busy
            guard !completedCount(), (self.agent == "codex" || LiveCheckRules.countOutputStarted(self.screen)), LiveCheckRules.canQueue(screenBusy: screenBusy,
                turnActive: state?.turnActive == true, startedAt: state?.turnStartedAt, sentAt: sentAt,
                typing: self.reader?.isTyping != false, composerWorking: self.reader?.composerMode.isWorking == true) else { return false }
            busyEvidence = "screen busy=\(screenBusy), turn active=\(state?.turnActive == true); " + String(self.screen.suffix(450))
            queued = self.send(second)
            return true
        }
        report("count is running before queueing", busy, busyEvidence.isEmpty ? String(screen.suffix(450)) : busyEvidence)
        guard busy, let reader, let page = reader.reader?.page else { return }
        let id = chat.pendingMessages.entries.first(where: { $0.text == second })?.id
        let locallyQueued = id.map { chat.pendingMessages.stage(id: $0) == .waiting } == true
        report("default send immediately creates an editable queue entry", queued && locallyQueued)
        var actionable = false
        var accepted = false
        reader.reader?.onQueueAction = { [weak reader] chatID, messageID, action in
            if action == "send" || action == "sendWithQueue" {
                accepted = reader?.sendNow(chatID: chatID, id: messageID) == true
            }
        }
        let observed = queued && wait(8) {
            guard !completedCount(), let id,
                  let data = try? JSONEncoder().encode(id), let literal = String(data: data, encoding: .utf8) else { return false }
            actionable = (SelfTest.js(page, """
                (() => { const row = Array.from(document.querySelectorAll('.entry.pending')).find(e => e.dataset.id === \(literal));
                  const button = row && Array.from(row.querySelectorAll('.queue-action')).find(b => b.textContent === 'Send now' || b.textContent === 'Send with agent queue');
                  if (!button) return false; button.click(); return true; })()
                """) as? Bool) == true
            return actionable
        }
        report("reader renders and clicks Send now", observed && actionable)
        guard observed, actionable, let id else { return }
        let requested = wait(8) {
            accepted && chat.pendingMessages.entries.contains { $0.id == id && $0.deliveryRequested == true }
        }
        report("Send now confirms the native queue and requests delivery", requested,
               "A naturally accepted steer cannot prove native promotion. " + String(screen.suffix(450)))
        guard requested else { return }
        var receivedBeforeFinish = false
        let received = wait(120) {
            if completedCount() { return true }
            receivedBeforeFinish = chat.allEntries.contains { $0.kind == .user && $0.text == second }
            return receivedBeforeFinish
        }
        report("agent receives queued instruction before count finishes", received && receivedBeforeFinish)
        guard receivedBeforeFinish else { return }
        let answered = wait(120) { self.reply(token) && !chat.pendingMessages.entries.contains { $0.id == id } }
        report("Send now reconciles its bubble and receives the requested answer", answered &&
               countUser(second) == 1 && countUser(second, pending: true) == 0,
               "delivered=\(countUser(second)), pending=\(countUser(second, pending: true)).")
    }

    /// Opt-in only. Uses the production panel service and its reader transport, never
    /// terminal.submit. Both providers run this same retained-comment/receipt contract.
    func reviewFeedback() {
        guard safe(), let app = model, let chat, let reader else { return }
        let service = PanelFeedbackDelivery(url: dir.appendingPathComponent("live-review-\(chat.id).json"))
        let wrongChat = UUID()
        let rejectedComment = ReviewComment(root: folder.path, path: "review-fixture.txt", side: "new",
            start: 1, end: 1, quoted: ["fixture"], body: "Do not send this stale-chat review.", revision: "fixture-1")
        let wrong = service.send(comments: [rejectedComment], folder: folder.path, chatID: wrongChat, model: app) { _ in
            self.report("stale-chat callback must never run", false)
        }
        report("stale chat is rejected without pending input", !wrong && chat.pendingMessages.isEmpty && service.latest(for: wrongChat)?.state == .failed)
        guard !wrong else { return }

        for busy in [false, true] {
            let token = "review" + UUID().uuidString.prefix(8).lowercased()
            let draft = "Keep my unfinished composer draft " + token
            reader.composer.textView.text = draft
            let c = ReviewComment(root: folder.path, path: "review-fixture.txt", side: "new", start: 1, end: 1,
                quoted: ["This is a synthetic review anchor; do not access a file."],
                body: "This is a delivery test. Do not use tools or change files. Reply only \(token).", revision: "fixture-1")
            var retained = [c]
            var receipts = 0
            func submitReview() -> Bool {
                reader.composer.textView.text = draft
                return service.send(comments: retained, folder: folder.path, chatID: chat.id, model: app) { delivered in
                    receipts += 1
                    retained.removeAll { delivered.contains($0) }
                }
            }
            var sent = false
            if busy {
                let began = Date()
                let workingPrompt = "Without tools or file access, write every integer from 1 to 400, one per line. Use exactly this line format: <integer> - this is the next number in the sequence. Do not abbreviate, summarize, or skip any lines. Finish with done."
                let started = send(workingPrompt)
                let working = started && wait(60) {
                    let state = self.center?.state(of: chat.id)
                    guard (self.agent == "codex" || LiveCheckRules.countOutputStarted(self.screen)),
                          LiveCheckRules.canQueue(screenBusy: TerminalScreen.analyze(self.screen).busy,
                            turnActive: state?.turnActive == true, startedAt: state?.turnStartedAt, sentAt: began,
                            typing: reader.isTyping, composerWorking: reader.composerMode.isWorking) else { return false }
                    sent = submitReview()
                    return true
                }
                report("review queue starts during real work", working, String(screen.suffix(450)))
                guard working else { return }
            } else { sent = submitReview() }
            let batch = service.latest(for: chat.id)
            report("\(busy ? "queued" : "idle") review retains comments and draft before acknowledgement",
                sent && retained == [c] && reader.composer.textView.string == draft && receipts == 0 &&
                batch?.state == (busy ? .queued : .sending) && chat.pendingMessages.entries.contains { $0.id == batch?.id })
            guard sent, let batch else { return }
            let delivered = wait(busy ? 300 : 120) {
                service.latest(for: chat.id)?.state == .delivered && self.reply(token) &&
                self.reader?.composerMode == .ready && !TerminalScreen.analyze(self.screen).busy
            }
            report("\(busy ? "queued" : "idle") review removes only after matching receipt",
                delivered && receipts == 1 && retained.isEmpty && !chat.pendingMessages.entries.contains { $0.id == batch.id })
            report("review routes once to owning chat and preserves composer",
                delivered && chat.allEntries.filter { $0.kind == .user && $0.text == batch.text }.count == 1 &&
                reader.composer.textView.string == draft && countUser(batch.text, pending: true) == 0)
            guard delivered else { return }
        }
    }

    func relaunch() {
        let beforeToken = "before" + UUID().uuidString.prefix(8).lowercased()
        let afterToken = "after" + UUID().uuidString.prefix(8).lowercased()
        let first = "Without tools, reply only \(beforeToken)."
        let second = "Without tools, reply only \(afterToken)."
        let sent = send(first)
        let answered = sent && wait(120) { self.reply(beforeToken) && self.reader?.composerMode == .ready && !TerminalScreen.analyze(self.screen).busy }
        report("first message and reply rendered before quit", answered)
        guard answered, let id = chatID, let previous = SessionHelper.info(id) else { return }
        model?.save()
        weak var oldModel = model
        weak var oldReader = reader
        weak var oldTranscriptReader = reader?.reader
        weak var oldPage = reader?.reader?.page
        weak var oldPeek = reader?.peekBar
        autoreleasepool { unmount() }
        let released = SelfTest.waitUntil(10) {
            autoreleasepool {
                SessionHelper.info(id)?.attached == false && oldModel == nil && oldReader == nil &&
                    oldTranscriptReader == nil && oldPage == nil && oldPeek == nil
            }
        }
        let detached = SessionHelper.info(id)?.attached == false
        report("quit releases app objects while the same agent survives",
               released && SessionHelper.info(id)?.child == previous.child,
               "detached=\(detached), model released=\(oldModel == nil), reader released=\(oldReader == nil), transcript reader released=\(oldTranscriptReader == nil), page released=\(oldPage == nil), peek released=\(oldPeek == nil).")
        let restored = AppModel()
        restored.agents = discoveredAgents
        model = restored
        restored.load()
        restored.select(id)
        mount()
        let reattached = wait(60) {
            SessionHelper.info(id)?.child == previous.child && SessionHelper.info(id)?.attached == true &&
                self.reader?.composerMode == .ready && self.reply(beforeToken)
        }
        report("saved state reload reattaches same PID and replays history", reattached)
        guard reattached else { return }
        let previousIDs = Set(chat?.allEntries.map(\.id) ?? [])
        let nextSent = send(second)
        var afterReply: ReaderEntry?
        let replied = nextSent && wait(120) {
            guard let page = self.reader?.reader?.page,
                  let entry = LiveCheckRules.replyAfter(second, entries: self.chat?.allEntries ?? [], previousIDs: previousIDs) else { return false }
            let literal = String(decoding: try! JSONEncoder().encode(entry.id), as: UTF8.self)
            let visible = SelfTest.js(page, "Array.from(document.querySelectorAll('section.entry.assistant')).some(e => e.dataset.id === \(literal) && e.innerText.trim().length > 0)") as? Bool == true
            if visible { afterReply = entry }
            return visible
        }
        report("reader follows message and reply after relaunch",
               replied && countUser(first) == 1 && countUser(second) == 1 && reply(beforeToken),
               "first=\(countUser(first)), second=\(countUser(second)), new reply=\(afterReply?.id ?? "missing"), requested token matched=\(afterReply?.text.contains(afterToken) == true); \(String(screen.suffix(450)))")
    }

    /// One inexpensive turn supplies real evidence. No tool gate or permission policy is changed.
    func readerParity() {
        guard let chat else { return }
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let stdout = "readerstdout" + suffix
        let stderr = "readerfailure" + suffix
        let done = "readerdone" + suffix
        let before = "readerbefore" + suffix
        let after = "readerafter" + suffix
        let planText = "Reader probe " + suffix
        let file = folder.appendingPathComponent("hantuu-reader-probe-" + suffix + ".txt")
        guard LiveCheckRules.inside(file, folder), !FileManager.default.fileExists(atPath: file.path) else {
            report("unique probe-owned file", false); return
        }
        let editTools = agent == "claude" ? "Write then Edit" : "apply_patch for both creation and edit"
        let planTools = agent == "claude" ? "TaskCreate/TaskUpdate or TodoWrite" : "update_plan"
        let prompt = """
        Run this small reader integration probe. Do not inspect other files or use subagents.
        If checklist tools (\(planTools)) are already available, record one in-progress step titled '\(planText)' and complete it after the probe. Do not change configuration to expose tools. Otherwise finish without a checklist.
        Run two separate shell calls: first printf '\(stdout)\\n'; second sh -c 'printf "\(stderr)\\n" >&2; exit 7'. The exit 7 is intentional; continue afterwards without retrying it.
        Using \(editTools), create only the new file \(file.path) containing '\(before)' and then edit that content to '\(after)'. Do not create or edit any other file. Do not use shell redirection for these file changes.
        Finish with exactly \(done). If a permission or trust prompt appears, leave it for the user. Do not change permissions.
        """
        let sent = send(prompt)
        let answered = sent && wait(180) { self.reply(done) && self.reader?.composerMode == .ready }
        report("probe completed without answering safety prompts", answered)
        guard answered, let page = reader?.reader?.page else { return }
        let operations = chat.allEntries.compactMap(\.operation)
        let successful = operations.first { ($0.output ?? "").contains(stdout) && $0.state == "completed" }
        report("successful shell retains actual stdout", successful != nil)
        let failed = operations.first { ($0.output ?? "").contains(stderr) && $0.state == "failed" }
        report("intentional shell failure retains output and exit 7", failed?.exitCode == 7,
               "state=\(failed?.state ?? "missing"), exit=\(failed?.exitCode.map(String.init) ?? "unrecorded")")
        let edits = operations.filter { ($0.patch ?? "").contains(before) || ($0.patch ?? "").contains(after) }
        report("successful edit retains historical before and after patch",
               edits.contains { $0.state == "completed" && ($0.patch ?? "").contains(before) && ($0.patch ?? "").contains(after) })
        let contents = try? String(contentsOf: file, encoding: .utf8)
        report("probe-owned file has final content", contents?.trimmingCharacters(in: .whitespacesAndNewlines) == after,
               "Artifact retained at \(file.path)")
        let planCalls = operations.filter { ["TodoWrite", "TaskCreate", "TaskUpdate", "update_plan"].contains($0.name) }
        if planCalls.isEmpty {
            report("SKIP live checklist: provider emitted no checklist call", true,
                   "Tool availability is not inferred from absence. No launch configuration was changed.")
        } else {
            let checklist = chat.allEntries.compactMap(\.checklist).last
            report("confirmed checklist reaches reader model and DOM",
                   checklist?.state == "completed" && checklist?.items.contains { $0.text == planText && $0.status == "completed" } == true &&
                   body().contains(planText), "state=\(checklist?.state ?? "missing")")
        }
        func literal(_ value: String) -> String {
            String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
        }
        let dom = SelfTest.js(page, """
        (() => {
          const success = [...document.querySelectorAll('.parity-entry[data-operation-state="completed"]')].find(e => e.querySelector('[data-full-text]') && [...e.querySelectorAll('[data-full-text]')].some(n => n.dataset.fullText.includes(\(literal(stdout)))));
          const failed = [...document.querySelectorAll('.parity-failure')].find(e => e.textContent.includes(\(literal(stderr))));
          const patch = [...document.querySelectorAll('.parity-patch')].some(e => e.textContent.includes(\(literal(before))) && e.textContent.includes(\(literal(after))));
          if (!success) return { output: false, failure: !!failed, patch };
          const detail = success.querySelector('details'); const summary = detail?.querySelector('summary');
          if (!detail || !summary) return { output: true, failure: !!failed, patch, disclosure: false };
          success.closest('.toolgroup')?.classList.add('open');
          detail.open = false; summary.focus(); const focusable = document.activeElement === summary;
          summary.click(); const opens = detail.open; summary.click(); const closes = !detail.open;
          document.dispatchEvent(new KeyboardEvent('keydown', { key: 'f', metaKey: true, bubbles: true }));
          const input = document.querySelector('.reader-find input');
          if (input) { input.value = \(literal(stdout)); input.dispatchEvent(new Event('input', { bubbles: true })); }
          for (let i = 0; i < 50 && !success.classList.contains('reader-search-hit'); i++) document.dispatchEvent(new KeyboardEvent('keydown', { key: 'g', metaKey: true, bubbles: true }));
          const found = success.classList.contains('reader-search-hit') && detail.open && !document.querySelector('.reader-find').hidden;
          document.dispatchEvent(new KeyboardEvent('keydown', { key: 'g', metaKey: true, bubbles: true }));
          document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
          const restored = document.querySelector('.reader-find').hidden && !detail.open;
          return { output: true, failure: !!failed && failed.textContent.includes('Exit 7'), patch, disclosure: focusable && opens && closes, found, restored };
        })()
        """) as? [String: Any] ?? [:]
        report("real operation output, failure and historical patch render", dom["output"] as? Bool == true && dom["failure"] as? Bool == true && dom["patch"] as? Bool == true)
        report("native summary receives focus and toggles disclosure", dom["disclosure"] as? Bool == true)
        report("find keyboard handlers reveal hidden real output and Esc restores disclosure", dom["found"] as? Bool == true && dom["restored"] as? Bool == true)
        report("SKIP live approval/question response: manual interaction required", true,
               "This harness never answers a safety prompt. Provider request fixtures cover correlation and one-shot responses separately.")
    }

    /// A live session exercises metadata against its actual transcript. Model calls are
    /// limited to one short reply; archive and restore never send text to the provider.
    func sidebar() {
        guard let app = model, let chat else { return }
        let priorTerminal = chat.terminal
        let priorPID = SessionHelper.info(chat.id)?.child
        app.prepareChat(chat, resuming: true)
        let reconnected = SelfTest.waitUntil(30) {
            guard let terminal = chat.terminal, terminal !== priorTerminal, let host = self.host else { return false }
            if terminal.superview !== host {
                priorTerminal?.removeFromSuperview()
                terminal.frame = host.bounds
                host.addSubview(terminal, positioned: .below, relativeTo: self.reader?.root)
                self.layout()
            }
            return SessionHelper.info(chat.id)?.child == priorPID && SessionHelper.info(chat.id)?.attached == true
        }
        report("retry reattaches the same owned process", reconnected && priorPID != nil)
        guard reconnected else { return }
        let token = "sidebar" + UUID().uuidString.prefix(8).lowercased()
        let sent = send("Without tools, reply only \(token).")
        let answered = sent && wait(120) { self.reply(token) && self.reader?.composerMode == .ready && !TerminalScreen.analyze(self.screen).busy }
        report("provider reply available for history search", answered)
        guard answered, let session = chat.sessionID, let path = chat.transcriptPath else { return }
        if agent == "codex" {
            report("configured terminal title resolves the native Codex identity", chat.codexTitleIdentity.hint?.matches(session) == true && !chat.codexTitleIdentity.waiting)
        }
        app.renameChat(chat, to: "Saved sidebar check")
        chat.terminalTitle = "Changed provider suggestion"
        report("manual name survives provider title update", chat.displayTitle == "Saved sidebar check")
        let record = ChatHistoryRecord(localChatID: chat.id, agentID: agent, sessionID: session,
                                       title: chat.displayTitle, cwd: folder.path, transcriptPath: path)
        var result: ChatHistoryResult?
        DispatchQueue.global(qos: .userInitiated).async {
            let found = ChatHistoryIndex().search(records: [record], query: token, scope: .all,
                                                  location: .folder, folder: self.folder.path,
                                                  includeNative: false, fullText: true)
            DispatchQueue.main.async { result = found }
        }
        let searched = SelfTest.waitUntil(10) { result != nil }
        report("history matches exact provider identity and message", searched && result?.hits.count == 1 && result?.hits.first?.record.sessionID == session && result?.hits.first?.matchedMessageID != nil)
        center?.setRead(chat: chat, read: false)
        report("manual unread uses same live chat", chat.manualUnread && chat.activity == .doneUnseen)
        center?.setRead(chat: chat, read: true)
        var stopped = false
        app.stopChat(chat) { app.finishArchive(chat); stopped = true }
        let archived = SelfTest.waitUntil(15) { stopped || chat.launchPhase.label?.contains("still running") == true }
        report("archive stops helper and retains transcript identity", archived && stopped && SessionHelper.info(chat.id) == nil && chat.archivedAt != nil && chat.sessionID == session && chat.transcriptPath == path && FileManager.default.fileExists(atPath: path))
        guard stopped else { return }
        app.save()
        let saved = (try? Data(contentsOf: Paths.stateFile)).flatMap(SavedState.read)?.chats.first { $0.id == chat.id }
        report("archive and manual name persist", saved?.archivedAt != nil && saved?.userTitle == "Saved sidebar check")
        app.restoreChat(chat)
        report("restore returns row without launching process", chat.archivedAt == nil && chat.status == .ended && chat.terminal == nil && SessionHelper.info(chat.id) == nil && app.selectedChatID == chat.id)
        app.focusSidebar()
        _ = app.sidebarKey(115)
        _ = app.sidebarKey(119)
        report("sidebar Home and End stay on visible rows", app.visibleSidebarTargets.contains(app.sidebarCursor ?? .pinned))
    }

    /// Opt-in only. Exercises the mounted controller against a disposable provider session.
    /// No picker option, trust dialog, permission request or update prompt is accepted.
    func composerParity() {
        guard let reader, let chat, safe() else { report("mounted composer", false); return }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        guard let controls = descendants(reader.root).compactMap({ $0 as? ComposerAgentControlsView }).first else {
            report("native controls mounted", false); return
        }
        let draft = "Unsent composer draft " + UUID().uuidString
        let selection = NSRange(location: 7, length: 8)
        reader.composer.textView.text = draft
        reader.composer.textView.setSelectedRange(selection)

        for action in [ComposerAgentControlAction.model, .effort, .permissions] {
            guard safe(), reader.composerMode == .ready,
                  let button = descendants(controls).compactMap({ $0 as? NSButton }).first(where: { $0.tag == action.rawValue }),
                  button.isEnabled else { report("\(action.label) available at ready boundary", false); return }
            button.performClick(nil)
            let marker = action == .permissions ? "permission" : action == .effort && agent == "claude" ? "effort" : "model"
            let opened = wait(15, allowingMenu: true) {
                self.mode?.isPeeking(chat) == true && self.screen.lowercased().contains(marker) &&
                    TerminalScreen.analyze(self.screen).menu != nil && !reader.isTyping
            }
            report("\(action.label) opens actual native picker", opened, String(screen.suffix(450)))
            guard opened, safe(allowingMenu: true) else { return }
            report("\(action.label) retains unsent text and caret", reader.composer.textView.string == draft &&
                   reader.composer.textView.selectedRange() == selection)
            dismissPicker()
            let returned = wait(15, allowingMenu: true) {
                TerminalScreen.analyze(self.screen).menu == nil && self.mode?.showsReader(chat) == true &&
                    reader.composerMode == .ready && self.window?.firstResponder === reader.composer.textView
            }
            report("\(action.label) cancellation restores reader focus", returned, String(screen.suffix(450)))
            guard returned else { return }
        }

        // Use an existing checkout candidate without writing into the trusted probe folder.
        if let item = try? ComposerMentionSearch.items(root: folder, query: "").first(where: {
            ($0.relativePath as NSString).lastPathComponent.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        }) {
            let name = (item.relativePath as NSString).lastPathComponent
            reader.composer.textView.text = "Inspect @" + name
            reader.composer.textView.setSelectedRange(NSRange(location: (reader.composer.textView.string as NSString).length, length: 0))
            reader.composer.textView.refreshMentions(force: true)
            let found = wait(8) { reader.composer.textView.mentionSuggestions.contains(where: { $0.relativePath == item.relativePath }) }
            report("@ search resolves an actual checkout path", found)
            guard found, let index = reader.composer.textView.mentionSuggestions.firstIndex(where: { $0.relativePath == item.relativePath }) else { return }
            reader.composer.textView.completeMention(at: index)
            report("@ completion inserts a path without submitting", reader.composer.textView.string.contains(item.insertion.trimmingCharacters(in: .whitespaces)) &&
                   !chat.allEntries.contains(where: { $0.kind == .user && $0.text.contains(item.relativePath) }))
        } else {
            report("SKIP @ live search: trusted folder has no searchable Git candidate", true)
        }
        reader.composer.textView.text = ""

        let missingURL = dir.appendingPathComponent("missing-\(UUID().uuidString).png")
        let missingPrompt = "Unsent missing attachment " + UUID().uuidString
        let priorPermit = reader.permitsSubmit
        var transportAttempted = false
        reader.permitsSubmit = { terminal in transportAttempted = true; return priorPermit(terminal) }
        reader.composer.setAttachments([ComposerAttachment(url: missingURL)])
        let missingAccepted = send(missingPrompt)
        let failedID = chat.pendingMessages.entries.first(where: { $0.text == missingPrompt })?.id
        let retained = missingAccepted && wait(5) {
            guard let failedID else { return false }
            return chat.pendingMessages.stage(id: failedID) == .failed && !reader.isTyping
        }
        reader.permitsSubmit = priorPermit
        let recovery = failedID.flatMap { chat.pendingMessages.recovery(id: $0) }
        report("missing attachment fails before terminal input and retains recovery", retained && !transportAttempted &&
               recovery?.text == missingPrompt && recovery?.attachments.first?.url == missingURL && countUser(missingPrompt) == 0)
        guard retained, !transportAttempted else { return }

        // A small deterministic bitmap is test input, not generated product art.
        let imageURL = dir.appendingPathComponent("composer-\(agent)-fixture.png")
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            report("image fixture allocated", false); return
        }
        for y in 0..<16 { for x in 0..<16 { bitmap.setColor(.systemBlue, atX: x, y: y) } }
        guard let png = bitmap.representation(using: .png, properties: [:]), (try? png.write(to: imageURL)) != nil else {
            report("image fixture written in test output", false); return
        }
        let imageToken = "image" + UUID().uuidString.prefix(8).lowercased()
        let imagePrompt = "Without tools, inspect the attached test image and reply only \(imageToken)."
        reader.composer.setAttachments([ComposerAttachment(url: imageURL)])
        let imageSent = send(imagePrompt)
        let imageSeen = imageSent && wait(120) {
            self.reply(imageToken) && reader.composerMode == .ready &&
                chat.allEntries.contains { $0.kind == .user && $0.text.contains(imageToken) && !$0.images.isEmpty }
        }
        report("image receives native acknowledgement, transcript image and reply", imageSeen,
               "Requires an actual user transcript image, not a path echo. \(String(screen.suffix(450)))")
        guard imageSeen else { return }

        reader.refresh()
        reader.composer.textView.text = draft
        let recallSelection = NSRange(location: 0, length: 0)
        reader.composer.textView.setSelectedRange(recallSelection)
        let usersBeforeRecall = chat.allEntries.filter { $0.kind == .user }.count
        func recallKey(_ code: UInt16, _ character: String) -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                              timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                                              context: nil, characters: character, charactersIgnoringModifiers: character,
                                              isARepeat: false, keyCode: code) else { return false }
            reader.composer.textView.keyDown(with: event)
            return true
        }
        let recalled = recallKey(126, String(UnicodeScalar(NSUpArrowFunctionKey)!))
        report("Up recalls actual latest user prompt", recalled && reader.composer.textView.string == imagePrompt)
        reader.composer.textView.setSelectedRange(NSRange(location: (reader.composer.textView.string as NSString).length, length: 0))
        let returnedDraft = recallKey(125, String(UnicodeScalar(NSDownArrowFunctionKey)!))
        report("Down restores draft and caret without sending", returnedDraft && reader.composer.textView.string == draft &&
               reader.composer.textView.selectedRange() == recallSelection && !reader.isTyping &&
               chat.allEntries.filter { $0.kind == .user }.count == usersBeforeRecall)

        let busyPrompt = "Without tools, count slowly from 1 to 300, one number per line, spelling out each number and its square."
        let queuedPrompt = "Without tools, reply only held" + UUID().uuidString.prefix(8).lowercased() + "."
        let busySent = send(busyPrompt)
        let busy = busySent && wait(45) {
            reader.composerMode.isWorking && TerminalScreen.analyze(self.screen).busy && !reader.isTyping
        }
        report("active turn observed before explicit Queue", busy)
        guard busy else { return }
        reader.composer.textView.text = queuedPrompt
        let queued = reader.send(intent: .queue)
        let queuedID = chat.pendingMessages.entries.first(where: { $0.text == queuedPrompt })?.id
        report("Queue retains message before provider submission", queued && queuedID != nil &&
               queuedID.map { chat.pendingMessages.stage(id: $0) == .waiting } == true && countUser(queuedPrompt) == 0)
        guard queued, let queuedID, reader.composerMode.isWorking else { return }
        reader.composer.textView.text = draft
        reader.composer.textView.setSelectedRange(selection)
        let stopped = reader.stop()
        let settled = stopped && wait(30) { !TerminalScreen.analyze(self.screen).busy && !reader.isTyping }
        report("Stop holds reader queue without sending it", settled && chat.pendingMessages.queuePaused &&
               chat.pendingMessages.stage(id: queuedID) == .waiting && countUser(queuedPrompt) == 0)
        guard settled, chat.pendingMessages.queuePaused, let id = chatID, let previous = SessionHelper.info(id) else { return }
        let quiet = pause(3)
        report("held queue stays unsent after ready boundary", quiet && countUser(queuedPrompt) == 0 &&
               chat.pendingMessages.stage(id: queuedID) == .waiting)
        guard quiet else { return }
        // Text/selection changes have had the debounce window above to persist. sync(nil)
        // hides the reader and stops its timer before destroying the app objects.
        _ = reader.sync(selected: nil)
        model?.save()
        unmount()
        let detached = SelfTest.waitUntil(10) { SessionHelper.info(id)?.attached == false }
        report("composer relaunch detaches owned session", detached)
        guard detached else { return }
        let restored = AppModel()
        restored.agents = discoveredAgents
        model = restored
        restored.load()
        restored.select(id)
        mount()
        let reattached = wait(60) {
            SessionHelper.info(id)?.child == previous.child && SessionHelper.info(id)?.attached == true &&
                self.reader?.composer.textView.string == draft
        }
        report("relaunch restores unsent draft and caret", reattached && self.reader?.composer.textView.selectedRange() == selection)
        guard reattached, let restoredChat = self.chat else { return }
        let stillQuiet = pause(3)
        report("relaunch retains paused queue without replay", stillQuiet && restoredChat.pendingMessages.queuePaused &&
               restoredChat.pendingMessages.stage(id: queuedID) == .waiting && countUser(queuedPrompt) == 0)
        guard stillQuiet, let activeReader = self.reader else { return }
        let planReady = wait(10) { activeReader.composerMode == .ready && !activeReader.isTyping }
        guard planReady, safe(),
              let newControls = descendants(activeReader.root).compactMap({ $0 as? ComposerAgentControlsView }).first,
              let planButton = descendants(newControls).compactMap({ $0 as? NSButton }).first(where: { $0.tag == ComposerAgentControlAction.plan.rawValue }),
              planButton.isEnabled else { report("Plan control available after relaunch", false); return }
        planButton.performClick(nil)
        let enteredPlan = wait(15, allowingMenu: true) {
            guard !activeReader.isTyping else { return false }
            let parsed = newControls.displayedState?.plan
            if parsed?.text == "On", parsed?.evidence == .terminalFooter { return true }
            // Codex's native mode indicator is a footer, not assistant prose or a proposed plan.
            return self.screen.split(whereSeparator: \.isNewline).suffix(4).contains { raw in
                let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
                return line == "plan mode" || line.hasPrefix("plan mode (") || line.hasPrefix("⏸ plan mode on (")
            }
        }
        report("Plan action produces confirmed native mode indicator", enteredPlan, String(screen.suffix(450)))
        report("Plan action preserves draft, caret and paused queue", enteredPlan &&
               activeReader.composer.textView.string == draft && activeReader.composer.textView.selectedRange() == selection &&
               restoredChat.pendingMessages.queuePaused && countUser(queuedPrompt) == 0)
    }

    /// A separate disposable session because compaction and Plan change session state.
    /// Claude /compact accepts summary instructions. Codex /plan explicitly supports pasted
    /// arguments and images. Claude's image case uses /plan's prompt path, not compaction.
    func commandArguments() {
        guard let reader, let chat, safe() else { report("command probe ready", false); return }
        let seedToken = "seed" + UUID().uuidString.prefix(8).lowercased()
        let seeded = send("Without tools, reply only \(seedToken).") && wait(120) {
            self.reply(seedToken) && reader.composerMode == .ready && !reader.isTyping
        }
        report("seed conversation exists before compaction", seeded)
        guard seeded else { return }

        let imageURL = dir.appendingPathComponent("command-arguments-\(agent).png")
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            report("command image fixture allocated", false); return
        }
        for y in 0..<16 { for x in 0..<16 { bitmap.setColor(.systemBlue, atX: x, y: y) } }
        guard let png = bitmap.representation(using: .png, properties: [:]), (try? png.write(to: imageURL)) != nil else {
            report("command image fixture written", false); return
        }
        for attachImage in [false, true] {
            guard safe(), reader.composerMode == .ready else { report("next command ready", false); return }
            let previousIDs = Set(chat.allEntries.map(\.id))
            let transcriptOffset = chat.transcriptPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)).count } ?? 0
            let baselineMarks = ComposerMessage.imageMarks(screen)
            var nativeImageSeen = false
            let previousPermit = reader.permitsSubmit
            reader.permitsSubmit = { terminal in
                if ComposerMessage.imageMarks(terminal.activeScreenText()) > baselineMarks { nativeImageSeen = true }
                return previousPermit(terminal)
            }
            defer { reader.permitsSubmit = previousPermit }
            reader.composer.setAttachments(attachImage ? [ComposerAttachment(url: imageURL)] : [])
            let usesPlan = agent == "codex" || attachImage
            let token = "planned" + UUID().uuidString.prefix(8).lowercased()
            let command = usesPlan
                ? "/plan Do not use tools or change files.\nReply only \(token)."
                : "/compact Preserve the conversation token \(seedToken).\nKeep the summary brief. Do not use tools or change files."
            var currentPlanConfirmed = false
            let accepted = send(command)
            let dispatched = accepted && wait(120) {
                if usesPlan {
                    if self.agent == "codex", let path = chat.transcriptPath,
                       let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)), bytes.count >= transcriptOffset {
                        let records = bytes.split(separator: 10).map { Data($0) }
                        let parsed = ComposerAgentControlsParser.snapshot(provider: .codex, sessionID: chat.sessionID, records: records)
                        let newContext = bytes.dropFirst(transcriptOffset).split(separator: 10).contains { line in
                            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                                  object["type"] as? String == "turn_context",
                                  let payload = object["payload"] as? [String: Any],
                                  let mode = payload["collaboration_mode"] as? [String: Any] else { return false }
                            return mode["mode"] as? String == "plan"
                        }
                        currentPlanConfirmed = currentPlanConfirmed || (newContext && parsed.plan?.text == "On")
                    } else if self.agent == "claude" {
                        let parsed = ComposerAgentControlsParser.snapshot(provider: .claude, sessionID: chat.sessionID, screen: self.screen)
                        currentPlanConfirmed = currentPlanConfirmed || (parsed.plan?.text == "On" && parsed.plan?.evidence == .terminalFooter)
                    }
                    return currentPlanConfirmed && self.reply(token) && !reader.isTyping && !TerminalScreen.analyze(self.screen).busy
                }
                return chat.allEntries.contains { !previousIDs.contains($0.id) && $0.kind == .notice && $0.text == "Conversation compacted" } &&
                    !reader.isTyping && !TerminalScreen.analyze(self.screen).busy
            }
            let suffix = attachImage ? "with image" : "without image"
            report("multiline \(usesPlan ? "/plan" : "/compact") dispatches natively \(suffix)", dispatched,
                   "Requires native mode plus reply, or a new provider compaction event. Assistant agreement alone cannot pass. \(String(screen.suffix(450)))")
            if attachImage { report("native image chip acknowledged before command submission", dispatched && nativeImageSeen) }
            guard dispatched else {
                report("no automatic command retry or confirmation", true,
                       "Unsupported syntax, a confirmation, or missing native state evidence leaves this check failed.")
                return
            }
            if mode?.isPeeking(chat) == true, safe(), TerminalScreen.analyze(screen).menu == nil { reader.backToReader() }
            let ready = wait(15) { reader.composerMode == .ready }
            report("native command returns to ready boundary \(suffix)", ready)
            guard ready else { return }
        }
    }

    func subagents() {
        guard let app = model, let chat, let host else { return }
        let token = "child" + UUID().uuidString.prefix(8).lowercased()
        let taskToken = "task" + UUID().uuidString.prefix(8).lowercased()
        let tool = agent == "claude" ? "Agent tool with model haiku"
            : "available spawn_agent tool (which may be named collaboration.spawn_agent), with fork_turns none and model \(codexModel)"
        let prompt = """
        This is an integration test of subagent navigation. Delegation is explicitly authorized and required even though the task is small. Use the \(tool) to start exactly one child. Do not perform its task yourself or simulate its reply.
        Give the child this exact task: "Task marker \(taskToken). Without file access or command execution, count from 1 to 30, one number per line, then finish with \(token). Use your provider's required final-report tool if it has one."
        Wait for the child to finish using your available agent tools, then reply only done. If no spawn tool is exposed, say that explicitly. Do not inspect files or configuration or change any feature flags.
        """
        let sent = send(prompt)
        let found = sent && wait(120) { app.subagentBrowser.count(for: chat.id) > 0 }
        report("sidebar observes an open subagent", found,
               found ? "open=\(app.subagentBrowser.count(for: chat.id))"
               : "No active row observed. A missing tool is not established by an assistant refusal. For Codex, multi_agent was checked before launch; retry with HANTUU_LIVE_CODEX_MODEL set to an available delegating model. \(String(screen.suffix(450)))")
        guard found, let child = app.subagentBrowser.open[chat.id]?.first else { return }
        let inlineLaunch = wait(10) {
            guard let page = self.reader?.reader?.page else { return false }
            return chat.allEntries.contains { $0.operation?.childID != nil } &&
                (SelfTest.js(page, "[...document.querySelectorAll('.parity-delegated button')].some(b => b.textContent === 'Open agent conversation')") as? Bool) == true
        }
        report("parent reader retains inline child navigation", inlineLaunch)
        app.selectSubagent(child.id, in: chat.id)
        let childReader = SubagentReaderController(model: app)
        self.childReader = childReader
        childReader.install(in: host, top: host.topAnchor)
        childReader.sync()
        var encryptedTask = false
        let promptRendered = wait(120) {
            childReader.sync()
            encryptedTask = self.agent == "codex" && (SelfTest.js(childReader.reader.page,
                "!!document.querySelector('section.entry.notice[data-content-unavailable=\"encrypted-agent-message\"]')") as? Bool) == true
            if encryptedTask { return true }
            return (SelfTest.js(childReader.reader.page,
                                "Array.from(document.querySelectorAll('section.entry.user')).some(e => e.textContent.includes('\(taskToken)'))") as? Bool) == true
        }
        if encryptedTask {
            report("encrypted child task has an explicit unavailable notice", promptRendered)
            report("SKIP child task plaintext: Codex recorded encrypted content", true,
                   "The child transcript and parent spawn record do not provide readable task text. This is not a plaintext rendering pass.")
        } else { report("child task renders in its own reader", promptRendered) }
        let rendered = wait(120) {
            childReader.sync()
            guard let path = app.subagentBrowser.selection?.agent.transcript,
                  FileManager.default.fileExists(atPath: path) else { return false }
            return (SelfTest.js(childReader.reader.page,
                                "Array.from(document.querySelectorAll('section.entry.assistant')).filter(e => e.textContent.includes('\(token)')).length === 1") as? Bool) == true
        }
        report("child transcript is found and renders in its reader", rendered,
               "transcript=\(app.subagentBrowser.selection?.agent.transcript ?? "not found").")
        let retired = wait(60) {
            childReader.sync()
            return app.subagentBrowser.count(for: chat.id) == 0 && app.subagentBrowser.selection?.agent.state.isActive == false
        }
        report("completed child leaves open sidebar list", retired,
               "open=\(app.subagentBrowser.count(for: chat.id)).")
        let parentEvidence = wait(15) {
            chat.allEntries.contains { entry in
                guard let operation = entry.operation else { return false }
                return operation.childID != nil && operation.state == "completed" &&
                    ((operation.report ?? "").contains(token) || (operation.output ?? "").contains(token))
            }
        }
        report("parent inline child card retains completion and report", parentEvidence)
        report("finished child keeps its final answer visible", rendered && retired && !childReader.root.isHidden &&
               (SelfTest.js(childReader.reader.page,
                            "Array.from(document.querySelectorAll('section.entry.assistant')).filter(e => e.textContent.includes('\(token)')).length === 1") as? Bool) == true)
        _ = app.backFromSubagent()
        childReader.sync()
        report("back returns to parent without closing it", childReader.root.isHidden &&
               app.subagentBrowser.selection == nil && app.selectedChatID == chat.id && chat.terminal?.processExited == false)
    }
}
