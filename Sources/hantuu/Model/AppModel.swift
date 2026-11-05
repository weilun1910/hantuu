import AppKit
import Combine

struct Project: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var expanded = true
    var name: String { (path as NSString).lastPathComponent }
}

enum ChatStatus: String, Codable {
    case running, needsYou, ended
}

enum PanelTab: String, Codable, CaseIterable {
    case overview = "Overview", changes = "Changes", files = "Files"
    case code = "Code", terminal = "Terminal", reader = "Reader"
}

/// One agent session: a real terminal running the agent's own TUI in a project folder.
final class Chat: ObservableObject, Identifiable {
    let id: UUID
    let projectID: UUID
    let agentID: String
    let createdAt: Date
    @Published var sessionID: String?
    @Published var terminalTitle = ""
    @Published var status: ChatStatus = .running
    @Published var exitCode: Int?
    @Published var transcriptPath: String?
    @Published var firstPrompt: String?
    /// What the agent is doing and the grey line under the title. Kept true by StatusCenter.
    @Published var activity: AgentActivity = .idle
    @Published var activityDetail = ""
    @Published var activitySince = Date()
    @Published var lastTurnEndedAt: Date?
    var startedAt = Date()
    var terminal: TerminalView?
    var follower: TranscriptFollower?
    /// Entries from an earlier transcript file (Codex resume), shown before the follower's.
    var earlierEntries: [ReaderEntry] = []
    /// "Needs you" notices raised by the terminal (permission prompts, waiting for input).
    var liveEntries: [ReaderEntry] = []
    var discoveryTimer: Timer?
    /// Set when the chat runs in its own git worktree (Sessions/Worktrees.swift).
    @Published var worktree: WorktreeInfo?
    var worktreePath: String? { worktree?.directory }

    init(id: UUID = UUID(), projectID: UUID, agentID: String, createdAt: Date = Date()) {
        self.id = id
        self.projectID = projectID
        self.agentID = agentID
        self.createdAt = createdAt
    }

    var agent: AgentDefinition { AgentCatalog.definition(agentID) }

    /// The terminal title (Claude Code sets one), cleaned of spinner glyphs.
    var displayTitle: String {
        let cleaned = Chat.cleanTitle(terminalTitle)
        if !cleaned.isEmpty, cleaned.lowercased() != agent.name.lowercased(), cleaned != agentID {
            return cleaned
        }
        if let p = firstPrompt, !p.isEmpty { return String(p.prefix(60)) }
        return agent.name
    }

