import AppKit
import Combine

/// State behind the Overview, Changes and Files tabs. It follows the selected chat (or the
/// current project when no chat is selected) and only does work while one of those tabs is
/// showing: git runs on a background queue, the folder is watched with FSEvents, and the PR
/// and port lookups run on timers.
final class ReviewCenter: ObservableObject {
    static let shared = ReviewCenter()

    private(set) weak var model: AppModel?
    private(set) var panelProjectID: UUID?
    private var restoringPanel = false
    private var savedRepositories: [String: RepositoryPanelState] = [:]
    var diffScroll: [String: Double] = [:]
    @Published var filesScroll: Double = 0 { didSet { rememberPanelState() } }
    @Published var changesScroll: Double = 0 { didSet { rememberPanelState() } }
    @Published var selectedFilePath: String? { didSet { rememberPanelState() } }
    @Published private(set) var chatID: UUID?
    @Published private(set) var folder: String?
    @Published private(set) var activeTab: PanelTab?

    // Changes
    @Published private(set) var repo: RepoInfo?
    @Published private(set) var repoChecked = false
    @Published var base: DiffBase = .uncommitted { didSet { if !restoringPanel, base != oldValue { baseChanged(); rememberPanelState() } } }
    @Published private(set) var changes: [ChangedFile] = []
    @Published private(set) var uncommitted: [ChangedFile] = []
    @Published private(set) var branchSummary: ChangeSummary?
    @Published private(set) var changesLoaded = false
    @Published var selectedPath: String? { didSet { if !restoringPanel, selectedPath != oldValue { loadDiff(); rememberPanelState() } } }
    @Published private(set) var comments: [String: [ReviewComment]] = [:]
    @Published private(set) var viewed: [String: String] = [:]
    @Published var flash: String?

    // A folder that isn't a repository but holds some. This center scans them all and keeps
    // the comments and viewed marks. Each repository gets a center of its own (parentReview
    // set) for its file list, comparison and diff page, shown as a section in Changes. The
    // diff below the sections is the focused repository's.
    @Published private(set) var repositories: [RepositoryChanges] = []
    @Published private(set) var discoveryTruncated = false
    @Published var expandedRepositories: Set<String> = [] { didSet { rememberPanelState() } }
    @Published var showCleanRepositories = false { didSet { rememberPanelState() } }
    @Published private(set) var focusedRepository: String? { didSet { rememberPanelState() } }
    private(set) var repositoryCenters: [String: ReviewCenter] = [:]
    private weak var parentReview: ReviewCenter?
    /// A repository's center: its part of the parent's last scan.
    private var nestedEntry: RepositoryChanges?
    private let discoveryCache = RepositoryDiscoveryCache()

    var hasRepositories: Bool { repo != nil || !repositories.isEmpty }
    /// What Overview's Changes card counts: the branch, or every nested repository's branch.
    var overviewSummary: ChangeSummary? { repo == nil ? repositories.flatMap(\.branch).summary : branchSummary }

    // Overview
    @Published private(set) var insights: SessionInsights?
    /// The selected chat's subagents and background tasks, with what their own files add.
    @Published private(set) var work = AgentWork()
    @Published private(set) var pr: PullRequestInfo?
    @Published private(set) var ports: [ListeningPort] = []

    // Files
    @Published private(set) var tree: FileTree?
    @Published var filter = "" { didSet { rememberPanelState() } }
    @Published var expanded: Set<String> = [] { didSet { rememberPanelState() } }

    private struct CachedFolder {
        var repo: RepoInfo?
        var repoChecked: Bool
        var changes: [ChangedFile]
        var uncommitted: [ChangedFile]
        var branchSummary: ChangeSummary?
        var changesLoaded: Bool
        var repositories: [RepositoryChanges]
        var discoveryTruncated: Bool
        var centers: [String: ReviewCenter]
        var tree: FileTree?
        var pr: PullRequestInfo?
        var ports: [ListeningPort]
        var page: DiffPage?
        var lastDiffKey: String
    }
    private var cachedFolders: [String: CachedFolder] = [:]
    private var loadedDiffPage: DiffPage?
    /// Made on first use, so a repository section only gets a web view once it's opened.
    var diffPage: DiffPage {
        if let page = loadedDiffPage { return page }
        let page = DiffPage()
        page.center = self
        loadedDiffPage = page
        return page
    }
    /// Fixtures for snapshots and tests: no gh, lsof or timers.
    var fixtureMode = false

