import AppKit

extension AppModel {
    /// The folder a chat's agent runs in: its worktree if it has one, otherwise the project's.
    func workingDirectory(of chat: Chat) -> String {
        if let w = chat.worktree?.directory { return w }
        return project(chat.projectID)?.path ?? Paths.home.path
    }

    /// At launch: chats whose agent kept running in hantuu-session come back attached and
    /// running. The rest stay ended, with Resume, as before.
    func restoreSessions() {
        SessionHelper.prepare()
        SessionSettings.shared.watch(self)
        var live = Dictionary(SessionHelper.list().filter { !$0.exited }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for chat in chats {
            guard let info = live.removeValue(forKey: chat.id.uuidString) else { continue }
            // Archive never intentionally leaves a process alive. A crash during Stop must
            // surface that process again rather than hiding it behind an archived row.
            if chat.archivedAt != nil { chat.archivedAt = nil }
            reattach(chat, startedAt: Date(timeIntervalSince1970: info.created))
        }
        adoptOrphans(Array(live.values))
        SessionDebug.startIfRequested(self)
    }

    /// A session with no saved chat: the app quit or crashed before saving a chat it had just
    /// started. Rather than leave an invisible agent running, give it a chat in the project
    /// it's working in.
    private func adoptOrphans(_ sessions: [SessionInfo]) {
        for info in sessions {
            guard let id = UUID(uuidString: info.id) else { continue }
            let marker = "/.hantuu/worktrees/"
            var worktree: WorktreeInfo?
            var dir = info.cwd
            if let r = info.cwd.range(of: marker) {
                let repo = String(info.cwd[..<r.lowerBound])
                let tail = info.cwd[r.upperBound...]
                let slug = tail.split(separator: "/").first.map(String.init) ?? ""
                worktree = WorktreeInfo(repo: repo, root: repo + marker + slug, directory: info.cwd, branch: "hantuu/" + slug)
                dir = repo + tail.dropFirst(slug.count) // the same folder in the main checkout
            }
            guard let project = projects.first(where: { dir == $0.path || dir.hasPrefix($0.path + "/") }) else {
                Log.write("sessions: left session \(info.id) alone, no project holds \(info.cwd)")
                continue
            }
            let words = info.command.split(separator: " ").map(String.init)
            let agentID = words.first.map { ($0 as NSString).lastPathComponent } ?? "agent"
            let chat = Chat(id: id, projectID: project.id, agentID: agentID, createdAt: Date(timeIntervalSince1970: info.created))
            chat.worktree = worktree
            if let i = words.firstIndex(of: "--session-id"), i + 1 < words.count { chat.sessionID = words[i + 1] }
            chats.append(chat)
            reattach(chat, startedAt: Date(timeIntervalSince1970: info.created))
            Log.write("sessions: adopted session \(info.id) into \(project.name)")
        }
    }

    /// Quitting with "Keep agents running" off: stop every agent, as quitting did before.
    func stopAllSessions() {
        let ids = chats.filter { $0.terminal != nil }.map(\.id)
        guard !ids.isEmpty else { return }
        SessionHelper.killAll(ids)
    }
}

/// Test hook. With `HANTUU_SCREEN_DUMP_DIR` set, the app writes each chat's status and visible
/// terminal text to `<dir>/<chat id>.txt` every second, so a headless check can see what a
/// reattached chat shows. Off unless the variable is set.
enum SessionDebug {
    private static var timer: Timer?

    static func startIfRequested(_ model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["HANTUU_SCREEN_DUMP_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        Paths.ensure(url)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak model] _ in
            guard let model else { return }
            for chat in model.chats {
                let text = "status=\(chat.status.rawValue) terminal=\(chat.terminal != nil) worktree=\(chat.worktree?.branch ?? "-")\n"
                    + (chat.terminal?.screenText() ?? "")
                try? Data(text.utf8).write(to: url.appendingPathComponent("\(chat.id.uuidString).txt"), options: .atomic)
            }
        }
    }
}