    static func cleanTitle(_ t: String) -> String {
        var s = t.trimmingCharacters(in: .whitespaces)
        while let f = s.unicodeScalars.first, !CharacterSet.alphanumerics.contains(f), !"\"'([".unicodeScalars.contains(f) {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    var allEntries: [ReaderEntry] { earlierEntries + (follower?.entries ?? []) + liveEntries }
}

final class PanelShell: ObservableObject, Identifiable {
    let id = UUID()
    let projectID: UUID
    let terminal: TerminalView
    @Published var title = "Shell"
    init(projectID: UUID, terminal: TerminalView) {
        self.projectID = projectID
        self.terminal = terminal
    }
}

struct CodeTab: Identifiable, Equatable {
    let id = UUID()
    var path: String
    var line: Int?
    var preview = false
    var name: String { (path as NSString).lastPathComponent }
    var isMarkdown: Bool { ["md", "markdown", "mdx"].contains((path as NSString).pathExtension.lowercased()) }
}

private struct SavedChat: Codable {
    var id: UUID
    var projectID: UUID
    var agentID: String
    var sessionID: String?
    var title: String
    var firstPrompt: String?
    var transcriptPath: String?
    var createdAt: Date
    var worktree: WorktreeInfo?
}

private struct SavedState: Codable {
    var projects: [Project] = []
    var chats: [SavedChat] = []
    var defaultAgentID = "claude"
    var sidebarVisible = true
    var panelVisible = false
    var panelTab: PanelTab = .reader
    var windowFrame: String?
    var sidebarWidth: Double?
    var panelWidth: Double?
}

enum AppActions {
    static var shared: AppModel { AppModel.shared }
}

final class AppModel: ObservableObject, TerminalEvents {
    static let shared = AppModel()

    @Published var projects: [Project] = []
    @Published var chats: [Chat] = []
    @Published var selectedChatID: UUID?
    @Published var selectedProjectID: UUID?
    @Published var agents: [AgentDefinition] = []
    @Published var agentsLoaded = false
    @Published var defaultAgentID = "claude"
    @Published var sidebarVisible = true
    @Published var panelVisible = false
    @Published var panelTab: PanelTab = .reader
    @Published var shells: [PanelShell] = []
    @Published var selectedShellID: [UUID: UUID] = [:]
    @Published var codeTabs: [CodeTab] = []
    @Published var selectedCodeTabID: UUID?
    let keepAwake = KeepAwake()

    var windowFrame: String?
    var sidebarWidth: Double?
    var panelWidth: Double?

    /// Fired when a chat's terminal is created or destroyed.
    let terminalsChanged = PassthroughSubject<Void, Never>()
    /// New reader entries for a chat.
    let readerAppend = PassthroughSubject<(UUID, [ReaderEntry]), Never>()
    /// The selected chat's transcript was (re)attached; the reader should reload.
    let readerReload = PassthroughSubject<UUID, Never>()
    /// Ask the window to focus something.
    let focusRequest = PassthroughSubject<NSView, Never>()

    private var saveWork: DispatchWorkItem?
    private var bag = Set<AnyCancellable>()

    var selectedChat: Chat? { chats.first { $0.id == selectedChatID } }

    /// The project new things open in: the selected chat's, else the selected project, else the first.
    var currentProject: Project? {
        if let c = selectedChat, let p = projects.first(where: { $0.id == c.projectID }) { return p }
        if let id = selectedProjectID, let p = projects.first(where: { $0.id == id }) { return p }
        return projects.first
    }

    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }
    func chats(in project: Project) -> [Chat] { chats.filter { $0.projectID == project.id } }
    func shells(in projectID: UUID?) -> [PanelShell] { shells.filter { $0.projectID == projectID } }

    // MARK: Startup

    func load() {
        FileRouter.shared.openInCode = { [weak self] path, line in self?.openFile(path, line: line) }
        if let data = try? Data(contentsOf: Paths.stateFile),
           let s = try? JSONDecoder.hantuu.decode(SavedState.self, from: data) {
            projects = s.projects.filter { FileManager.default.fileExists(atPath: $0.path) }
            defaultAgentID = s.defaultAgentID
            sidebarVisible = s.sidebarVisible
            panelVisible = s.panelVisible
            panelTab = s.panelTab
            windowFrame = s.windowFrame
            sidebarWidth = s.sidebarWidth
            panelWidth = s.panelWidth
            // Earlier chats come back as ended, with their transcript, ready to resume.
            for sc in s.chats where projects.contains(where: { $0.id == sc.projectID }) {
                let c = Chat(id: sc.id, projectID: sc.projectID, agentID: sc.agentID, createdAt: sc.createdAt)
                c.sessionID = sc.sessionID
                c.terminalTitle = sc.title
                c.firstPrompt = sc.firstPrompt
                c.status = .ended
                c.transcriptPath = sc.transcriptPath
                c.worktree = sc.worktree
                if let p = sc.transcriptPath, FileManager.default.fileExists(atPath: p), let kind = c.agent.transcript {
                    attachFollower(c, url: URL(fileURLWithPath: p), kind: kind, live: false)
                }
                chats.append(c)
            }
        }
        selectedProjectID = projects.first?.id
        // Agents that kept running in hantuu-session while the app was closed reattach.
        restoreSessions()
        keepAwake.refresh()
        detectAgents()

        // Persist whenever something durable changes.
        Publishers.MergeMany(
            $projects.map { _ in () }.eraseToAnyPublisher(),
            $defaultAgentID.map { _ in () }.eraseToAnyPublisher(),
            $sidebarVisible.map { _ in () }.eraseToAnyPublisher(),
            $panelVisible.map { _ in () }.eraseToAnyPublisher(),
            $panelTab.map { _ in () }.eraseToAnyPublisher(),
            $chats.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(6)
        .sink { [weak self] in self?.scheduleSave() }
        .store(in: &bag)
    }

    func detectAgents() {
        DispatchQueue.global(qos: .userInitiated).async {
            var found = AgentCatalog.detect()
            if found.isEmpty {
                // Fallback if the login shell printed nothing usable.
                let dirs = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.bun/bin", "~/.npm-global/bin"]
                    .map { ($0 as NSString).expandingTildeInPath }
                found = AgentCatalog.known.compactMap { def in
                    for d in dirs where FileManager.default.isExecutableFile(atPath: "\(d)/\(def.id)") {
                        var x = def
                        x.path = "\(d)/\(def.id)"
                        return x
                    }
                    return nil
                }
            }
            DispatchQueue.main.async {
                self.agents = found
                self.agentsLoaded = true
                if !found.contains(where: { $0.id == self.defaultAgentID }), let first = found.first {
                    self.defaultAgentID = first.id
                }
                Log.write("agents: \(found.map { "\($0.id)=\($0.path ?? "")" }.joined(separator: ", "))")
            }
        }
    }

    // MARK: Persistence

    func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func save() {
        var s = SavedState()
        s.projects = projects
        s.chats = chats.map {
            SavedChat(id: $0.id, projectID: $0.projectID, agentID: $0.agentID, sessionID: $0.sessionID,
                      title: $0.terminalTitle, firstPrompt: $0.firstPrompt, transcriptPath: $0.transcriptPath,
                      createdAt: $0.createdAt, worktree: $0.worktree)
        }
        s.defaultAgentID = defaultAgentID
        s.sidebarVisible = sidebarVisible
        s.panelVisible = panelVisible
        s.panelTab = panelTab
        s.windowFrame = windowFrame
        s.sidebarWidth = sidebarWidth
        s.panelWidth = panelWidth
        Paths.ensure(Paths.dataDir)
        if let data = try? JSONEncoder.hantuu.encode(s) {
            try? data.write(to: Paths.stateFile, options: .atomic)
        }
    }

    // MARK: Projects

    func addProjectWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Project"
        panel.message = "Pick a project folder. Agents start in it."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addProject(path: url.path) }
    }

