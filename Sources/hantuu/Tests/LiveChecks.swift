import AppKit
import Combine
import GhosttyKit

/// Opt-in checks against installed CLIs. The ordinary self test only exercises the pure
/// parsing and selection rules below. No fixture test launches an agent or reads its home.
enum LiveCheckRules {
    static let agents = ["claude", "codex"]
    static let features = ["slash", "queued", "send-now", "relaunch", "subagents"]

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
    }

    static func liveChecks(_ dir: URL) {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["HANTUU_LIVE"], !raw.isEmpty else { return }
        guard let agents = LiveCheckRules.selection(env["HANTUU_LIVE_AGENTS"], allowed: LiveCheckRules.agents),
              let features = LiveCheckRules.selection(env["HANTUU_LIVE_FEATURES"], allowed: LiveCheckRules.features) else {
            check("live configuration: selectors", false, "Use claude,codex and slash,queued,send-now,relaunch,subagents.")
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
                let probe = LiveCheckSession(agent: agent, feature: feature, folder: folder, dir: dir,
                                             codexModel: env["HANTUU_LIVE_CODEX_MODEL"] ?? "gpt-6-luna")
                defer { probe.finish() }
                guard probe.start() else { continue }
                switch feature {
                case "slash": probe.slash()
                case "queued": probe.queued()
                case "send-now": probe.sendNow()
                case "relaunch": probe.relaunch()
                case "subagents": probe.subagents()
                default: break
                }
            }
        }
    }
}

/// Each feature has its own chat and helper PID. Failure never carries a menu into the
/// next feature. All app data stays in the self test; only CLIs write their own transcripts.
private final class LiveCheckSession {
    let agent: String
    let feature: String
    let folder: URL
    let dir: URL
    let codexModel: String
    private var model: AppModel?
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

