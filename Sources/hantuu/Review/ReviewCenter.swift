import AppKit
import Combine

/// State behind the Overview, Changes and Files tabs. It follows the selected chat (or the
/// current project when no chat is selected) and only does work while one of those tabs is
/// showing: git runs on a background queue, the folder is watched with FSEvents, and the PR
/// and port lookups run on timers.
final class ReviewCenter: ObservableObject {
    static let shared = ReviewCenter()

    private(set) weak var model: AppModel?
    @Published private(set) var chatID: UUID?
    @Published private(set) var folder: String?
    @Published private(set) var activeTab: PanelTab?

    // Changes
    @Published private(set) var repo: RepoInfo?
    @Published private(set) var repoChecked = false
    @Published var base: DiffBase = .uncommitted { didSet { if base != oldValue { baseChanged() } } }
    @Published private(set) var changes: [ChangedFile] = []
    @Published private(set) var uncommitted: [ChangedFile] = []
    @Published private(set) var branchSummary: ChangeSummary?
    @Published private(set) var changesLoaded = false
    @Published var selectedPath: String? { didSet { if selectedPath != oldValue { loadDiff() } } }
    @Published private(set) var comments: [String: [ReviewComment]] = [:]
    @Published private(set) var viewed: [String: String] = [:]
    @Published var flash: String?

    // Overview
    @Published private(set) var insights: SessionInsights?
    @Published private(set) var pr: PullRequestInfo?
    @Published private(set) var ports: [ListeningPort] = []

    // Files
    @Published private(set) var tree: FileTree?
    @Published var filter = ""
    @Published var expanded: Set<String> = []

    let diffPage = DiffPage()
    /// Fixtures for snapshots and tests: no gh, lsof or timers.
    var fixtureMode = false

    private let queue = DispatchQueue(label: "hantuu.review", qos: .userInitiated)
    private let slowQueue = DispatchQueue(label: "hantuu.review.slow", qos: .utility)
    private var generation = 0
    private var watcher: FolderWatcher?
    private var timers: [Timer] = []
    private var insightsFollower: InsightsFollower?
    private var forcedLarge: Set<String> = []
    private var lastDiffKey = ""
    private var saveWork: DispatchWorkItem?
    private var bag = Set<AnyCancellable>()

    init() {
        let s = ReviewSavedState.load()
        comments = s.comments
        viewed = s.viewed
        diffPage.center = self
    }

    func configure(model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
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
        guard chat?.id != chatID || f != folder else { return }
        let folderChanged = f != folder
        chatID = chat?.id
        folder = f
        generation += 1
        insightsFollower = nil
        insights = nil
        if folderChanged {
            repo = nil
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
        diffPage.clear("")
        updateActivity(refresh: true)
    }

    /// Called by the panel whenever it syncs: which tab shows, if any.
    func setActiveTab(_ tab: PanelTab?) {
        let t: PanelTab? = [.overview, .changes, .files].contains(tab) ? tab : nil
        guard t != activeTab else { return }
        activeTab = t
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
        refreshGit()
        if activeTab == .files { refreshTree() }
    }

    func refreshNow() {
        updateActivity(refresh: true)
    }

    // MARK: Git

    func refreshGit(completion: (() -> Void)? = nil) {
        guard let folder else { completion?(); return }
        let gen = generation
        let base = self.base
        let wantBranch = activeTab == .overview || base == .branch
        queue.async {
            let repo = RepoInfo.load(folder: folder)
            var unc: [ChangedFile] = [], list: [ChangedFile] = []
            var summary: ChangeSummary?
            if let repo {
                let env = Git.readOnlyIndex(root: repo.root)
                unc = ChangeScanner.uncommitted(repo, env: env)
                var branchList: [ChangedFile]?
                if wantBranch, let mb = repo.mergeBase { branchList = ChangeScanner.branch(repo, base: mb, env: env) }
                list = base == .branch ? (branchList ?? unc) : unc
                summary = (branchList ?? unc).summary
            }
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                let rootChanged = repo?.root != self.repo?.root
                if repo != self.repo { self.repo = repo }
                self.repoChecked = true
                if unc != self.uncommitted { self.uncommitted = unc }
                if list != self.changes { self.changes = list }
                if wantBranch { self.branchSummary = summary }
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

    private func baseChanged() {
        lastDiffKey = ""
        changesLoaded = false
        refreshGit()
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
    var changedInFolder: [String: Character] {
        guard let repo, let folder else { return [:] }
        let f = folder.hasSuffix("/") ? folder : folder + "/"
        var out: [String: Character] = [:]
        for c in uncommitted {
            let abs = (repo.root as NSString).appendingPathComponent(c.path)
            if abs.hasPrefix(f) { out[String(abs.dropFirst(f.count))] = c.status }
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
                guard gen == self.generation, self.selectedPath == file.path else { return }
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

    func isViewed(_ f: ChangedFile) -> Bool { viewed[viewedKey(f)] == fingerprint(f) }

    func toggleViewed(_ f: ChangedFile) {
        let k = viewedKey(f)
        if isViewed(f) { viewed.removeValue(forKey: k) } else { viewed[k] = fingerprint(f) }
        scheduleSave()
    }

    // MARK: Comments

    private var chatKey: String? { chatID?.uuidString }

    var currentComments: [ReviewComment] { chatKey.flatMap { comments[$0] } ?? [] }

    private func pageComments(for path: String) -> [DiffPayload.Comment] {
        currentComments.filter { $0.path == path && $0.root == repo?.root }.map {
            DiffPayload.Comment(id: $0.id, side: $0.side, start: $0.start, end: $0.end, body: $0.body)
        }
    }

    func addComment(path: String, side: String, start: Int, end: Int, quoted: [String], body: String) {
        guard let key = chatKey, let repo else { return }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let c = ReviewComment(root: repo.root, path: path, side: side == "old" ? "old" : "new",
                              start: min(start, end), end: max(start, end), quoted: quoted, body: text)
        comments[key, default: []].append(c)
        pushComments()
    }

    func removeComment(id: String) {
        guard let key = chatKey else { return }
        comments[key]?.removeAll { $0.id == id }
        if comments[key]?.isEmpty == true { comments.removeValue(forKey: key) }
        pushComments()
    }

    func clearComments() {
        guard let key = chatKey else { return }
        comments.removeValue(forKey: key)
        pushComments()
    }

    private func pushComments() {
        scheduleSave()
        if let p = selectedPath { diffPage.setComments(pageComments(for: p)) }
    }

    /// Whether the selected chat has a live terminal to type into.
    var canSend: Bool {
        guard let chat = selectedChat, let t = chat.terminal else { return false }
        return chat.status != .ended && !t.processExited
    }

    /// Types every pending comment into the chat as one message and presses Return.
    func sendComments() {
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
            completion?()
            return
        }
        if insightsFollower?.url.path != path { insightsFollower = InsightsFollower(url: URL(fileURLWithPath: path), kind: kind) }
        guard let f = insightsFollower else { return }
        let gen = generation
        queue.async {
            let i = f.poll()
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                if i != self.insights { self.insights = i }
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