    @discardableResult
    func addProject(path: String) -> Project {
        let std = (path as NSString).standardizingPath
        if let existing = projects.first(where: { $0.path == std }) {
            selectedProjectID = existing.id
            return existing
        }
        let p = Project(path: std)
        projects.append(p)
        selectedProjectID = p.id
        return p
    }

    func removeProject(_ id: UUID) {
        let running = chats.filter { $0.projectID == id && $0.status != .ended }
        if !running.isEmpty {
            let a = NSAlert()
            a.messageText = "Remove this project?"
            a.informativeText = "\(running.count) agent\(running.count == 1 ? " is" : "s are") still running in it. Removing the project stops them. Files on disk aren't touched."
            a.addButton(withTitle: "Remove")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        for c in chats where c.projectID == id { teardown(c) }
        chats.removeAll { $0.projectID == id }
        for s in shells where s.projectID == id { s.terminal.destroy() }
        shells.removeAll { $0.projectID == id }
        projects.removeAll { $0.id == id }
        if selectedChat == nil { selectedChatID = nil }
        if selectedProjectID == id { selectedProjectID = projects.first?.id }
        terminalsChanged.send()
    }

    func toggleExpanded(_ id: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].expanded.toggle()
    }

    // MARK: Chats

    func newChat(agentID: String?, projectID: UUID?) {
        newChat(agentID: agentID, projectID: projectID, worktree: nil)
    }

    /// `worktree` nil follows the project's "In a new worktree" switch.
    func newChat(agentID: String?, projectID: UUID?, worktree: Bool?) {
        let project: Project
        if let id = projectID, let p = self.project(id) {
            project = p
        } else if let p = currentProject {
            project = p
        } else {
            addProjectWithPanel()
            guard let p = currentProject else { return }
            project = p
        }
        let agentID = agentID ?? defaultAgentID
        let def = agents.first(where: { $0.id == agentID }) ?? AgentCatalog.definition(agentID)
        let chat = Chat(projectID: project.id, agentID: def.id)
        // Claude Code gets a known session id so its transcript file is known up front.
        if def.id == "claude" { chat.sessionID = UUID().uuidString.lowercased() }
        let settings = SessionSettings.shared
        if worktree == true || (worktree == nil && settings.usesWorktree(project.id) && settings.isGitRepo(project.id)) {
            // Making the worktree can take a moment in a big repo, so the chat appears once it's ready.
            Worktrees.createAsync(projectPath: project.path, chatID: chat.id) { [weak self] result in
                switch result {
                case .success(let wt):
                    chat.worktree = wt
                    self?.start(chat, def: def, in: project)
                case .failure(let error):
                    WorktreePrompt.showCreateFailed(error, project: project.name)
                }
            }
            return
        }
        start(chat, def: def, in: project)
    }

