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
    case code = "Code", terminal = "Terminal"

    /// The panel used to have a Reader tab. A saved "Reader", or any tab that's gone, opens
    /// Overview, so the rest of the saved state still loads.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PanelTab(rawValue: raw) ?? .overview
    }
}

/// One agent session: a real terminal running the agent's own TUI in a project folder.
final class Chat: ObservableObject, Identifiable {
    let id: UUID
    let projectID: UUID
    let agentID: String
    let createdAt: Date
    @Published var sessionID: String?
    @Published var terminalTitle = ""
    @Published var status: ChatStatus = .running {
        didSet { if status == .ended { pendingMessages.removeAll() } }
    }
    @Published var pendingMessages = PendingReaderMessages()
    @Published var exitCode: Int?
    @Published var transcriptPath: String?
    @Published var firstPrompt: String?
    /// What the agent is doing and the grey line under the title. Kept true by StatusCenter.
    @Published var activity: AgentActivity = .idle
    @Published var activityDetail = ""
    @Published var activitySince = Date()
    @Published var lastTurnEndedAt: Date?
    /// When the chat was pinned to the top of the sidebar. Nil when it isn't pinned.
    @Published var pinnedAt: Date?
    var startedAt = Date()
    var terminal: TerminalView?
    var follower: TranscriptFollower?
    /// Entries from an earlier transcript file (Codex resume), shown before the follower's.
    var earlierEntries: [ReaderEntry] = []
    /// "Needs you" notices raised by the terminal (permission prompts, waiting for input).
    var liveEntries: [ReaderEntry] = []
    var discoveryTimer: Timer?
    var transcriptRecovery: TranscriptRecovery?
    var codexSessionRequest: UUID?
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
    let id: UUID
    let projectID: UUID
    let terminal: TerminalView
    @Published var title = "Shell"
    init(id: UUID = UUID(), projectID: UUID, terminal: TerminalView) {
        self.id = id
        self.projectID = projectID
        self.terminal = terminal
    }
}

/// A tab in the Code panel: any file, in the viewer that suits it (FileViewer/).
struct CodeTab: Identifiable, Equatable {
    var id = UUID()
    var path: String
    var line: Int?
    /// Counts link clicks that asked for a line, so asking for the same line again still
    /// scrolls there, and coming back to the tab doesn't.
    var lineRequest = 0
    /// Markdown, SVG and CSV: the rendered preview rather than the source.
    var preview = false
    var kind: ViewerKind = .text
    /// The editor has changes that aren't saved.
    var dirty = false
    var editorPosition: EditorPosition?
    var name: String { (path as NSString).lastPathComponent }
    var isMarkdown: Bool { kind == .markdown }
}

struct SavedChat: Codable {
    var id: UUID
    var projectID: UUID
    var agentID: String
    var sessionID: String?
    var title: String
    var firstPrompt: String?
    var transcriptPath: String?
    var createdAt: Date
    var worktree: WorktreeInfo?
    var pinnedAt: Date?
}

/// What state.json holds: the sidebar, the chats and the window.
///
/// Reading it never fails as a whole. Every field may be missing, and a project or chat that
/// can't be read is skipped on its own. So a build that adds a field, or drops one, still loads
/// the sidebar an earlier build saved, and never saves an empty one over it. New fields must
/// be optional or have a default here.
struct SavedState: Codable {
    var projects: [Project] = []
    var chats: [SavedChat] = []
    var defaultAgentID = "claude"
    var sidebarVisible = true
    var panelVisible = false
    var panelTab: PanelTab = .overview
    var windowFrame: String?
    var sidebarWidth: Double?
    var panelWidth: Double?
    var pinnedExpanded: Bool?
    var projectPanels: [String: ProjectPanelState]?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
        projects = (get(.projects) as [Lenient<Project>]?)?.compactMap(\.value) ?? []
        chats = (get(.chats) as [Lenient<SavedChat>]?)?.compactMap(\.value) ?? []
        defaultAgentID = get(.defaultAgentID) ?? defaultAgentID
        sidebarVisible = get(.sidebarVisible) ?? sidebarVisible
        panelVisible = get(.panelVisible) ?? panelVisible
        panelTab = get(.panelTab) ?? panelTab
        windowFrame = get(.windowFrame)
        sidebarWidth = get(.sidebarWidth)
        panelWidth = get(.panelWidth)
        projectPanels = (get(.projectPanels) as [String: Lenient<ProjectPanelState>]?)?.compactMapValues(\.value)
        pinnedExpanded = get(.pinnedExpanded)
    }

    /// Nil only when the data isn't a JSON object at all.
    static func read(_ data: Data) -> SavedState? {
        try? JSONDecoder.hantuu.decode(SavedState.self, from: data)
    }
}

