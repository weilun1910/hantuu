import AppKit

/// Launch state is separate from provider activity. Waiting for a login or trust prompt
/// is a running terminal, not a failed model response.
enum ChatLaunchPhase: Equatable {
    case ready, preparing, creatingWorktree, starting, reconnecting, stopping
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .ready, .failed: return false
        default: return true
        }
    }
    var label: String? {
        switch self {
        case .ready: return nil
        case .preparing: return "Checking agent"
        case .creatingWorktree: return "Creating worktree"
        case .starting: return "Starting agent"
        case .reconnecting: return "Reconnecting"
        case .stopping: return "Stopping agent"
        case .failed(let reason): return reason
        }
    }
}

extension AppModel {
    var archivedChats: [Chat] {
        chats.filter { $0.archivedAt != nil }.sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    static func manualTitle(_ text: String) -> String? {
        let cleaned = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cleaned.isEmpty ? nil : String(cleaned.prefix(200))
    }

    func renameChat(_ chat: Chat, to title: String?) {
        if let title {
            guard let cleaned = Self.manualTitle(title) else { return }
            chat.userTitle = cleaned
        } else { chat.userTitle = nil }
        objectWillChange.send()
        scheduleSave()
    }

    /// Closing is recoverable. A live process always gets an explicit stop confirmation,
    /// even if its last reported activity was idle.
    func archiveChat(_ chat: Chat) {
        guard chat.archivedAt == nil, !chat.launchPhase.isBusy else { return }
        let running = chat.status != .ended || chat.terminal?.processExited == false || sideChats.running.contains(chat.id)
        if running {
            let alert = NSAlert()
            alert.messageText = "Stop and archive this chat?"
            alert.informativeText = "This stops the agent and any side question. Its transcript, side history and worktree stay available. Restore returns the chat without starting the agent."
            alert.addButton(withTitle: "Stop and Archive")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        stopChat(chat) { [weak self, weak chat] in
            guard let self, let chat else { return }
            self.finishArchive(chat)
        }
    }

    /// The fixture suite uses this pure registry operation without touching a helper.
    func finishArchive(_ chat: Chat, at date: Date = Date()) {
        let order = sidebarOrder
        let index = order.firstIndex { $0.id == chat.id } ?? 0
        chat.archivedAt = date
        chat.status = .ended
        chat.launchPhase = .ready
        lastArchivedID = chat.id
        subagentBrowser.forget(chat.id)
        objectWillChange.send()
        if selectedChatID == chat.id {
            let remaining = sidebarOrder
            select(remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id)
        }
        StatusCenter.shared.recomputeAttention()
        scheduleSave()
    }

    func restoreChat(_ chat: Chat) {
        guard chat.archivedAt != nil, !chat.launchPhase.isBusy else { return }
        chat.archivedAt = nil
        if lastArchivedID == chat.id { lastArchivedID = nil }
        objectWillChange.send()
        select(chat.id)
        scheduleSave()
    }

    func reopenLastChat() {
        if let chat = archivedChats.first { restoreChat(chat) }
    }

    /// Stop retains both the sidebar entry and every saved transcript. The completion is
    /// delivered after the helper's stop request, so Retry cannot overlap that request.
    func stopChat(_ chat: Chat, completion: (() -> Void)? = nil) {
        guard chat.launchPhase != .stopping else { return }
        chat.codexTitleIdentity.cancel()
        chat.launchToken = UUID()
        chat.launchMonitor?.invalidate()
        chat.discoveryTimer?.invalidate()
        chat.transcriptRecovery = nil
        chat.follower?.stop()
        chat.launchPhase = .stopping
        sideChats.stop(chat.id)
        chat.terminal?.destroy()
        chat.terminal = nil
        terminalsChanged.send()
        SessionHelper.kill(chat.id) { [weak self, weak chat] in
            let stillAlive = SessionHelper.isAlive(chat?.id ?? UUID())
            DispatchQueue.main.async {
                guard let self, let chat else { return }
                if stillAlive {
                    chat.launchPhase = .failed("The agent is still running. Retry reconnects to it; archiving has been cancelled.")
                    self.objectWillChange.send()
                    return
                }
                chat.status = .ended
                chat.launchPhase = .ready
                completion?()
                self.objectWillChange.send()
                self.scheduleSave()
            }
        }
    }

    func removeArchivedRecord(_ chat: Chat) {
        guard chat.archivedAt != nil, !chat.launchPhase.isBusy else { return }
        let alert = NSAlert()
        alert.messageText = "Remove this hantuu record?"
        alert.informativeText = "This removes the chat and its hantuu side history from the app. Provider transcripts and the worktree are kept on disk. This cannot be undone in hantuu."
        alert.addButton(withTitle: "Remove Record")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        sideChats.forget(chat.id)
        chat.codexTitleIdentity.cancel()
        chat.follower?.stop()
        chat.discoveryTimer?.invalidate()
        chats.removeAll { $0.id == chat.id }
        if lastArchivedID == chat.id { lastArchivedID = nil }
        scheduleSave()
    }

    /// Preflight and helper inspection run away from the UI. Each attempt owns a token;
    /// stale callbacks cannot create a second terminal after cancellation or removal.
    func prepareChat(_ chat: Chat, resuming: Bool? = nil) {
        guard !chat.launchPhase.isBusy, chat.archivedAt == nil, let project = project(chat.projectID) else { return }
        let resuming = resuming ?? chat.resumeOnRetry
        chat.resumeOnRetry = resuming
        let token = UUID()
        chat.launchToken = token
        chat.launchPhase = .preparing
        let cwd = workingDirectory(of: chat)
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak chat] in
            guard let chat else { return }
            let alive = SessionHelper.isAlive(chat.id)
            let detected = AgentCatalog.detect()
            let executable = detected.first { $0.id == chat.agentID }?.path
            var isDirectory: ObjCBool = false
            let folderExists = FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) && isDirectory.boolValue
            DispatchQueue.main.async {
                guard let self, chat.launchToken == token, self.chats.contains(where: { $0 === chat }), chat.archivedAt == nil else { return }
                self.agents = detected
                self.agentsLoaded = true
                if alive {
                    chat.terminal?.destroy()
                    chat.terminal = nil
                    self.reattach(chat)
                    self.readerReload.send(chat.id)
                    return
                }
                guard folderExists else {
                    chat.launchPhase = .failed(chat.worktree == nil ? "Project folder is missing. Locate it before retrying." : "Worktree is missing. Locate the existing checkout before retrying.")
                    return
                }
                guard let executable, FileManager.default.isExecutableFile(atPath: executable) else {
                    chat.launchPhase = .failed("\(chat.agent.name) was not found. Install it or check your shell PATH, then retry to detect it again.")
                    return
                }
                if chat.requestedWorktree && chat.worktree == nil {
                    chat.launchPhase = .creatingWorktree
                    Worktrees.createAsync(projectPath: project.path, chatID: chat.id) { [weak self] result in
                        guard let self, chat.launchToken == token, self.chats.contains(where: { $0 === chat }) else { return }
                        switch result {
                        case .success(let worktree):
                            chat.worktree = worktree
                            self.scheduleSave()
                            self.launchPrepared(chat, project: project, executable: executable, resuming: resuming)
                        case .failure(let error): chat.launchPhase = .failed(error.localizedDescription)
                        }
                    }
                } else {
                    self.launchPrepared(chat, project: project, executable: executable, resuming: resuming)
                }
            }
        }
    }

    private func launchPrepared(_ chat: Chat, project: Project, executable: String, resuming: Bool) {
        var argv: [String]
        if resuming, chat.agentID == "claude" || chat.agentID == "codex",
           chat.sessionID.flatMap(UUID.init(uuidString:)) == nil {
            chat.launchPhase = .failed("The original session identity is unavailable. Locate it in History before resuming.")
            return
        }
        if resuming, let sid = chat.sessionID, let resume = chat.agent.resumeArguments(sessionID: sid) {
            argv = resume
        } else {
            argv = chat.agent.launchArguments(sessionID: chat.sessionID)
        }
        argv[0] = executable
        chat.terminal?.destroy()
        chat.terminal = nil
        launch(chat, argv: argv, in: project)
        readerReload.send(chat.id)
        scheduleSave()
    }

    func monitorLaunch(_ chat: Chat) {
        chat.launchMonitor?.invalidate()
        let token = chat.launchToken
        let started = Date()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self, weak chat] timer in
            guard let self, let chat, chat.launchToken == token, chat.archivedAt == nil else { timer.invalidate(); return }
            guard chat.status != .ended else { timer.invalidate(); return }
            if let terminal = chat.terminal, !terminal.activeScreenText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chat.launchPhase = .ready
                timer.invalidate()
                self.objectWillChange.send()
            } else if Date().timeIntervalSince(started) > 30 {
                chat.launchPhase = .failed("No terminal output yet. Show the terminal to inspect startup, or retry to reconnect safely.")
                timer.invalidate()
                self.objectWillChange.send()
            }
        }
        chat.launchMonitor = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func locateProject(_ project: Project) {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.message = "Locate the existing folder for \(project.name). Chats keep their transcript identities."
        picker.prompt = "Locate Folder"
        guard picker.runModal() == .OK, let url = picker.url,
              let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        guard !chats.contains(where: { $0.projectID == project.id && ($0.status != .ended || $0.launchPhase.isBusy) }) else { return }
        projects[index].path = url.standardizedFileURL.path
        scheduleSave()
    }

    func locateWorktree(_ chat: Chat) {
        guard chat.status == .ended, !chat.launchPhase.isBusy, let old = chat.worktree else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.message = "Locate the existing worktree checkout. No files will be created or deleted."
        guard picker.runModal() == .OK, let url = picker.url else { return }
        let path = url.standardizedFileURL.path
        chat.launchPhase = .preparing
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak chat] in
            let root = Worktrees.repoRoot(of: path)
            let common = Worktrees.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path)
            let original = Worktrees.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: old.repo)
            DispatchQueue.main.async {
                guard let self, let chat else { return }
                guard let root, common.code == 0, original.code == 0, common.out == original.out else {
                    chat.launchPhase = .failed("That folder is not a checkout of the same repository.")
                    return
                }
                // Relocating a checkout does not grant ownership of a new branch or folder.
                // Keep the original cleanup metadata and only change the launch directory.
                var moved = old
                moved.directory = path
                if root == old.root { moved.root = root }
                chat.worktree = moved
                chat.launchPhase = .ready
                self.scheduleSave()
            }
        }
    }
}