    private func start(_ chat: Chat, def: AgentDefinition, in project: Project) {
        launch(chat, argv: def.launchArguments(sessionID: chat.sessionID), in: project)
        if let i = projects.firstIndex(where: { $0.id == project.id }) { projects[i].expanded = true }
        chats.append(chat)
        select(chat.id)
    }

    private func launch(_ chat: Chat, argv: [String], in project: Project) {
        guard let g = GhosttyApp.shared else { return }
        let cwd = workingDirectory(of: chat)
        // The agent runs inside hantuu-session, so it outlives the app (Sessions/).
        let cmd = LoginShell.surfaceCommand(argv, session: SessionLaunch(chatID: chat.id, mode: .create(cwd: cwd)))
        Log.write("launch chat=\(chat.id) cwd=\(cwd) cmd=\(cmd)")
        // HANTUU_EVENTS reaches the agent through hantuu-session, which passes on its whole environment.
        let tv = TerminalView(app: g.app, launch: .init(workingDirectory: cwd, command: cmd,
                                                         environment: ["HANTUU_CHAT_ID": chat.id.uuidString]
                                                            .merging(AgentHooks.environment(for: chat.id)) { a, _ in a }),
                              handlesChildExit: true)
        tv.events = self
        chat.terminal = tv
        chat.status = .running
        chat.exitCode = nil
        chat.startedAt = Date()
        terminalsChanged.send()
        beginTranscriptDiscovery(chat, cwd: cwd)
    }

    /// Reconnects a chat to its agent, which kept running in hantuu-session. The session
    /// replays recent output and nudges the agent to redraw.
    func reattach(_ chat: Chat, startedAt: Date? = nil) {
        guard let g = GhosttyApp.shared else { return }
        let cwd = workingDirectory(of: chat)
        let cmd = LoginShell.surfaceCommand([], session: SessionLaunch(chatID: chat.id, mode: .attach))
        Log.write("reattach chat=\(chat.id) cmd=\(cmd)")
        let tv = TerminalView(app: g.app, launch: .init(workingDirectory: cwd, command: cmd,
                                                         environment: ["HANTUU_CHAT_ID": chat.id.uuidString]),
                              handlesChildExit: true)
        tv.events = self
        chat.terminal = tv
        chat.status = .running
        chat.exitCode = nil
        chat.startedAt = startedAt ?? Date()
        terminalsChanged.send()
        // Same agent process, so its transcript keeps growing where it was.
        if let f = chat.follower { f.start() } else { beginTranscriptDiscovery(chat, cwd: cwd) }
    }

    func resume(_ chat: Chat) {
        guard let project = project(chat.projectID) else { return }
        // Only the terminal was lost (the agent is still in its session): reconnect to it.
        if SessionHelper.isAlive(chat.id) {
            chat.terminal?.destroy()
            chat.terminal = nil
            reattach(chat)
            readerReload.send(chat.id)
            select(chat.id)
            return
        }
        if let wt = chat.worktree, !FileManager.default.fileExists(atPath: wt.directory) {
            WorktreePrompt.showMissing(wt)
            return
        }
        let def = chat.agent
        let argv: [String]
        if let sid = chat.sessionID, let r = def.resumeArguments(sessionID: sid) {
            argv = r
        } else {
            argv = def.launchArguments(sessionID: def.id == "claude" ? (chat.sessionID ?? UUID().uuidString.lowercased()) : nil)
        }
        chat.terminal?.destroy()
        chat.terminal = nil
        if def.id == "codex", let f = chat.follower {
            // Codex may continue in a new rollout file; keep what we already have.
            chat.earlierEntries += f.entries
            f.stop()
            chat.follower = nil
        }
        launch(chat, argv: argv, in: project)
        readerReload.send(chat.id)
        select(chat.id)
    }

    func select(_ id: UUID?) {
        selectedChatID = id
        if let c = selectedChat {
            selectedProjectID = c.projectID
            if c.status == .needsYou, NSApp.isActive { c.status = .running }
            if let t = c.terminal { focusRequest.send(t) }
        }
    }

    func selectChat(index: Int) {
        // Cmd-1...9 follow the sidebar order: projects top to bottom, chats within each.
        let ordered = projects.flatMap { p in chats.filter { $0.projectID == p.id } }
        guard index >= 0, index < ordered.count else { return }
        select(ordered[index].id)
    }