/// One element of a saved list: nil when that element can't be read, so the rest still load.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

enum AppActions {
    static var shared: AppModel { AppModel.shared }
}

final class AppModel: ObservableObject, TerminalEvents {
    static let shared = AppModel()

    @Published var projects: [Project] = []
    @Published var chats: [Chat] = []
    @Published var selectedChatID: UUID? {
        didSet {
            if let selection = subagentBrowser.selection, selection.chatID != selectedChatID { subagentBrowser.selection = nil }
            syncProjectPanel()
        }
    }
    @Published var subagentBrowser = SubagentBrowser()
    @Published var selectedProjectID: UUID? { didSet { syncProjectPanel() } }
    @Published var agents: [AgentDefinition] = []
    @Published var agentsLoaded = false
    @Published var defaultAgentID = "claude"
    @Published var sidebarVisible = true
    @Published var panelVisible = false
    @Published var panelTab: PanelTab = .overview { didSet { rememberProjectPanel() } }
    @Published var shells: [PanelShell] = []
    @Published var selectedShellID: [UUID: UUID] = [:] { didSet { rememberProjectPanel() } }
    @Published var codeTabs: [CodeTab] = [] { didSet { rememberProjectPanel() } }
    @Published var pinnedExpanded = true
    @Published var selectedCodeTabID: UUID? { didSet { rememberProjectPanel() } }
    /// The Code tab's controller, for saving and the unsaved-changes prompts.
    weak var fileViewer: FileViewerController?
    weak var panelReview: ReviewCenter?
    private(set) var projectPanels: [UUID: ProjectPanelState] = [:]
    private var projectCodeTabs: [UUID: [CodeTab]] = [:]
    private(set) var panelProjectID: UUID?
    private var switchingPanel = false
    private var capturingPanelSnapshot = false
    /// Tests that construct a model without load() never write application state.
    private var persistenceEnabled = false
    let keepAwake = KeepAwake()

    var windowFrame: String?
    var sidebarWidth: Double?
    var panelWidth: Double?
    /// Projects whose folder was missing at launch, and their chats. Not shown, but written
    /// back on every save, so a folder that's away for a while (an unplugged drive, a renamed
    /// parent) comes back with its chats.
    private var awayProjects: [Project] = []
    private var awayChats: [SavedChat] = []

    /// Fired when a chat's terminal is created or destroyed.
    let terminalsChanged = PassthroughSubject<Void, Never>()
    /// New reader entries for a chat.
    let readerAppend = PassthroughSubject<(UUID, [ReaderEntry]), Never>()
    /// The selected chat's transcript was (re)attached; the reader should reload.
    let readerReload = PassthroughSubject<UUID, Never>()
    /// Ask the window to focus something.
    let focusRequest = PassthroughSubject<NSView, Never>()

    var transcriptLocations = TranscriptLocations()
    var codexProcessID: (UUID) -> Int32? = { SessionHelper.info($0)?.child }
    var codexOpenRollouts: (Int32, URL) -> [URL] = { CodexProcessRollout.paths(rootPID: $0, sessionsRoot: $1) }

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