    private var queue = DispatchQueue(label: "hantuu.review", qos: .userInitiated)
    private let slowQueue = DispatchQueue(label: "hantuu.review.slow", qos: .utility)
    private var generation = 0
    private var watcher: FolderWatcher?
    private var timers: [Timer] = []
    private var insightsFollower: InsightsFollower?
    private var workTracker = AgentWorkTracker()
    private var forcedLarge: Set<String> = []
    private var lastDiffKey = ""
    private var saveWork: DispatchWorkItem?
    private var bag = Set<AnyCancellable>()

    /// A repository's center keeps nothing of its own: its parent saves for it.
    init(loadSavedState: Bool = true) {
        guard loadSavedState else { return }
        let s = ReviewSavedState.load()
        comments = s.comments
        viewed = s.viewed
    }

    func configure(model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        model.panelReview = self
        bag.removeAll()
        Publishers.Merge3(model.$selectedChatID.map { _ in () }, model.$selectedProjectID.map { _ in () }, model.$chats.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.retarget() }
            .store(in: &bag)
        retarget()
    }

    var selectedChat: Chat? { chatID.flatMap { id in model?.chats.first { $0.id == id } } }

    // MARK: Following the selection

    func retarget() {
        guard let model else { return }
        let chat = model.selectedChat
        let f = chat.map { model.workingDirectory(of: $0) } ?? model.currentProject?.path
        let pid = model.currentProject?.id
        guard chat?.id != chatID || f != folder || pid != panelProjectID else { return }
        let folderChanged = f != folder || pid != panelProjectID
        if folderChanged {
            rememberPanelState()
            parkFolderContent()
        }
        restoringPanel = true
        panelProjectID = pid
        chatID = chat?.id
        folder = f
        generation += 1
        for center in repositoryCenters.values {
            center.generation += 1
            center.chatID = chatID
        }
        insightsFollower = nil
        insights = nil
        workTracker = AgentWorkTracker()
        work = AgentWork()
        if folderChanged {
            flash = nil
            repo = nil
            repositoryCenters = [:]
            repositories = []
            expandedRepositories = []
            focusedRepository = nil
            showCleanRepositories = false
            discoveryTruncated = false
            repoChecked = false
            changes = []
            uncommitted = []
            branchSummary = nil
            changesLoaded = false
            selectedPath = nil
            tree = nil
            pr = nil
            ports = []
            filter = ""
            expanded = []
            lastDiffKey = ""
            stopWatching()
        }
        if folderChanged {
            let state = pid.flatMap { id in f.map { model.folderPanelState(project: id, folder: $0) } } ?? FolderPanelState()
            restorePanelState(state)
            restoreFolderContent()
        }
        restoringPanel = false
        updateActivity(refresh: true)
    }

    private func parkFolderContent() {
        guard folder != nil, panelProjectID != nil else { return }
        cachedFolders[panelContextKey] = CachedFolder(repo: repo, repoChecked: repoChecked,
            changes: changes, uncommitted: uncommitted, branchSummary: branchSummary,
            changesLoaded: changesLoaded, repositories: repositories, discoveryTruncated: discoveryTruncated,
            centers: repositoryCenters, tree: tree, pr: pr, ports: ports, page: loadedDiffPage, lastDiffKey: lastDiffKey)
        loadedDiffPage?.center = nil
        loadedDiffPage = nil
        for center in repositoryCenters.values {
            center.generation += 1
            center.activeTab = nil
            center.parentReview = nil
            center.model = nil
            center.loadedDiffPage?.center = nil
        }
    }