    func closeChat(_ chat: Chat) {
        let running = chat.status != .ended && chat.terminal.map { !$0.processExited } == true
        var choice = WorktreePrompt.CloseChoice.keepWorktree
        if let wt = chat.worktree {
            choice = WorktreePrompt.confirmClose(agentName: chat.agent.name, worktree: wt, running: running)
            if choice == .cancel { return }
        } else if running {
            let a = NSAlert()
            a.messageText = "Close this chat?"
            a.informativeText = "\(chat.agent.name) is still running. Closing the chat stops it. The transcript stays on disk."
            a.addButton(withTitle: "Close")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        let ordered = projects.flatMap { p in chats.filter { $0.projectID == p.id } }
        let idx = ordered.firstIndex(where: { $0.id == chat.id })
        if case .deleteWorktree(let force) = choice, let wt = chat.worktree {
            // Once the agent has stopped, so nothing is still writing into the worktree.
            teardown(chat) { WorktreePrompt.report(Worktrees.remove(wt, force: force), wt) }
        } else {
            teardown(chat)
        }
        chats.removeAll { $0.id == chat.id }
        if selectedChatID == chat.id {
            let rest = projects.flatMap { p in chats.filter { $0.projectID == p.id } }
            if let idx, !rest.isEmpty { select(rest[min(idx, rest.count - 1)].id) } else { selectedChatID = nil }
        }
        terminalsChanged.send()
    }

    private func teardown(_ chat: Chat, then: (() -> Void)? = nil) {
        chat.discoveryTimer?.invalidate()
        chat.follower?.stop()
        chat.terminal?.destroy()
        chat.terminal = nil
        // The agent lives in its session rather than in the terminal, so stop it there.
        SessionHelper.kill(chat.id, then: then)
    }

    /// Cmd-W: the focused panel tab if a panel terminal or the code viewer has focus,
    /// otherwise the selected chat.
    func closeFocused(responder: NSResponder?) {
        if let tv = responder as? TerminalView, let shell = shells.first(where: { $0.terminal === tv }) {
            closeShell(shell)
            return
        }
        if panelVisible, panelTab == .code, let v = responder as? NSView, v.hantuuIsInCodeViewer, let id = selectedCodeTabID {
            closeCodeTab(id)
            return
        }
        if let c = selectedChat { closeChat(c) }
    }

    // MARK: Transcripts

    private func beginTranscriptDiscovery(_ chat: Chat, cwd: String) {
        guard let kind = chat.agent.transcript else { return }
        chat.discoveryTimer?.invalidate()
        // Claude Code's resume appends to the same file. A chat restored from disk only read it
        // once, so start following it now.
        if let f = chat.follower, kind == .claude { f.start(); return }
        let started = chat.startedAt
        let tick = { [weak self, weak chat] in
            guard let self, let chat else { return }
            if chat.follower != nil { chat.discoveryTimer?.invalidate(); return }
            var url: URL?
            switch kind {
            case .claude:
                if let sid = chat.sessionID { url = ClaudeTranscriptParser.locate(sessionID: sid, cwd: cwd) }
            case .codex:
                let claimed = Set(self.chats.compactMap { $0.transcriptPath })
                if let (u, meta) = CodexTranscriptParser.locate(cwd: cwd, after: started, excluding: claimed) {
                    url = u
                    chat.sessionID = meta.id
                }
            }
            if let url {
                chat.discoveryTimer?.invalidate()
                chat.transcriptPath = url.path
                self.attachFollower(chat, url: url, kind: kind, live: true)
                self.readerReload.send(chat.id)
                self.scheduleSave()
                Log.write("transcript chat=\(chat.id) path=\(url.path)")
            }
        }
        chat.discoveryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in tick() }
        tick()
    }

    private func attachFollower(_ chat: Chat, url: URL, kind: TranscriptKind, live: Bool) {
        let base = workingDirectory(of: chat)
        let f = TranscriptFollower(url: url, kind: kind, baseDir: base)
        f.onAppend = { [weak self, weak chat] fresh in
            guard let self, let chat else { return }
            if chat.firstPrompt == nil, let p = fresh.first(where: { $0.kind == .user })?.text {
                chat.firstPrompt = p.split(whereSeparator: \.isNewline).first.map(String.init)
            }
            self.readerAppend.send((chat.id, fresh))
        }
        chat.follower = f
        if live { f.start() } else { f.poll() }
    }

    // MARK: Panel shells