    /// Pinned chats, from any project, in the order they were pinned.
    var pinnedChats: [Chat] {
        chats.filter { $0.pinnedAt != nil }.sorted { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
    }
    /// A project's chats that aren't pinned. A pinned chat shows in Pinned instead.
    func unpinnedChats(in project: Project) -> [Chat] { chats.filter { $0.projectID == project.id && $0.pinnedAt == nil } }
    /// The sidebar top to bottom: Pinned, then each project's other chats. Cmd-1...9 follow it.
    var sidebarOrder: [Chat] { pinnedChats + projects.flatMap { unpinnedChats(in: $0) } }

    func setPinned(_ chat: Chat, _ pinned: Bool) {
        guard (chat.pinnedAt != nil) != pinned else { return }
        objectWillChange.send()
        chat.pinnedAt = pinned ? Date() : nil
        if pinned { pinnedExpanded = true }
        scheduleSave()
    }

    func togglePinnedExpanded() {
        pinnedExpanded.toggle()
        scheduleSave()
    }
    func shells(in projectID: UUID?) -> [PanelShell] { shells.filter { $0.projectID == projectID } }

    // MARK: Startup

    func load() {
        FileRouter.shared.openInCode = { [weak self] path, line in self?.openFile(path, line: line) }
        if let data = try? Data(contentsOf: Paths.stateFile), let s = Self.readState(data) {
            restoreProjectList(s)
            if !awayProjects.isEmpty { Log.write("state: kept \(awayProjects.count) project(s) whose folder is missing: \(awayProjects.map(\.path))") }
            defaultAgentID = s.defaultAgentID
            pinnedExpanded = s.pinnedExpanded ?? true
            sidebarVisible = s.sidebarVisible
            panelVisible = s.panelVisible
            restoreProjectPanels(s)
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
                c.pinnedAt = sc.pinnedAt
                if let p = sc.transcriptPath, FileManager.default.fileExists(atPath: p), let kind = c.agent.transcript {
                    attachFollower(c, url: URL(fileURLWithPath: p), kind: kind, live: false)
                } else if c.sessionID != nil {
                    beginTranscriptDiscovery(c, cwd: workingDirectory(of: c), replayEvents: true)
                }
                chats.append(c)
            }
        }
        selectedProjectID = projects.first?.id
        restorePanelShells()
        persistenceEnabled = true
        // Agents that kept running in hantuu-session while the app was closed reattach.
        restoreSessions()
        // Reads the Keep awake switch, and turns sleep back on if an earlier hantuu left it off.
        keepAwake.start()
        // While any agent works, the Mac doesn't idle-sleep (lid open). No switch needed.
        keepAwake.watchAgents { [weak self] in self?.chats.contains { $0.activity == .working || $0.activity == .background } ?? false }
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

    /// Reads state.json for launch. Keeps a copy of a file that reads, as state.previous.json,
    /// so an update that gets the sidebar wrong can be undone. A file that doesn't read at all
    /// is moved aside rather than left for the next save to overwrite with an empty sidebar.
    static func readState(_ data: Data, dir: URL = Paths.dataDir) -> SavedState? {
        let fm = FileManager.default
        let file = dir.appendingPathComponent("state.json")
        if let s = SavedState.read(data) {
            let backup = dir.appendingPathComponent("state.previous.json")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: file, to: backup)
            return s
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = dir.appendingPathComponent("state.unreadable-\(stamp).json")
        try? fm.moveItem(at: file, to: aside)
        Log.write("state: state.json couldn't be read, so it was moved to \(aside.lastPathComponent) and hantuu started empty")
        return nil
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
        guard persistenceEnabled, !capturingPanelSnapshot else { return }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func save() {
        var s = SavedState()
        let away = awayProjects.filter { a in !projects.contains { $0.id == a.id || $0.path == a.path } }
        s.projects = projects + away
        s.chats = chats.map {
            SavedChat(id: $0.id, projectID: $0.projectID, agentID: $0.agentID, sessionID: $0.sessionID,
                      title: $0.terminalTitle, firstPrompt: $0.firstPrompt, transcriptPath: $0.transcriptPath,
                      createdAt: $0.createdAt, worktree: $0.worktree, pinnedAt: $0.pinnedAt)
        } + awayChats.filter { sc in away.contains { $0.id == sc.projectID } }
        s.defaultAgentID = defaultAgentID
        s.pinnedExpanded = pinnedExpanded
        s.sidebarVisible = sidebarVisible
        s.panelVisible = panelVisible
        s.panelTab = panelTab
        s.projectPanels = savedProjectPanels()
        s.windowFrame = windowFrame
        s.sidebarWidth = sidebarWidth
        s.panelWidth = panelWidth
        Paths.ensure(Paths.dataDir)
        if let data = try? JSONEncoder.hantuu.encode(s) {
            try? data.write(to: Paths.stateFile, options: .atomic)
        }
    }

    // MARK: Project panels

    var allCodeTabs: [CodeTab] {
        projectCodeTabs.filter { $0.key != panelProjectID }.values.flatMap { $0 } + codeTabs
    }

    /// Runs synchronously after selection changes, before a panel can render the new chat.
    func syncProjectPanel() {
        guard !switchingPanel else { return }
        let id = currentProject?.id
        if id != panelProjectID {
            rememberProjectPanel()
            switchingPanel = true
            panelProjectID = id
            let saved = id.flatMap { projectPanels[$0] } ?? ProjectPanelState()
            panelTab = saved.tab ?? .overview
            codeTabs = id.flatMap { projectCodeTabs[$0] } ?? []
            selectedCodeTabID = codeTabs.contains { $0.id == saved.selectedCodeTabID }
                ? saved.selectedCodeTabID : codeTabs.first?.id
            switchingPanel = false
            fileViewer?.projectDidChange()
        }
        panelReview?.retarget()
    }

    private func rememberProjectPanel() {
        guard !switchingPanel, let id = panelProjectID,
              projects.contains(where: { $0.id == id }) || awayProjects.contains(where: { $0.id == id }) else { return }
        projectCodeTabs[id] = codeTabs
        var state = projectPanels[id] ?? ProjectPanelState()
        state.tab = panelTab
        state.codeTabs = codeTabs.map(SavedCodeTab.init)
        state.selectedCodeTabID = selectedCodeTabID
        state.selectedShellID = selectedShellID[id]
        projectPanels[id] = state
        scheduleSave()
    }

    func folderPanelState(project: UUID, folder: String) -> FolderPanelState {
        projectPanels[project]?.folders?[folder] ?? FolderPanelState()
    }

    func setFolderPanelState(_ state: FolderPanelState, project: UUID, folder: String) {
        guard projects.contains(where: { $0.id == project }) || awayProjects.contains(where: { $0.id == project }) else { return }
        var panel = projectPanels[project] ?? ProjectPanelState()
        if panel.folders == nil { panel.folders = [:] }
        panel.folders?[folder] = state
        projectPanels[project] = panel
        scheduleSave()
    }

    func overviewPanelState(project: UUID) -> OverviewPanelState {
        projectPanels[project]?.overview ?? OverviewPanelState()
    }

    func setOverviewPanelState(_ overview: OverviewPanelState, project: UUID) {
        guard projects.contains(where: { $0.id == project }) else { return }
        objectWillChange.send()
        var state = projectPanels[project] ?? ProjectPanelState()
        state.overview = overview
        projectPanels[project] = state
        scheduleSave()
    }

    func overviewScroll(project: UUID) -> Double { projectPanels[project]?.overviewScroll ?? 0 }
    func setOverviewScroll(_ value: Double, project: UUID) {
        guard projects.contains(where: { $0.id == project }) else { return }
        var state = projectPanels[project] ?? ProjectPanelState()
        state.overviewScroll = value
        projectPanels[project] = state
        scheduleSave()
    }

    func restoreProjectList(_ saved: SavedState) {
        let here = saved.projects.filter { FileManager.default.fileExists(atPath: $0.path) }
        projects = here
        awayProjects = saved.projects.filter { p in !here.contains { $0.id == p.id } }
        awayChats = saved.chats.filter { sc in awayProjects.contains { $0.id == sc.projectID } }
    }

    func restoreProjectPanels(_ saved: SavedState) {
        switchingPanel = true
        projectPanels = [:]
        projectCodeTabs = [:]
        selectedShellID = [:]
        var seen = Set<UUID>()
        for (key, state) in saved.projectPanels ?? [:] {
            guard let id = UUID(uuidString: key) else { continue }
            projectPanels[id] = state
            selectedShellID[id] = state.selectedShellID
            projectCodeTabs[id] = (state.codeTabs ?? []).filter { seen.insert($0.id).inserted }.map(\.restored)
        }
        // An old file had one tab for the whole window. Apply it only to the first project.
        if saved.projectPanels == nil, let id = projects.first?.id {
            var state = ProjectPanelState()
            state.tab = saved.panelTab
            projectPanels[id] = state
        }
        panelProjectID = nil
        switchingPanel = false
        pruneProjectPanels()
        syncProjectPanel()
    }

    func pruneProjectPanels() {
        let keep = Set((projects + awayProjects).map(\.id))
        panelReview?.prunePanelCache(projects: keep)
        projectPanels = projectPanels.filter { keep.contains($0.key) }
        projectCodeTabs = projectCodeTabs.filter { keep.contains($0.key) }
        let retainedShells = selectedShellID.filter { keep.contains($0.key) }
        if retainedShells != selectedShellID { selectedShellID = retainedShells }
    }

    func savedProjectPanels() -> [String: ProjectPanelState] {
        capturingPanelSnapshot = true
        defer { capturingPanelSnapshot = false }
        rememberProjectPanel()
        panelReview?.rememberPanelState()
        pruneProjectPanels()
        for p in projects {
            var state = projectPanels[p.id] ?? ProjectPanelState()
            state.shells = shells(in: p.id).map { SavedPanelShell(id: $0.id, title: $0.title) }
            state.selectedShellID = selectedShellID[p.id]
            projectPanels[p.id] = state
        }
        return Dictionary(uniqueKeysWithValues: projectPanels.map { ($0.key.uuidString, $0.value) })
    }

    private func restorePanelShells() {
        guard let g = GhosttyApp.shared else { return }
        for project in projects {
            for saved in projectPanels[project.id]?.shells ?? [] {
                let terminal = TerminalView(app: g.app, launch: .init(workingDirectory: project.path), handlesChildExit: false)
                terminal.events = self
                let shell = PanelShell(id: saved.id, projectID: project.id, terminal: terminal)
                shell.title = saved.title
                shells.append(shell)
            }
            selectedShellID[project.id] = projectPanels[project.id]?.selectedShellID
        }
    }

    // MARK: Projects

    func addProjectWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Create Project"
        panel.message = "Pick a folder for the project, or make one with New Folder. Agents start in it."
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
        let unsaved = allCodeTabs.filter { tab in
            projectCodeTabs[id]?.contains(where: { $0.id == tab.id }) == true && tab.dirty
        }
        if !unsaved.isEmpty, let viewer = fileViewer {
            switch viewer.ask(unsaved) {
            case .cancel: return
            case .save: guard viewer.saveAllAndWait(unsaved.map(\.id)) else { return }
            case .discard: break
            }
        }
        for c in chats where c.projectID == id { teardown(c) }
        chats.removeAll { $0.projectID == id }
        for s in shells where s.projectID == id { s.terminal.destroy() }
        shells.removeAll { $0.projectID == id }
        projects.removeAll { $0.id == id }
        if selectedChat == nil { selectedChatID = nil }
        if selectedProjectID == id { selectedProjectID = projects.first?.id }
        pruneProjectPanels()
        syncProjectPanel()
        fileViewer?.render()
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

    // Live checks use this same launch path with an explicit inexpensive model.
    func launch(_ chat: Chat, argv: [String], in project: Project) {
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
        beginTranscriptDiscovery(chat, cwd: cwd, replayEvents: true)
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
        // Both agents append to their existing transcript when resumed by session ID.
        // A later hook can redirect the reader if the agent changes conversations.
        launch(chat, argv: argv, in: project)
        readerReload.send(chat.id)
        select(chat.id)
    }

    func select(_ id: UUID?) {
        if subagentBrowser.selection != nil { subagentBrowser.selection = nil }
        selectedChatID = id
        if let c = selectedChat {
            selectedProjectID = c.projectID
            if c.status == .needsYou, NSApp.isActive { c.status = .running }
            if let t = c.terminal { focusRequest.send(t) }
        }
    }

    func selectChat(index: Int) {
        // Cmd-1...9 follow the sidebar order: Pinned, then projects top to bottom.
        let ordered = sidebarOrder
        guard index >= 0, index < ordered.count else { return }
        select(ordered[index].id)
    }

    /// Whether closing a live chat would cut its agent off mid-task (or its background agents and
    /// tasks), which is the only time Close asks first. An agent sitting at its prompt (idle, done, or a chat that never got a
    /// message) closes quietly: nothing is lost, and Resume brings the conversation back.
    static func closingInterrupts(_ chat: Chat) -> Bool {
        switch chat.activity {
        case .working, .background, .needsPermission, .needsAnswer: return true
        case .doneUnseen, .idle, .ended: return false
        }
    }

    func closeChat(_ chat: Chat) {
        let running = chat.status != .ended && chat.terminal.map { !$0.processExited } == true
        var choice = WorktreePrompt.CloseChoice.keepWorktree
        if let wt = chat.worktree {
            choice = WorktreePrompt.confirmClose(agentName: chat.agent.name, worktree: wt, running: running)
            if choice == .cancel { return }
        } else if running && Self.closingInterrupts(chat) {
            let a = NSAlert()
            a.messageText = "Close this chat?"
            a.informativeText = "\(chat.agent.name) is still running. Closing the chat stops it. The transcript stays on disk."
            a.addButton(withTitle: "Close")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        let ordered = sidebarOrder
        let idx = ordered.firstIndex(where: { $0.id == chat.id })
        if case .deleteWorktree(let force) = choice, let wt = chat.worktree {
            // Once the agent has stopped, so nothing is still writing into the worktree.
            teardown(chat) { WorktreePrompt.report(Worktrees.remove(wt, force: force), wt) }
        } else {
            teardown(chat)
        }
        chats.removeAll { $0.id == chat.id }
        if selectedChatID == chat.id {
            let rest = sidebarOrder
            if let idx, !rest.isEmpty { select(rest[min(idx, rest.count - 1)].id) } else { selectedChatID = nil }
        }
        terminalsChanged.send()
    }

    private func teardown(_ chat: Chat, then: (() -> Void)? = nil) {
        subagentBrowser.forget(chat.id)
        chat.discoveryTimer?.invalidate()
        chat.codexSessionRequest = nil
        chat.transcriptRecovery = nil
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
        if backFromSubagent() { return }
        if let c = selectedChat { closeChat(c) }
    }

    // MARK: Transcripts

    /// Hooks follow the agent's active conversation, including an in-terminal resume or clear.
    func followSession(_ chat: Chat, session: HookLineParser.Session, verifiedCodex: Bool = false) {
        guard let kind = chat.agent.transcript else { return }
        if kind == .codex, !verifiedCodex {
            // A legacy completion event may belong to a child. Resolve its main transcript
            // before touching either the saved identity or the reader's current history.
            if session.id == chat.sessionID, session.path == nil, chat.follower != nil { return }
            let token = UUID()
            chat.codexSessionRequest = token
            let previousID = chat.sessionID
            let previousPath = chat.transcriptPath
            let root = transcriptLocations.codex
            Log.write("transcript signal chat=\(chat.id) candidate=\(session.id ?? "unknown")")
            DispatchQueue.global(qos: .utility).async { [weak self, weak chat] in
                let resolved = TranscriptLookup.validatedCodexSession(session, root: root)
                DispatchQueue.main.async {
                    guard let self, let chat, chat.codexSessionRequest == token,
                          chat.sessionID == previousID, chat.transcriptPath == previousPath else { return }
                    chat.codexSessionRequest = nil
                    guard let resolved else {
                        Log.write("transcript signal chat=\(chat.id) candidate=\(session.id ?? "unknown") result=unresolved-kept-current")
                        return
                    }
                    self.followSession(chat, session: resolved, verifiedCodex: true)
                }
            }
            return
        }
        guard kind != .codex || session.path != nil else { return }
        let changedID = session.id != nil && session.id != chat.sessionID
        let path = session.path ?? (changedID ? nil : chat.transcriptPath)
        guard changedID || path != chat.transcriptPath || chat.follower == nil else { return }
        Log.write("transcript identity chat=\(chat.id) from=\(chat.sessionID ?? "unknown") to=\(session.id ?? chat.sessionID ?? "unknown") path=\(path ?? "pending")")
        chat.discoveryTimer?.invalidate()
        chat.codexSessionRequest = nil
        chat.transcriptRecovery = nil
        chat.follower?.stop()
        chat.follower = nil
        chat.earlierEntries = []
        chat.liveEntries = []
        chat.firstPrompt = nil
        if changedID { chat.pendingMessages.removeAll() }
        if let id = session.id { chat.sessionID = id }
        chat.transcriptPath = path
        if let path {
            attachFollower(chat, url: URL(fileURLWithPath: path), kind: kind, live: chat.status != .ended)
        }
        if chat.status != .ended || path == nil {
            beginTranscriptDiscovery(chat, cwd: workingDirectory(of: chat))
        }
        readerReload.send(chat.id)
        scheduleSave()
    }

    /// Used by fresh launches and reattachments alike. Keep checking after the first match.
    func beginTranscriptDiscovery(_ chat: Chat, cwd: String, replayEvents: Bool = false) {
        guard chat.agent.transcript != nil else { return }
        chat.discoveryTimer?.invalidate()
        chat.codexSessionRequest = nil
        let recovery = TranscriptRecovery(events: AgentHooks.eventsFile(for: chat.id), replay: replayEvents)
        chat.transcriptRecovery = recovery
        if let follower = chat.follower {
            follower.start(follow: chat.status != .ended)
            Log.write("transcript chat=\(chat.id) path=\(follower.url.path) reason=restart")
        }
        if chat.status != .ended {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self, weak chat] _ in
                guard let self, let chat else { return }
                if chat.status == .ended { chat.discoveryTimer?.invalidate(); return }
                self.checkTranscriptRecovery(chat, cwd: cwd)
            }
            RunLoop.main.add(timer, forMode: .common)
            chat.discoveryTimer = timer
        }
        checkTranscriptRecovery(chat, cwd: cwd)
    }

    func checkTranscriptRecovery(_ chat: Chat, cwd: String, now: Date = Date()) {
        guard let kind = chat.agent.transcript, let recovery = chat.transcriptRecovery,
              !recovery.pending else { return }
        let size = chat.follower.flatMap {
            ((try? FileManager.default.attributesOfItem(atPath: $0.url.path))?[.size] as? NSNumber)?.uint64Value
        }
        let following = chat.status == .ended ? chat.follower != nil : chat.follower?.isFollowing == true
        let lookupDue = recovery.policy.shouldLookup(now: now, fileSize: size, hasFollower: following,
                                                      working: chat.activity == .working || chat.activity == .background)
        // Process-owned open files can change on /resume even while the agent is idle.
        let probeProcess = kind == .codex && chat.status != .ended
        guard lookupDue || probeProcess else { return }
        recovery.pending = true
        let request = TranscriptLookup.Request(kind: kind, sessionID: chat.sessionID, path: chat.transcriptPath,
                                               cwd: cwd, startedAt: chat.startedAt,
                                               excluded: Set(chats.filter { $0.id != chat.id }.compactMap { $0.transcriptPath }),
                                               roots: transcriptLocations)
        let processID = codexProcessID
        let openRollouts = codexOpenRollouts
        let chatID = chat.id
        if lookupDue { Log.write("transcript lookup chat=\(chat.id) reason=\(size == nil ? "missing" : "recheck")") }
        recovery.queue.async { [weak self, weak chat] in
            var owned: HookLineParser.Session?
            if probeProcess {
                if recovery.lastProcessLookup.map({ now.timeIntervalSince($0) >= 10 }) ?? true {
                    recovery.lastProcessLookup = now
                    recovery.processID = processID(chatID)
                }
                if let pid = recovery.processID {
                    owned = recovery.processRollouts.select(paths: openRollouts(pid, request.roots.codex),
                                                           currentPath: request.path)
                }
            }
            let result = owned ?? (lookupDue ? TranscriptLookup.find(request, events: recovery.events.read(limit: 256 * 1024)) : nil)
            DispatchQueue.main.async {
                recovery.pending = false
                guard let self, let chat, chat.transcriptRecovery === recovery,
                      chat.sessionID == request.sessionID, chat.transcriptPath == request.path else { return }
                guard let result else {
                    if lookupDue { Log.write("transcript lookup chat=\(chat.id) result=missing") }
                    return
                }
                // Another initial lookup may have claimed this rollout while ours was running.
                if owned == nil, request.sessionID == nil, let path = result.path,
                   self.chats.contains(where: { $0.id != chat.id && $0.transcriptPath == path }) {
                    Log.write("transcript lookup chat=\(chat.id) result=claimed")
                    return
                }
                if result.id != chat.sessionID || result.path != chat.transcriptPath || chat.follower == nil {
                    Log.write("transcript switch chat=\(chat.id) from=\(chat.sessionID ?? "unknown") to=\(result.id ?? "unknown") source=\(owned == nil ? "lookup" : "process")")
                    self.followSession(chat, session: result, verifiedCodex: kind == .codex)
                } else if lookupDue {
                    // Restarting a stopped timer preserves the parser cursor and existing entries.
                    chat.follower?.start(follow: chat.status != .ended)
                    if let path = result.path { Log.write("transcript chat=\(chat.id) path=\(path) reason=recovered") }
                }
            }
        }
    }

    private func attachFollower(_ chat: Chat, url: URL, kind: TranscriptKind, live: Bool) {
        chat.follower?.stop()
        let base = workingDirectory(of: chat)
        let f = TranscriptFollower(url: url, kind: kind, baseDir: base)
        f.onReset = { [weak self, weak chat, weak f] in
            guard let self, let chat, let f, chat.follower === f else { return }
            self.readerReload.send(chat.id)
        }
        f.onAppend = { [weak self, weak chat, weak f] fresh in
            guard let self, let chat, let f, chat.follower === f else { return }
            if chat.firstPrompt == nil, let p = fresh.first(where: { $0.kind == .user })?.text {
                chat.firstPrompt = p.split(whereSeparator: \.isNewline).first.map(String.init)
            }
            self.readerAppend.send((chat.id, chat.pendingMessages.reconcile(fresh)))
        }
        chat.follower = f
        Log.write("transcript chat=\(chat.id) path=\(url.path) reason=attach")
        f.start(follow: live)
    }

    // MARK: Panel shells

    func newTerminalTab() {
        guard let g = GhosttyApp.shared, let project = currentProject else { return }
        let tv = TerminalView(app: g.app, launch: .init(workingDirectory: project.path), handlesChildExit: false)
        let shell = PanelShell(projectID: project.id, terminal: tv)
        tv.events = self
        shells.append(shell)
        selectedShellID[project.id] = shell.id
        scheduleSave()
        panelTab = .terminal
        panelVisible = true
        focusRequest.send(tv)
    }

    func closeShell(_ shell: PanelShell) {
        defer { scheduleSave() }
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

    /// Opens any file in the Code tab, as a tab of its own (or the one it already has), and
    /// shows the panel.
    func openFile(_ path: String, line: Int?) {
        let path = (path as NSString).standardizingPath
        if let i = codeTabs.firstIndex(where: { $0.path == path }) {
            codeTabs[i].line = line
            if line != nil {
                codeTabs[i].lineRequest += 1
                // A line is in the source, so a rendered Markdown file shows its source.
                codeTabs[i].preview = false
            }
            selectedCodeTabID = codeTabs[i].id
        } else {
            var tab = CodeTab(path: path, line: line)
            tab.kind = FileKinds.kind(of: path)
            if line != nil { tab.lineRequest = 1 }
            // Markdown, SVG and CSV open rendered; a link to a line shows the source there.
            tab.preview = tab.kind.hasPreview && line == nil
            codeTabs.append(tab)
            selectedCodeTabID = tab.id
        }
        panelTab = .code
        panelVisible = true
    }

    /// Closes a tab, asking to save first if it has unsaved changes.
    func closeCodeTab(_ id: UUID) {
        guard let tab = codeTabs.first(where: { $0.id == id }) else { return }
        guard let viewer = fileViewer else { return removeCodeTab(id) }
        viewer.confirmClose(tab) { [weak self] in self?.removeCodeTab(id) }
    }

    func removeCodeTab(_ id: UUID) {
        guard let i = codeTabs.firstIndex(where: { $0.id == id }) else {
            guard let pid = projectCodeTabs.first(where: { $0.value.contains { $0.id == id } })?.key else { return }
            projectCodeTabs[pid]?.removeAll { $0.id == id }
            projectPanels[pid]?.codeTabs = projectCodeTabs[pid]?.map(SavedCodeTab.init)
            if projectPanels[pid]?.selectedCodeTabID == id {
                projectPanels[pid]?.selectedCodeTabID = projectCodeTabs[pid]?.first?.id
            }
            fileViewer?.render()
            scheduleSave()
            return
        }
        codeTabs.remove(at: i)
        if selectedCodeTabID == id {
            selectedCodeTabID = codeTabs.isEmpty ? nil : codeTabs[min(i, codeTabs.count - 1)].id
        }
    }

    func setCodeTabDirty(_ id: UUID, _ dirty: Bool) {
        updateCodeTab(id) { $0.dirty = dirty }
    }

    func setEditorPosition(_ id: UUID, _ position: EditorPosition) {
        updateCodeTab(id) { $0.editorPosition = position }
    }

    private func updateCodeTab(_ id: UUID, _ update: (inout CodeTab) -> Void) {
        if let i = codeTabs.firstIndex(where: { $0.id == id }) {
            update(&codeTabs[i])
        } else if let pid = projectCodeTabs.first(where: { $0.value.contains { $0.id == id } })?.key,
                  let i = projectCodeTabs[pid]?.firstIndex(where: { $0.id == id }) {
            update(&projectCodeTabs[pid]![i])
            projectPanels[pid]?.codeTabs = projectCodeTabs[pid]?.map(SavedCodeTab.init)
            scheduleSave()
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

    /// An agent's reminder that it's idle, as opposed to a prompt that's waiting on you.
    static func isIdleNotice(_ text: String) -> Bool {
        text.lowercased().contains("waiting for your input")
    }

    func terminalNeedsAttention(_ view: TerminalView, reason: String) {
        guard let c = chat(for: view), c.status != .ended else { return }
        if reason.hasPrefix("notification:") {
            let text = String(reason.dropFirst("notification:".count)).trimmingCharacters(in: .whitespaces)
            // Claude Code's "waiting for your input" comes a minute after every finished turn,
            // so it isn't a notice worth keeping in the conversation. The status still sees it.
            if !text.isEmpty && !Self.isIdleNotice(text) {
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