    private func restoreFolderContent() {
        guard let cached = cachedFolders.removeValue(forKey: panelContextKey) else { return }
        repo = cached.repo
        repoChecked = cached.repoChecked
        changes = cached.changes
        uncommitted = cached.uncommitted
        branchSummary = cached.branchSummary
        changesLoaded = cached.changesLoaded
        repositories = cached.repositories
        discoveryTruncated = cached.discoveryTruncated
        repositoryCenters = cached.centers
        tree = cached.tree
        pr = cached.pr
        ports = cached.ports
        loadedDiffPage = cached.page
        loadedDiffPage?.center = self
        lastDiffKey = cached.lastDiffKey
        for center in repositoryCenters.values {
            center.chatID = chatID
            center.model = model
            center.parentReview = self
            center.loadedDiffPage?.center = center
        }
        updateRepositoryTabs()
    }

    func prunePanelCache(projects: Set<UUID>) {
        let prefixes = projects.map { $0.uuidString + "|" }
        for key in Array(cachedFolders.keys) where !prefixes.contains(where: { key.hasPrefix($0) }) {
            guard let cached = cachedFolders.removeValue(forKey: key) else { continue }
            cached.page?.close()
            for center in cached.centers.values { center.loadedDiffPage?.close() }
        }
    }

    /// Includes the project identity even when two projects point at the same folder.
    var panelContextKey: String { "\(panelProjectID?.uuidString ?? "none")|\(folder ?? "")" }

    func rememberPanelState() {
        guard !restoringPanel else { return }
        if let parentReview { parentReview.rememberPanelState(); return }
        guard let model, let id = panelProjectID, let folder else { return }
        var state = FolderPanelState()
        state.base = base
        state.selectedPath = selectedPath
        state.expandedRepositories = expandedRepositories
        state.showCleanRepositories = showCleanRepositories
        state.focusedRepository = focusedRepository
        var nested = savedRepositories
        for (key, center) in repositoryCenters {
            nested[key] = RepositoryPanelState(base: center.base, selectedPath: center.selectedPath, diffScroll: center.diffScroll)
        }
        state.repositories = nested
        state.filter = filter
        state.expanded = expanded
        state.selectedFile = selectedFilePath
        state.filesScroll = filesScroll
        state.changesScroll = changesScroll
        state.diffScroll = diffScroll
        model.setFolderPanelState(state, project: id, folder: folder)
    }

    private func restorePanelState(_ state: FolderPanelState) {
        base = state.base ?? .uncommitted
        selectedPath = state.selectedPath
        expandedRepositories = state.expandedRepositories ?? []
        showCleanRepositories = state.showCleanRepositories ?? false
        focusedRepository = state.focusedRepository
        savedRepositories = state.repositories ?? [:]
        filter = state.filter ?? ""
        expanded = state.expanded ?? []
        selectedFilePath = state.selectedFile
        filesScroll = state.filesScroll ?? 0
        changesScroll = state.changesScroll ?? 0
        diffScroll = state.diffScroll ?? [:]
    }

    func recordDiffScroll(key: String, top: Double) {
        diffScroll[key] = top
        rememberPanelState()
    }

    /// Called by the panel whenever it syncs: which tab shows, if any.
    func setActiveTab(_ tab: PanelTab?) {
        let t: PanelTab? = [.overview, .changes, .files].contains(tab) ? tab : nil
        guard t != activeTab else { return }
        activeTab = t
        updateRepositoryTabs()
        updateActivity(refresh: true)
    }

    private func updateActivity(refresh: Bool) {
        timers.forEach { $0.invalidate() }
        timers = []
        guard let tab = activeTab, folder != nil else {
            stopWatching()
            return
        }
        startWatching()
        if refresh {
            refreshGit()
            if tab == .files { refreshTree() }
            if tab == .overview { refreshInsights(); refreshPullRequest(); refreshPorts() }
            if tab == .changes { loadDiff() }
        }
        guard !fixtureMode, tab == .overview else { return }
        timers.append(timer(2) { [weak self] in self?.refreshInsights() })
        timers.append(timer(5) { [weak self] in self?.refreshPorts() })
        timers.append(timer(60) { [weak self] in self?.refreshPullRequest() })
    }