    init(agent: String, feature: String, folder: URL, dir: URL, codexModel: String) {
        self.agent = agent
        self.feature = feature
        self.folder = folder
        self.dir = dir
        self.codexModel = codexModel
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
                report("cleared suggestions", false); return
            }
        }
        report("suggestions paged without submitting", !observed.isEmpty && !bounded,
               "Observed \(observed.sorted().joined(separator: ",")); traversal cap reached=\(bounded).")
        guard !observed.isEmpty, !bounded, failure == nil, let chat, let reader else { return }
        // Exercise production discovery separately. Comparing the static table to a live
        // menu cannot account for account skills or feature gates.
        reader.commandDiscoveryEnabled = true
        reader.composer.textView.text = "/"
        reader.composer.textView.setSelectedRange(NSRange(location: 1, length: 0))
        reader.composer.textView.updateCommands()
        reader.composer.textView.onCommandQuery?()
        let discovered = wait(100, allowingMenu: true) { reader.hasObservedCommands && !reader.isDiscoveringCommands }
        report("reader harvests its idle menu and restores input", discovered && CommandMenuScreen.emptyInput(screen, agent: agent),
               String(screen.suffix(450)))
        guard discovered else { return }
        let names = Set(reader.composer.textView.commandCatalog.filter { $0.sigil == "/" && $0.aliasOf == nil }.map(\.name))
        report("TUI commands present in reader", observed.subtracting(names).isEmpty,
               "Missing in reader: \(observed.subtracting(names).sorted().joined(separator: ",")).")
        report("reader commands observed in TUI", names.subtracting(observed).isEmpty,
               "Not observed in TUI: \(names.subtracting(observed).sorted().joined(separator: ",")).")
        reader.composer.textView.text = ""

        let sent = send("/model")
        let peeked = sent && wait(15, allowingMenu: true) {
            self.mode?.isPeeking(chat) == true && TerminalScreen.analyze(self.screen).menu != nil &&
                self.screen.lowercased().contains("model") && CommandMenuScreen.rows(self.screen).isEmpty &&
                CommandMenuScreen.input(self.screen, agent: self.agent) != "/model"
        }
        report("/model opens the real picker and peeks terminal", peeked, String(screen.suffix(450)))
        guard peeked, safe(allowingMenu: true) else { return }
        terminal?.pressEscape()
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
                self.screen.contains(title) && !TerminalScreen.analyze(self.screen).busy
        }
        report("/rename with arguments executes and clears the input", renamed, String(screen.suffix(450)))
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
               "Matching pending entries=\(pending.count).")
        let shown = wait(3) { self.countUser(second, pending: true) == 1 && self.body().contains("Queued") }
        report("reader shows one Queued message", shown, String(body().suffix(450)))
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

    func sendNow() {
        let token = "received" + UUID().uuidString.prefix(8).lowercased()
        let finished = "finished" + UUID().uuidString.prefix(8).lowercased()
        let first = "Without tools, count slowly from 1 to 300, one number per line. Spell out each number and its square on that line. Finish with \(finished)."
        let second = "Stop counting now. Without tools, reply only \(token)."
        guard let chat else { return }
        func completedCount() -> Bool {
            chat.allEntries.contains { $0.kind == .assistant && $0.text.contains(finished) }
        }
        let sent = send(first)
        let busy = sent && wait(45) {
            TerminalScreen.analyze(self.screen).busy && self.reader?.isTyping == false &&
                self.reader?.composerMode.isWorking == true && !completedCount()
        }
        report("count is running before queueing", busy, String(screen.suffix(450)))
        guard busy, let reader, let page = reader.reader?.page else { return }
        let queued = send(second)
        let id = chat.pendingMessages.entries.first(where: { $0.text == second })?.id
        let actionable = queued && wait(8) {
            reader.isTyping == false && !completedCount() &&
                chat.pendingMessages.entries.contains { $0.id == id && $0.sendNowLabel != nil } &&
                (SelfTest.js(page, "document.querySelectorAll('.send-now').length") as? Int ?? 0) > 0
        }
        report("native pending queue and reader Send now action observed", actionable,
               "If the steer was accepted or the count finished before the action, this attempt cannot prove Send now. \(String(screen.suffix(450)))")
        guard actionable, !completedCount(), safe(), let id else { return }
        // Click the real DOM control. Its bridge validates the selected chat and invokes the
        // same controller action used by the keyboard shortcut.
        var accepted = false
        reader.reader?.onSendNow = { [weak reader] chatID, messageID in
            accepted = reader?.sendNow(chatID: chatID, id: messageID) == true
        }
        _ = SelfTest.js(page, "document.querySelector('.send-now').click(); 0")
        let requested = wait(3) { accepted }
        report("Send now requests delivery", requested)
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
        let nextSent = send(second)
        let replied = nextSent && wait(120) { self.reply(afterToken) }
        report("reader follows message and reply after relaunch",
               replied && countUser(first) == 1 && countUser(second) == 1 && reply(beforeToken),
               "first=\(countUser(first)), second=\(countUser(second)); \(String(screen.suffix(450)))")
    }

    func subagents() {
        guard let app = model, let chat, let host else { return }
        let token = "child" + UUID().uuidString.prefix(8).lowercased()
        // Give the child enough output to stay visible across transcript flushes. The
        // explicit delegation instruction overrides a project's default against spawning.
        let task = "Without tools or file access, write every integer from 1 to 200, one per line, without abbreviating. End your answer with \(token)."
        let prompt: String
        if agent == "codex" {
            prompt = "I explicitly authorize exactly one subagent for this live check. Call spawn_agent with task_name=live_probe, fork_turns=none, and message: \(task) Use your inherited model without a model override. Then use wait_agent or list_agents to observe its completion and reply done. Do not do the child's task yourself or substitute a shell command for spawn_agent."
        } else {
            prompt = "I explicitly authorize exactly one subagent for this live check. Use the Agent tool with model haiku and task: \(task) Wait for it, then reply done."
        }
        let sent = send(prompt)
        let found = sent && wait(120) { app.subagentBrowser.count(for: chat.id) > 0 }
        report("sidebar observes an open subagent", found,
               found ? "open=\(app.subagentBrowser.count(for: chat.id))"
               : "No active row observed. For Codex, multi_agent_v2 was explicitly enabled for this process. Model refusal does not establish a missing tool; inspect this probe's rollout tool calls and turn metadata. \(String(screen.suffix(450)))")
        guard found, let child = app.subagentBrowser.open[chat.id]?.first else { return }
        app.selectSubagent(child.id, in: chat.id)
        let childReader = SubagentReaderController(model: app)
        self.childReader = childReader
        childReader.install(in: host, top: host.topAnchor)
        childReader.sync()
        let rendered = wait(120) {
            childReader.sync()
            guard let path = app.subagentBrowser.selection?.agent.transcript,
                  FileManager.default.fileExists(atPath: path) else { return false }
            return (SelfTest.js(childReader.reader.page,
                                "Array.from(document.querySelectorAll('section.entry.assistant')).some(e => e.innerText.includes('\(token)'))") as? Bool) == true
        }
        report("child transcript is found and renders in its reader", rendered,
               "transcript=\(app.subagentBrowser.selection?.agent.transcript ?? "not found").")
        let retired = wait(60) {
            childReader.sync()
            return app.subagentBrowser.count(for: chat.id) == 0 && app.subagentBrowser.selection?.agent.state.isActive == false
        }
        report("completed child leaves open sidebar list", retired,
               "open=\(app.subagentBrowser.count(for: chat.id)).")
    }
}
