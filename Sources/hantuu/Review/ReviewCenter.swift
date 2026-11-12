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
    @Published var base: DiffBase = .unstaged { didSet { if !restoringPanel, base != oldValue { baseChanged(); rememberPanelState() } } }
    @Published var changes: [ChangedFile] = []
    @Published private(set) var uncommitted: [ChangedFile] = []
    @Published private(set) var branchSummary: ChangeSummary?
    @Published var changesLoaded = false
    @Published var selectedPath: String? { didSet { if !restoringPanel, selectedPath != oldValue { loadDiff(); rememberPanelState() } } }
    @Published private(set) var comments: [String: [ReviewComment]] = [:]
    @Published private(set) var viewed: [String: String] = [:]
    @Published var flash: String?
    @Published var gitReadState = PanelReadState()
    @Published var diffReadState = PanelReadState()
    @Published var gitSnapshot: GitReviewSnapshot?
    @Published var gitSelection = GitReviewSelection()
    @Published var selectedCheckout: String?
    @Published var diffText = ""
    @Published var hunks: [GitReviewHunk] = []
    @Published var operationRunning = false
    @Published var operationMessage: String?
    @Published var recoveryFolder: URL?
    @Published var pathFilter = ""
    @Published var hideTests = false
    @Published var hideGenerated = false
    @Published var hideDeleted = false
    @Published var diffContext = 3 { didSet { if diffContext != oldValue { loadDiff() } } }
    @Published var commitMessage = ""
    @Published var prTitle = ""
    @Published var prBody = ""
    @Published var prDraft = true
    private var gitRefreshInFlight = false
    private var gitRefreshAgain = false
    private var gitRefreshCompletions: [() -> Void] = []
    private var diffRequest = 0

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

    var checkoutPreferenceRoot: String? { parentReview == nil ? folder : nestedEntry?.info.root }

    var hasRepositories: Bool { repo != nil || !repositories.isEmpty }
    /// What Overview's Changes card counts: the branch, or every nested repository's branch.
    var overviewSummary: ChangeSummary? { repo == nil ? repositories.flatMap(\.branch).summary : branchSummary }

    // Overview
    @Published private(set) var repositoryPullRequests: [RepositoryPullRequest] = []
    @Published private(set) var prReadState = PanelReadState()
    @Published private(set) var portsReadState = PanelReadState()
    @Published private(set) var insightsReadState = PanelReadState()
    @Published private(set) var insights: SessionInsights?
    /// The selected chat's subagents and background tasks, with what their own files add.
    @Published private(set) var work = AgentWork()
    @Published private(set) var pr: PullRequestInfo?
    @Published private(set) var ports: [ListeningPort] = []

    // Files
    @Published private(set) var filesReadState = PanelReadState()
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
        insightsReadState = PanelReadState()
        filesReadState.loading = false
        prReadState.loading = false
        portsReadState.loading = false
        if folderChanged {
            prReadState = PanelReadState()
            portsReadState = PanelReadState()
            filesReadState = PanelReadState()
            repositoryPullRequests = []
        }
        workTracker = AgentWorkTracker()
        work = AgentWork()
        if folderChanged {
            flash = nil
            repo = nil
            gitSnapshot = nil
            selectedCheckout = f.flatMap { GitReviewSelection.load($0).checkout }
            gitSelection = GitReviewSelection.load(selectedCheckout ?? f ?? "")
            gitReadState = PanelReadState()
            diffReadState = PanelReadState()
            diffText = ""
            hunks = []
            operationMessage = nil
            recoveryFolder = nil
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
        base = state.base ?? .unstaged
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
        if parentReview != nil { refreshGit(); return }
        invalidateDiscovery()
        updateActivity(refresh: false)
        refreshGit()
    }

    // MARK: Git

    func refreshGit(completion: (() -> Void)? = nil) {
        guard let folder else { completion?(); return }
        if gitRefreshInFlight {
            gitRefreshAgain = true
            if let completion { gitRefreshCompletions.append(completion) }
            return
        }
        gitRefreshInFlight = true
        let target = selectedCheckout ?? (parentReview == nil ? folder : (repo?.root ?? folder))
        let gen = generation
        let scope = base
        let selection = gitSelection
        gitReadState.loading = true
        queue.async {
            // Superseded queued scans must not delay the current explicit refresh.
            let current = DispatchQueue.main.sync { gen == self.generation && scope == self.base && selection == self.gitSelection }
            guard current else { DispatchQueue.main.async { self.finishGitRefresh(completion: completion) }; return }
            let info = RepoInfo.load(folder: target)
            var snapshot: GitReviewSnapshot?
            var failure: String?
            var nested: [RepositoryChanges] = []
            var truncated = false
            if info != nil {
                do { snapshot = try GitReviewSnapshot.load(root: info!.root, scope: scope, selection: selection) }
                catch { failure = error.localizedDescription }
            } else if FileManager.default.fileExists(atPath: (target as NSString).appendingPathComponent(".git")) {
                failure = "Git could not read this checkout. Check its permissions and repository metadata."
            } else {
                let discovered = self.discoveryCache.result(folder: target)
                truncated = discovered.truncated
                nested = RepositoryChanges.ordered(discovered.repositories.compactMap(RepositoryChanges.scan))
                let errors = discovered.errors + nested.compactMap(\.scanError)
                if !errors.isEmpty { failure = errors.joined(separator: "\n") }
                if nested.count != discovered.repositories.count { failure = "Some repositories could not be read. Retry before reviewing them." }
            }
            DispatchQueue.main.async {
                defer { self.finishGitRefresh(completion: completion) }
                let currentTarget = self.selectedCheckout ?? (self.parentReview == nil ? self.folder : (self.repo?.root ?? self.folder))
                guard gen == self.generation, scope == self.base, selection == self.gitSelection, target == currentTarget else { return }
                self.gitReadState.loading = false
                self.gitReadState.error = failure
                self.repoChecked = true
                if let failure {
                    if !nested.isEmpty { self.applyRepositories(nested) }
                    self.operationMessage = failure
                    return
                }
                self.gitReadState.lastSuccess = Date()
                let repositorySetChanged = self.repo?.root != info?.root || self.repositories.map(\.id) != nested.map(\.id)
                self.repo = info
                self.gitSnapshot = snapshot
                if let snapshot {
                    self.gitSelection = snapshot.selection
                    snapshot.selection.save(snapshot.info.root)
                    self.changes = snapshot.files
                    self.uncommitted = snapshot.uncommitted
                    self.branchSummary = snapshot.overviewSummary
                } else {
                    self.changes = []
                    self.uncommitted = []
                }
                if !nested.isEmpty || !self.repositories.isEmpty { self.applyRepositories(nested) }
                self.discoveryTruncated = truncated
                self.changesLoaded = true
                if self.activeTab != nil { self.startWatching() }
                if self.selectedPath == nil || !self.changes.contains(where: { $0.path == self.selectedPath }) {
                    self.selectedPath = self.changes.first?.path
                }
                self.loadDiff()
                if repositorySetChanged, self.activeTab == .overview { self.refreshPullRequest() }
                if let parent = self.parentReview {
                    parent.objectWillChange.send()
                    parent.repositoryListRefreshed()
                }
            }
        }
    }

    private func finishGitRefresh(completion: (() -> Void)?) {
        gitRefreshInFlight = false
        let again = gitRefreshAgain
        gitRefreshAgain = false
        let waiting = gitRefreshCompletions
        gitRefreshCompletions = []
        completion?()
        if again { refreshGit { waiting.forEach { $0() } } }
        else { waiting.forEach { $0() } }
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
        guard expandedRepositories.contains(id), let center = repositoryCenters[id] else { return false }
        // Reserve the first open section while its scoped scan loads. Completion order
        // must not choose the initial diff or replace a restored repository selection.
        if !center.changesLoaded { return center.nestedEntry?.hasChanges == true }
        return !center.changes.isEmpty
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

    /// A background scan preserves the chosen section. If its list becomes empty,
    /// the diff moves to the next open section with changes.
    private func repositoryListRefreshed() {
        if focusedRepository.map({ !canFocus($0) }) ?? true {
            focusedRepository = firstFocusable()
            updateRepositoryTabs()
        }
    }

    /// Whether this repository's selected file is the one whose diff is showing.
    var showsSelection: Bool {
        guard let parentReview else { return true }
        return parentReview.focusedRepository == parentReview.repositoryCenters.first(where: { $0.value === self })?.key
    }

    /// Picks a file in the list. In a repository section it also moves the diff to it.
    func select(_ path: String) {
        selectedPath = path
        if let parentReview, let id = parentReview.repositoryCenters.first(where: { $0.value === self })?.key { parentReview.focus(id) }
    }

    private func addRepositoryCenter(for entry: RepositoryChanges) -> ReviewCenter {
        let center = ReviewCenter(loadSavedState: false)
        center.parentReview = self
        // Diffs go through the same private index copy the scan uses, so they share its queue.
        center.queue = queue
        center.model = model
        center.chatID = chatID
        center.folder = folder
        center.selectedCheckout = GitReviewSelection.load(entry.info.root).checkout
        center.panelProjectID = panelProjectID
        center.restoringPanel = true
        // Open on the comparison that has something to show: a branch whose work is all
        // committed opens on Branch rather than on an empty Uncommitted list.
        center.base = entry.uncommitted.isEmpty && entry.info.mergeBase != nil ? .branch : .unstaged
        center.gitSelection = GitReviewSelection.load(entry.info.root)
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
        if let error = entry.scanError {
            if repo == nil { repo = entry.info }
            repoChecked = true
            gitReadState.loading = false
            gitReadState.error = error
            return
        }
        nestedEntry = entry
        if selectedCheckout == nil, entry.info != repo { repo = entry.info }
        if repo == nil { repo = entry.info }
        repoChecked = true
        if gitSnapshot == nil { branchSummary = entry.branch.summary }
        refreshGit()
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
        diffRequest += 1
        diffReadState.loading = false
        hunks = []
        // A comparison choice takes focus now. Its asynchronous result must not take
        // focus back if the user selects or closes another section while it loads.
        if let parentReview {
            if let id = parentReview.repositoryCenters.first(where: { $0.value === self })?.key,
               parentReview.expandedRepositories.contains(id) {
                parentReview.focus(id)
            }
            refreshGit()
            return
        }
        if activeTab != nil { refreshGit() }
    }

    var baseRef: String? {
        if let snapshot = gitSnapshot, snapshot.scope == base { return snapshot.baseRevision }
        guard let repo else { return nil }
        if base == .branch, let mb = repo.mergeBase { return mb }
        return repo.headRef
    }

    var baseLabel: String {
        if base == .branch { return gitSelection.target ?? repo?.defaultBranch ?? "Choose target" }
        if base == .commit { return String((gitSelection.commit ?? "HEAD").prefix(10)) }
        if base == .unstaged { return "index" }
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
        guard activeTab == .changes, let snapshot = gitSnapshot, snapshot.scope == base,
              let file = selectedFile else {
            if activeTab == .changes, changesLoaded, selectedFile == nil {
                diffRequest += 1
                diffReadState = PanelReadState()
                diffPage.clear(changes.isEmpty ? "" : "Pick a file to see its diff.")
                diffText = ""
                hunks = []
                lastDiffKey = ""
            }
            return
        }
        let gen = generation
        diffRequest += 1
        let request = diffRequest
        let context = diffContext
        let key = "\(snapshot.info.root)|\(base.rawValue)|\(file.path)"
        let allowLarge = force || forcedLarge.contains(key)
        if force { forcedLarge.insert(key) }
        let keepScroll = key == lastDiffKey
        diffReadState.loading = true
        queue.async {
            do {
                let text = try snapshot.diff(file, context: context)
                try GitReviewActions.validate(snapshot)
                let tooBig = text.utf8.count > 800_000
                let parsed = tooBig && !allowLarge ? ParsedDiff() : DiffParser.parse(text)
                DispatchQueue.main.async {
                    guard gen == self.generation, request == self.diffRequest, self.selectedPath == file.path,
                          self.gitSnapshot?.revision == snapshot.revision, self.base == snapshot.scope, self.activeTab == .changes else { return }
                    self.diffReadState = PanelReadState(loading: false, lastSuccess: Date(), error: nil)
                    self.diffText = text
                    self.hunks = GitReviewHunk.parse(text, file: file, context: context)
                    var payload = DiffPayload(key: key, path: file.path, rows: parsed.rows, comments: self.pageComments(for: file.path), keepScroll: keepScroll)
                    payload.revision = snapshot.fingerprints[file.path]
                    if !allowLarge && (tooBig || parsed.rows.count > 4000) {
                        payload.rows = []
                        payload.large = max(parsed.rows.count, text.split(separator: "\n").count)
                    } else if parsed.binary { payload.notice = "Binary file, not shown." }
                    else if parsed.rows.isEmpty { payload.notice = file.status == "R" ? "Renamed with no line changes." : "No line changes." }
                    self.lastDiffKey = key
                    self.diffPage.show(payload)
                }
            } catch {
                DispatchQueue.main.async {
                    guard gen == self.generation, request == self.diffRequest else { return }
                    self.diffReadState.loading = false
                    self.diffReadState.error = error.localizedDescription
                }
            }
        }
    }

    // MARK: Viewed

    private func viewedKey(_ f: ChangedFile) -> String { "\(repo?.root ?? "")|\(base.rawValue)|\(f.path)" }

    func revisionIdentity(file: ChangedFile) -> String? { gitSnapshot?.scope == base ? gitSnapshot?.fingerprints[file.path] : nil }

    private func fingerprint(_ f: ChangedFile) -> String { revisionIdentity(file: f) ?? "unavailable" }

    func isViewed(_ f: ChangedFile) -> Bool { revisionIdentity(file: f) != nil && (parentReview ?? self).viewed[viewedKey(f)] == fingerprint(f) }

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
            DiffPayload.Comment(id: $0.id, side: $0.side, start: $0.start, end: $0.end, body: $0.body, quoted: $0.quoted, revision: $0.revision)
        }
    }

    /// A repository section's comments are kept by its parent, with the rest of the chat's.
    func addComment(path: String, side: String, start: Int, end: Int, quoted: [String], body: String, revision: String? = nil) {
        let owner = parentReview ?? self
        guard let key = owner.chatKey, let repo else { return }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let c = ReviewComment(root: repo.root, path: path, side: side == "old" ? "old" : "new",
                              start: min(start, end), end: max(start, end), quoted: quoted, body: text, revision: revision)
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

    func editComment(id: String, body: String) {
        if let parentReview { parentReview.editComment(id: id, body: body); return }
        guard let key = chatKey, let i = comments[key]?.firstIndex(where: { $0.id == id }),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        comments[key]?[i].body = body
        pushComments()
    }

    func addCommentsToMessage() {
        guard let id = chatID, let folder else { return }
        if ReaderModeController.main?.addPanelFeedbackToDraft(CommentMessage.build(currentComments, folder: folder), chatID: id) == true {
            showFlash("Added to message")
        }
    }

    func sendComments() {
        if let parentReview { parentReview.sendComments(); return }
        guard let chat = selectedChat, let folder, let model else { return }
        let key = chat.id.uuidString
        PanelFeedbackDelivery.shared.send(comments: currentComments, folder: folder, chatID: chat.id, model: model) { [weak self] delivered in
            guard let self else { return }
            // A comment edited after sending remains pending as new feedback.
            self.comments[key]?.removeAll { delivered.contains($0) }
            self.pushComments()
        }
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

    func openLine(_ line: Int, side: String = "new") {
        guard let file = selectedFile else { return }
        if side == "old", let snapshot = gitSnapshot {
            HistoricalSourceWindow.open(snapshot: snapshot, file: file, line: line, old: true)
        } else if let snapshot = gitSnapshot, snapshot.scope == .branch || snapshot.scope == .commit {
            HistoricalSourceWindow.open(snapshot: snapshot, file: file, line: line, old: false)
        } else { open(file, line: line) }
    }

    func hasUncommittedChanges(_ f: ChangedFile) -> Bool { uncommitted.contains { $0.path == f.path } }

    func confirmRevert(_ f: ChangedFile) { confirmGitAction(.discard(f)) }

    /// File context joins the same chat-owned draft as other panel feedback.
    func insertPath(_ abs: String) {
        guard let id = chatID else { return }
        _ = ReaderModeController.main?.addPanelFeedbackToDraft(ShellEscape.escape(abs), chatID: id)
    }

    // MARK: Files

    func refreshTree(completion: (() -> Void)? = nil) {
        guard !filesReadState.loading, let folder else { completion?(); return }
        let gen = generation
        filesReadState.loading = true
        queue.async {
            let result = Result { () throws -> FileTree in
                let probe = Git.run(["rev-parse", "--is-inside-work-tree"], in: folder, timeout: 5)
                let inRepo = probe.ok && probe.text.hasPrefix("true")
                // Only Git's explicit non-repository response permits a directory walk.
                if !probe.ok && !probe.err.contains("not a git repository") {
                    throw GitReviewError(message: probe.err.isEmpty ? "Could not inspect this folder." : probe.err)
                }
                let listing = try FileTree.listFilesChecked(folder: folder, inRepo: inRepo)
                return FileTree.build(root: folder, paths: listing.paths, truncated: listing.truncated, fromGit: inRepo)
            }
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.filesReadState.loading = false
                switch result {
                case .success(let tree):
                    self.tree = tree
                    self.filesReadState.lastSuccess = Date()
                    self.filesReadState.error = nil
                case .failure(let error): self.filesReadState.error = error.localizedDescription
                }
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
            insightsReadState.loading = false
            insightsReadState.error = "No transcript is available for this chat."
            if !work.isEmpty { work = AgentWork() }
            completion?()
            return
        }
        // The transcript can change during a chat's life (Claude Code's /resume and /clear),
        // so the follower, and the subagents folder next to it, come from the current path.
        if insightsFollower?.url.path != path {
            insightsFollower = InsightsFollower(url: URL(fileURLWithPath: path), kind: kind)
            insights = nil
            insightsReadState = PanelReadState()
        }
        guard !insightsReadState.loading, let f = insightsFollower else { completion?(); return }
        insightsReadState.loading = true
        let gen = generation
        let tracker = workTracker
        let processStart: Date? = chat.status == .ended ? nil : chat.startedAt
        queue.async {
            let result = Result { try f.pollChecked() }
            let w = (try? result.get()).map { tracker.update($0.work, transcript: f.url, kind: kind, processStart: processStart) }
            DispatchQueue.main.async {
                guard gen == self.generation, self.insightsFollower === f else { return }
                self.insightsReadState.loading = false
                switch result {
                case .success(let i):
                    if i != self.insights { self.insights = i }
                    if let w, w != self.work { self.work = w }
                    self.insightsReadState.lastSuccess = Date()
                    self.insightsReadState.error = nil
                case .failure(let error): self.insightsReadState.error = error.localizedDescription
                }
                completion?()
            }
        }
    }

    func refreshPullRequest() {
        guard !fixtureMode, !prReadState.loading, let folder else { return }
        let gen = generation
        prReadState.loading = true
        let roots = repo == nil ? repositories.map { $0.repository.root }.sorted() : []
        let previous = repositoryPullRequests
        repositoryPullRequests = roots.map { root in
            var entry = previous.first { $0.root == root } ?? RepositoryPullRequest(root: root)
            entry.readState.loading = true
            return entry
        }
        slowQueue.async {
            let nested = roots.map { root -> RepositoryPullRequest in
                var entry = previous.first { $0.root == root } ?? RepositoryPullRequest(root: root)
                switch GitHubCLI.readPullRequest(folder: root) {
                case .success(let pr): entry.pr = pr; entry.readState = PanelReadState(lastSuccess: Date())
                case .failure(let error): entry.readState.loading = false; entry.readState.error = error.localizedDescription
                }
                return entry
            }
            let result: Result<PullRequestInfo?, GitHubCLI.ReadError> = roots.isEmpty ? GitHubCLI.readPullRequest(folder: folder) : .success(nil)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.prReadState.loading = false
                self.repositoryPullRequests = nested
                switch result {
                case .success(let pr):
                    self.pr = pr
                    self.prReadState.lastSuccess = Date()
                    self.prReadState.error = nil
                case .failure(let error): self.prReadState.error = error.localizedDescription
                }
            }
        }
    }

    func refreshPorts() {
        guard !fixtureMode, !portsReadState.loading, let folder else { return }
        let gen = generation
        portsReadState.loading = true
        DispatchQueue.global(qos: .utility).async {
            let result = Ports.readListening(in: folder)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.portsReadState.loading = false
                switch result {
                case .success(let ports):
                    self.ports = ports
                    self.portsReadState.lastSuccess = Date()
                    self.portsReadState.error = nil
                case .failure(let error): self.portsReadState.error = error.localizedDescription
                }
            }
        }
    }

    /// Fixture data for snapshots and the self test.
    func setFixture(pr: PullRequestInfo?, ports: [ListeningPort], readState: PanelReadState? = nil) {
        self.pr = pr
        self.ports = ports
        self.prReadState = readState ?? PanelReadState(lastSuccess: Date())
        self.portsReadState = readState ?? PanelReadState(lastSuccess: Date())
        if let readState { self.insightsReadState = readState }
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