    private func timer(_ interval: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { _ in block() }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private func startWatching() {
        guard let target = repo?.root ?? folder else { return }
        if watcher?.path == target { return }
        watcher?.stop()
        let w = FolderWatcher(path: target) { [weak self] in self?.folderDidChange() }
        w.start()
        watcher = w
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    private func folderDidChange() {
        guard activeTab != nil else { return }
        invalidateDiscovery()
        refreshGit()
        if activeTab == .files { refreshTree() }
    }

    private func invalidateDiscovery() {
        guard let folder else { return }
        queue.async { self.discoveryCache.invalidate(folder) }
    }

    func refreshNow() {
        if let parentReview { parentReview.refreshNow(); return }
        invalidateDiscovery()
        updateActivity(refresh: true)
    }

    // MARK: Git

    func refreshGit(completion: (() -> Void)? = nil) {
        if let parentReview { parentReview.refreshGit(completion: completion); return }
        guard let folder else { completion?(); return }
        let gen = generation
        let base = self.base
        let wantBranch = activeTab == .overview || base == .branch
        queue.async {
            let repo = RepoInfo.load(folder: folder)
            var unc: [ChangedFile] = [], list: [ChangedFile] = []
            var summary: ChangeSummary?
            var nested: [RepositoryChanges] = []
            var truncated = false
            if let repo {
                let env = Git.readOnlyIndex(root: repo.root)
                unc = ChangeScanner.uncommitted(repo, env: env)
                var branchList: [ChangedFile]?
                if wantBranch, let mb = repo.mergeBase { branchList = ChangeScanner.branch(repo, base: mb, env: env) }
                list = base == .branch ? (branchList ?? unc) : unc
                summary = (branchList ?? unc).summary
            } else {
                let discovered = self.discoveryCache.result(folder: folder)
                truncated = discovered.truncated
                nested = RepositoryChanges.ordered(discovered.repositories.compactMap(RepositoryChanges.scan))
            }
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                let rootChanged = repo?.root != self.repo?.root
                if repo != self.repo { self.repo = repo }
                self.repoChecked = true
                if unc != self.uncommitted { self.uncommitted = unc }
                if list != self.changes { self.changes = list }
                if wantBranch { self.branchSummary = summary }
                if !nested.isEmpty || !self.repositories.isEmpty { self.applyRepositories(nested) }
                if truncated != self.discoveryTruncated { self.discoveryTruncated = truncated }
                self.changesLoaded = true
                if rootChanged, self.activeTab != nil { self.startWatching() }
                if self.selectedPath == nil || !list.contains(where: { $0.path == self.selectedPath }) {
                    self.selectedPath = list.first?.path
                }
                self.loadDiff()
                completion?()
            }
        }
    }

    /// Hands each repository its part of the scan. Centers of repositories that are still
    /// there are kept, so their selection, comparison and open diff survive a refresh.
    private func applyRepositories(_ entries: [RepositoryChanges]) {
        let ids = Set(entries.map(\.id))
        Set(repositoryCenters.keys).subtracting(ids).forEach(dropRepositoryCenter)
        expandedRepositories.formIntersection(ids)
        for entry in entries {
            let center = repositoryCenters[entry.id] ?? addRepositoryCenter(for: entry)
            center.show(entry)
        }
        if entries != repositories { repositories = entries }
        if focusedRepository.map({ !canFocus($0) }) ?? true { focusedRepository = firstFocusable() }
        updateRepositoryTabs()
    }

    /// Only the focused repository's center is live on the Changes tab: it loads the diff.
    private func updateRepositoryTabs() {
        for (id, center) in repositoryCenters {
            let tab: PanelTab? = activeTab == .changes && id == focusedRepository ? .changes : nil
            guard center.activeTab != tab else { continue }
            center.activeTab = tab
            center.objectWillChange.send()
            center.loadDiff()
        }
    }

    private func canFocus(_ id: String) -> Bool {
        expandedRepositories.contains(id) && repositoryCenters[id]?.changes.isEmpty == false
    }

    private func firstFocusable() -> String? {
        repositories.first { canFocus($0.id) }?.id
    }

    /// A file picked in a repository's section shows its diff below the list.
    func focus(_ id: String) {
        guard repositoryCenters[id] != nil, id != focusedRepository else { return }
        focusedRepository = id
        updateRepositoryTabs()
    }

    /// After a section switches comparison: its diff shows if it has files, and if it was
    /// showing and now has none, the diff moves to the next open section with changes.
    private func repositoryListChanged(_ id: String) {
        if canFocus(id) {
            focus(id)
        } else if focusedRepository == id {
            focusedRepository = firstFocusable()
            updateRepositoryTabs()
        }
    }

    /// Whether this repository's selected file is the one whose diff is showing.
    var showsSelection: Bool {
        guard let parentReview else { return true }
        return parentReview.focusedRepository == repo?.root
    }

    /// Picks a file in the list. In a repository section it also moves the diff to it.
    func select(_ path: String) {
        selectedPath = path
        if let parentReview, let root = repo?.root { parentReview.focus(root) }
    }

    private func addRepositoryCenter(for entry: RepositoryChanges) -> ReviewCenter {
        let center = ReviewCenter(loadSavedState: false)
        center.parentReview = self
        // Diffs go through the same private index copy the scan uses, so they share its queue.
        center.queue = queue
        center.model = model
        center.chatID = chatID
        center.folder = folder
        center.panelProjectID = panelProjectID
        center.restoringPanel = true
        // Open on the comparison that has something to show: a branch whose work is all
        // committed opens on Branch rather than on an empty Uncommitted list.
        center.base = entry.uncommitted.isEmpty && entry.info.mergeBase != nil ? .branch : .uncommitted
        if let saved = savedRepositories[entry.id] {
            center.base = saved.base ?? center.base
            center.selectedPath = saved.selectedPath
            center.diffScroll = saved.diffScroll ?? [:]
        } else if entry.hasChanges { expandedRepositories.insert(entry.id) }
        center.restoringPanel = false
        repositoryCenters[entry.id] = center
        return center
    }

    private func dropRepositoryCenter(_ id: String) {
        guard let center = repositoryCenters.removeValue(forKey: id) else { return }
        savedRepositories[id] = RepositoryPanelState(base: center.base, selectedPath: center.selectedPath, diffScroll: center.diffScroll)
        center.generation += 1
        center.loadedDiffPage?.close()
    }

    /// A repository's center: shows its part of the parent's scan.
    private func show(_ entry: RepositoryChanges) {
        nestedEntry = entry
        if entry.info != repo { repo = entry.info }
        repoChecked = true
        if entry.uncommitted != uncommitted { uncommitted = entry.uncommitted }
        branchSummary = entry.branch.summary
        showNestedList()
    }

    private func showNestedList() {
        guard let entry = nestedEntry else { return }
        let list = base == .branch ? entry.branch : entry.uncommitted
        if list != changes { changes = list }
        changesLoaded = true
        if selectedPath == nil || !list.contains(where: { $0.path == selectedPath }) { selectedPath = list.first?.path }
        loadDiff()
    }

    /// Opening a section shows its diff if nothing else is; closing the one whose diff is
    /// showing moves the diff to the next open section with changes.
    func toggleRepository(_ id: String) {
        if expandedRepositories.contains(id) { expandedRepositories.remove(id) } else { expandedRepositories.insert(id) }
        if focusedRepository.map({ !canFocus($0) }) ?? true {
            focusedRepository = canFocus(id) ? id : firstFocusable()
        }
        updateRepositoryTabs()
    }

    /// Overview's Changes card counts the branch, so Changes opens on Branch to match.
    func showOverviewChanges() {
        if let repo { base = repo.mergeBase != nil ? .branch : .uncommitted }
        for entry in repositories {
            repositoryCenters[entry.id]?.base = entry.info.mergeBase != nil ? .branch : .uncommitted
            if entry.hasChanges { expandedRepositories.insert(entry.id) }
        }
        if focusedRepository.map({ !canFocus($0) }) ?? true { focusedRepository = firstFocusable() }
        updateRepositoryTabs()
        model?.panelTab = .changes
    }

    private func baseChanged() {
        lastDiffKey = ""
        // A repository in a parent folder already has both lists from the last scan.
        if let parentReview {
            showNestedList()
            if let root = repo?.root { parentReview.repositoryListChanged(root) }
            return
        }
        changesLoaded = false
        if activeTab != nil { refreshGit() }
    }

    var baseRef: String? {
        guard let repo else { return nil }
        if base == .branch, let mb = repo.mergeBase { return mb }
        return repo.headRef
    }

    var baseLabel: String {
        if base == .branch, let d = repo?.defaultBranch { return d }
        return "last commit"
    }

    var selectedFile: ChangedFile? { changes.first { $0.path == selectedPath } }

    /// Changed files keyed by their path relative to the working folder, for the Files tab.
    /// In a folder holding several repositories, every repository's changes count.
    var changedInFolder: [String: Character] {
        guard let folder else { return [:] }
        let f = folder.hasSuffix("/") ? folder : folder + "/"
        var out: [String: Character] = [:]
        let sources: [(root: String, files: [ChangedFile])] = repo.map { [($0.root, uncommitted)] }
            ?? repositories.map { ($0.info.root, $0.uncommitted) }
        for (root, files) in sources {
            for c in files {
                let abs = (root as NSString).appendingPathComponent(c.path)
                if abs.hasPrefix(f) { out[String(abs.dropFirst(f.count))] = c.status }
            }
        }
        return out
    }

    // MARK: Diff

    func loadDiff(force: Bool = false) {
        guard activeTab == .changes, let repo, let file = selectedFile, let ref = baseRef else {
            if activeTab == .changes, changesLoaded, selectedFile == nil {
                diffPage.clear(changes.isEmpty ? "" : "Pick a file to see its diff.")
                lastDiffKey = ""
            }
            return
        }
        let gen = generation
        let key = "\(repo.root)|\(base.rawValue)|\(file.path)"
        let allowLarge = force || forcedLarge.contains(key)
        if force { forcedLarge.insert(key) }
        let keepScroll = key == lastDiffKey
        queue.async {
            let text = ChangeScanner.diff(file, base: ref, root: repo.root)
            let tooBig = text.utf8.count > 800_000
            let parsed = tooBig && !allowLarge ? ParsedDiff() : DiffParser.parse(text)
            DispatchQueue.main.async {
                guard gen == self.generation, self.selectedPath == file.path, self.baseRef == ref, self.activeTab == .changes else { return }
                var payload = DiffPayload(key: key, path: file.path, rows: parsed.rows, comments: self.pageComments(for: file.path),
                                          keepScroll: keepScroll)
                if !allowLarge && (tooBig || parsed.rows.count > 4000) {
                    payload.rows = []
                    payload.large = max(parsed.rows.count, text.split(separator: "\n").count)
                } else if parsed.binary {
                    payload.notice = "Binary file, not shown."
                } else if parsed.rows.isEmpty {
                    payload.notice = file.status == "R" ? "Renamed with no line changes." : "No line changes."
                }
                self.lastDiffKey = key
                self.diffPage.show(payload)
            }
        }
    }

    // MARK: Viewed

    private func viewedKey(_ f: ChangedFile) -> String { "\(repo?.root ?? "")|\(base.rawValue)|\(f.path)" }

    /// Changes when the file does, so a viewed file comes back once the agent edits it again.
    private func fingerprint(_ f: ChangedFile) -> String {
        let abs = ((repo?.root ?? "") as NSString).appendingPathComponent(f.path)
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: abs))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(Int(mtime * 1000))-\(f.added ?? -1)-\(f.deleted ?? -1)"
    }

    func isViewed(_ f: ChangedFile) -> Bool { (parentReview ?? self).viewed[viewedKey(f)] == fingerprint(f) }

    func toggleViewed(_ f: ChangedFile) {
        let k = viewedKey(f)
        let owner = parentReview ?? self
        if isViewed(f) { owner.viewed.removeValue(forKey: k) } else { owner.viewed[k] = fingerprint(f) }
        owner.scheduleSave()
        objectWillChange.send()
    }

    // MARK: Comments

    private var chatKey: String? { chatID?.uuidString }

    var currentComments: [ReviewComment] { parentReview?.currentComments ?? (chatKey.flatMap { comments[$0] } ?? []) }

    private func pageComments(for path: String) -> [DiffPayload.Comment] {
        currentComments.filter { $0.path == path && $0.root == repo?.root }.map {
            DiffPayload.Comment(id: $0.id, side: $0.side, start: $0.start, end: $0.end, body: $0.body)
        }
    }

    /// A repository section's comments are kept by its parent, with the rest of the chat's.
    func addComment(path: String, side: String, start: Int, end: Int, quoted: [String], body: String) {
        let owner = parentReview ?? self
        guard let key = owner.chatKey, let repo else { return }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let c = ReviewComment(root: repo.root, path: path, side: side == "old" ? "old" : "new",
                              start: min(start, end), end: max(start, end), quoted: quoted, body: text)
        owner.comments[key, default: []].append(c)
        owner.pushComments()
    }

    func removeComment(id: String) {
        if let parentReview { parentReview.removeComment(id: id); return }
        guard let key = chatKey else { return }
        comments[key]?.removeAll { $0.id == id }
        if comments[key]?.isEmpty == true { comments.removeValue(forKey: key) }
        pushComments()
    }

    func clearComments() {
        if let parentReview { parentReview.clearComments(); return }
        guard let key = chatKey else { return }
        comments.removeValue(forKey: key)
        pushComments()
    }

    private func pushComments() {
        scheduleSave()
        for center in repositoryCenters.values {
            center.objectWillChange.send()
            if center.activeTab == .changes, let p = center.selectedPath { center.diffPage.setComments(center.pageComments(for: p)) }
        }
        if let p = selectedPath { diffPage.setComments(pageComments(for: p)) }
    }

    /// Whether the selected chat has a live terminal to type into.
    var canSend: Bool {
        guard let chat = selectedChat, let t = chat.terminal else { return false }
        return chat.status != .ended && !t.processExited
    }

    /// Types every pending comment into the chat as one message and presses Return.
    func sendComments() {
        if let parentReview { parentReview.sendComments(); return }
        guard canSend, let chat = selectedChat, let terminal = chat.terminal, let folder else { return }
        let list = currentComments
        guard !list.isEmpty else { return }
        terminal.submit(CommentMessage.build(list, folder: folder))
        Log.write("review: sent \(list.count) comment(s) to chat=\(chat.id)")
        clearComments()
        showFlash(list.count == 1 ? "Sent 1 comment" : "Sent \(list.count) comments")
        model?.focusRequest.send(terminal)
    }

    func showFlash(_ text: String) {
        flash = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.flash == text { self?.flash = nil }
        }
    }

    // MARK: File actions

    func absolutePath(_ f: ChangedFile) -> String? {
        repo.map { ($0.root as NSString).appendingPathComponent(f.path) }
    }

    func open(_ f: ChangedFile, line: Int? = nil) {
        guard let p = absolutePath(f), FileManager.default.fileExists(atPath: p) else { return }
        model?.openFile(p, line: line)
    }

    func openLine(_ line: Int) {
        if let f = selectedFile { open(f, line: line) }
    }

    func hasUncommittedChanges(_ f: ChangedFile) -> Bool { uncommitted.contains { $0.path == f.path } }

    func confirmRevert(_ f: ChangedFile) {
        guard let repo, let current = uncommitted.first(where: { $0.path == f.path }) else { return }
        let a = NSAlert()
        a.messageText = "Revert \(f.name)?"
        let inHead = !(current.isUntracked || current.status == "A")
        a.informativeText = inHead
            ? "This discards the uncommitted changes to \(current.path) and restores it from the last commit."
            : "\(current.path) isn't in the last commit, so reverting moves it to the Trash."
        a.addButton(withTitle: "Revert")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        queue.async {
            let err = ChangeScanner.revert(current, repo: repo)
            DispatchQueue.main.async {
                if let err, !err.isEmpty {
                    let e = NSAlert()
                    e.messageText = "Couldn't revert \(f.name)"
                    e.informativeText = err
                    e.runModal()
                }
                Log.write("review: reverted \(current.path) in \(repo.root)")
                self.refreshGit()
            }
        }
    }

    /// Types a shell-escaped path into the chat's terminal, as a drop would.
    func insertPath(_ abs: String) {
        guard canSend, let t = selectedChat?.terminal else { return }
        if ReaderModeController.main?.insertIntoComposer(ShellEscape.escape(abs) + " ") == true { return }
        t.pasteText(ShellEscape.escape(abs) + " ")
        model?.focusRequest.send(t)
    }

    // MARK: Files

    func refreshTree(completion: (() -> Void)? = nil) {
        guard let folder else { completion?(); return }
        let gen = generation
        queue.async {
            let inRepo = Git.run(["rev-parse", "--is-inside-work-tree"], in: folder, timeout: 5).text.hasPrefix("true")
            let (paths, truncated) = FileTree.listFiles(folder: folder, inRepo: inRepo)
            let tree = FileTree.build(root: folder, paths: paths, truncated: truncated, fromGit: inRepo)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.tree = tree
                completion?()
            }
        }
    }

    func toggleExpanded(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }

    // MARK: Overview

    func refreshInsights(completion: (() -> Void)? = nil) {
        guard let chat = selectedChat, let path = chat.transcriptPath, let kind = chat.agent.transcript else {
            insights = nil
            if !work.isEmpty { work = AgentWork() }
            completion?()
            return
        }
        // The transcript can change during a chat's life (Claude Code's /resume and /clear),
        // so the follower, and the subagents folder next to it, come from the current path.
        if insightsFollower?.url.path != path { insightsFollower = InsightsFollower(url: URL(fileURLWithPath: path), kind: kind) }
        guard let f = insightsFollower else { return }
        let gen = generation
        let tracker = workTracker
        let processStart: Date? = chat.status == .ended ? nil : chat.startedAt
        queue.async {
            let i = f.poll()
            let w = tracker.update(i.work, transcript: f.url, kind: kind, processStart: processStart)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                if i != self.insights { self.insights = i }
                if w != self.work { self.work = w }
                completion?()
            }
        }
    }

    func refreshPullRequest() {
        guard !fixtureMode, let folder else { return }
        let gen = generation
        slowQueue.async {
            let isRepo = Git.run(["rev-parse", "--is-inside-work-tree"], in: folder, timeout: 5).text.hasPrefix("true")
            let pr = isRepo ? GitHubCLI.pullRequest(folder: folder) : nil
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                if pr != self.pr { self.pr = pr }
            }
        }
    }

    func refreshPorts() {
        guard !fixtureMode, let folder else { return }
        let gen = generation
        slowQueue.async {
            let ports = Ports.listening(in: folder)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                if ports != self.ports { self.ports = ports }
            }
        }
    }

    /// Fixture data for snapshots and the self test.
    func setFixture(pr: PullRequestInfo?, ports: [ListeningPort]) {
        self.pr = pr
        self.ports = ports
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let state = ReviewSavedState(comments: comments, viewed: viewed)
        let w = DispatchWorkItem { state.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }
}