extension AppModel {
    /// Cleanup is independent of archive and never deletes the branch. Git gets no force
    /// flag, and a second scan after confirmation protects newly dirty checkouts.
    func cleanupArchivedWorktree(_ chat: Chat) {
        guard chat.archivedAt != nil, chat.status == .ended, !chat.launchPhase.isBusy, let worktree = chat.worktree else { return }
        chat.launchPhase = .preparing
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak chat] in
            let problem = Self.worktreeCleanupProblem(worktree)
            DispatchQueue.main.async {
                guard let self, let chat, chat.archivedAt != nil else { return }
                chat.launchPhase = .ready
                let alert = NSAlert()
                if let problem {
                    alert.messageText = "Worktree kept"
                    alert.informativeText = problem
                    alert.runModal()
                    return
                }
                alert.messageText = "Remove this archived chat's worktree?"
                alert.informativeText = "The checkout at \(worktree.root) will be removed. The branch \(worktree.branch), chat record and provider transcript will be kept. Any uncommitted, untracked or ignored files block removal."
                alert.addButton(withTitle: "Remove Checkout")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn, chat.archivedAt != nil else { return }
                chat.launchPhase = .preparing
                DispatchQueue.global(qos: .userInitiated).async {
                    let changed = Self.worktreeCleanupProblem(worktree)
                    let result = changed == nil ? Worktrees.run(["worktree", "remove", worktree.root], in: worktree.repo) : (code: Int32(-1), out: "", err: changed!)
                    DispatchQueue.main.async {
                        chat.launchPhase = .ready
                        if result.code == 0 {
                            // Restoring does not silently create a fresh checkout or run in the
                            // main tree. The missing recorded launch directory remains visible.
                            chat.requestedWorktree = false
                            chat.launchPhase = .failed("The checkout was removed. The branch is kept; restore its checkout before resuming.")
                            self.scheduleSave()
                        } else {
                            let failure = NSAlert()
                            failure.messageText = "Worktree kept"
                            failure.informativeText = result.err
                            failure.runModal()
                        }
                    }
                }
            }
        }
    }

    static func worktreeCleanupProblem(_ worktree: WorktreeInfo) -> String? {
        guard FileManager.default.fileExists(atPath: worktree.root) else { return "The recorded checkout is missing. No branch was removed." }
        guard Worktrees.repoRoot(of: worktree.root) == worktree.root else { return "The recorded folder is not the checkout root. No files were removed." }
        let common = Worktrees.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: worktree.root)
        let expected = Worktrees.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: worktree.repo)
        let branch = Worktrees.run(["symbolic-ref", "--short", "HEAD"], in: worktree.root)
        guard common.code == 0, expected.code == 0, common.out == expected.out,
              branch.code == 0, branch.out.trimmingCharacters(in: .whitespacesAndNewlines) == worktree.branch else {
            return "The checkout's repository or branch changed. No files were removed."
        }
        let dirty = Worktrees.run(["status", "--porcelain"], in: worktree.root)
        let ignored = Worktrees.run(["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], in: worktree.root)
        guard dirty.code == 0, ignored.code == 0 else { return "Git could not verify that the checkout is clean. No files were removed." }
        guard dirty.out.isEmpty, ignored.out.isEmpty else {
            return "The checkout contains uncommitted, untracked or ignored files. Save or move them before cleanup. hantuu will not force removal."
        }
        return nil
    }
}


extension AppModel {
    func renameProject(_ project: Project, reset: Bool = false) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        if reset { projects[index].alias = nil; scheduleSave(); return }
        let alert = NSAlert()
        alert.messageText = "Rename project in hantuu"
        alert.informativeText = "This changes the sidebar label. The folder stays where it is."
        let field = NSTextField(string: project.name)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, let title = Self.manualTitle(field.stringValue),
              let current = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[current].alias = title
        scheduleSave()
    }
}