    func newTerminalTab() {
        guard let g = GhosttyApp.shared, let project = currentProject else { return }
        let tv = TerminalView(app: g.app, launch: .init(workingDirectory: project.path), handlesChildExit: false)
        let shell = PanelShell(projectID: project.id, terminal: tv)
        tv.events = self
        shells.append(shell)
        selectedShellID[project.id] = shell.id
        panelTab = .terminal
        panelVisible = true
        focusRequest.send(tv)
    }

    func closeShell(_ shell: PanelShell) {
        shell.terminal.destroy()
        let siblings = shells.filter { $0.projectID == shell.projectID }
        let idx = siblings.firstIndex(where: { $0.id == shell.id }) ?? 0
        shells.removeAll { $0.id == shell.id }
        let rest = shells.filter { $0.projectID == shell.projectID }
        if selectedShellID[shell.projectID] == shell.id {
            selectedShellID[shell.projectID] = rest.isEmpty ? nil : rest[min(idx, rest.count - 1)].id
        }
    }

    // MARK: Code viewer

    func openFileWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        if let p = currentProject { panel.directoryURL = URL(fileURLWithPath: p.path) }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openFile(url.path, line: nil) }
    }

    func openFile(_ path: String, line: Int?) {
        if let i = codeTabs.firstIndex(where: { $0.path == path }) {
            codeTabs[i].line = line
            selectedCodeTabID = codeTabs[i].id
        } else {
            var tab = CodeTab(path: path, line: line)
            tab.preview = tab.isMarkdown
            codeTabs.append(tab)
            selectedCodeTabID = tab.id
        }
        panelTab = .code
        panelVisible = true
    }

    func closeCodeTab(_ id: UUID) {
        guard let i = codeTabs.firstIndex(where: { $0.id == id }) else { return }
        codeTabs.remove(at: i)
        if selectedCodeTabID == id {
            selectedCodeTabID = codeTabs.isEmpty ? nil : codeTabs[min(i, codeTabs.count - 1)].id
        }
    }

    func setPreview(_ id: UUID, _ preview: Bool) {
        guard let i = codeTabs.firstIndex(where: { $0.id == id }) else { return }
        codeTabs[i].preview = preview
    }

    // MARK: TerminalEvents

    private func chat(for view: TerminalView) -> Chat? { chats.first { $0.terminal === view } }

    func terminalTitleDidChange(_ view: TerminalView, title: String) {
        if let c = chat(for: view) {
            c.terminalTitle = title
            objectWillChange.send()
            scheduleSave()
        } else if let s = shells.first(where: { $0.terminal === view }) {
            let t = Chat.cleanTitle(title)
            s.title = t.isEmpty ? "Shell" : t
            objectWillChange.send()
        }
    }

    func terminalNeedsAttention(_ view: TerminalView, reason: String) {
        guard let c = chat(for: view), c.status != .ended else { return }
        if reason.hasPrefix("notification:") {
            let text = String(reason.dropFirst("notification:".count)).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                let entry = ReaderEntry(id: "live-\(UUID().uuidString)", kind: .attention, text: text,
                                        time: ISO8601DateFormatter().string(from: Date()))
                c.liveEntries.append(entry)
                readerAppend.send((c.id, [entry]))
            }
        }
        // The bell and desktop notifications are only a fallback signal now; StatusCenter
        // decides what they mean next to the agent's hooks.
        StatusCenter.shared.terminalAttention(c, reason: reason)
    }

    func terminalChildDidExit(_ view: TerminalView, code: Int) {
        guard let c = chat(for: view) else { return }
        c.status = .ended
        c.exitCode = code
        objectWillChange.send()
        Log.write("chat=\(c.id) exited code=\(code)")
        scheduleSave()
    }

    func terminalRequestedClose(_ view: TerminalView, processAlive: Bool) {
        if let s = shells.first(where: { $0.terminal === view }) {
            closeShell(s)
            return
        }
        if let c = chat(for: view) {
            if processAlive {
                closeChat(c)
            } else if c.status != .ended {
                c.status = .ended
                objectWillChange.send()
            }
        }
    }

    func terminalFocusDidChange(_ view: TerminalView, focused: Bool) {
        if focused, let c = chat(for: view), c.status == .needsYou {
            c.status = .running
            objectWillChange.send()
        }
    }
}

extension NSView {
    /// True if this view sits inside the code viewer's web view.
    var hantuuIsInCodeViewer: Bool {
        var v: NSView? = self
        while let x = v {
            if x.identifier?.rawValue == "hantuu.code" { return true }
            v = x.superview
        }
        return false
    }
}

extension JSONEncoder {
    static var hantuu: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var hantuu: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
