import AppKit
import SwiftUI

extension SelfTest {
    static func sidebarParity(_ dir: URL) {
        let root = dir.appendingPathComponent("sidebar-parity", isDirectory: true)
        Paths.ensure(root)
        for provider in ["claude", "codex", "other"] {
            let model = AppModel()
            let project = Project(path: root.path)
            model.projects = [project]
            let chat = Chat(projectID: project.id, agentID: provider)
            let next = Chat(projectID: project.id, agentID: provider)
            chat.status = .ended
            next.status = .ended
            chat.sessionID = "11111111-1111-4111-8111-111111111111"
            chat.transcriptPath = root.appendingPathComponent(provider + ".jsonl").path
            chat.worktree = WorktreeInfo(repo: root.path, root: root.appendingPathComponent("checkout").path,
                                         directory: root.appendingPathComponent("checkout").path, branch: "hantuu/test")
            chat.pinnedAt = Date(timeIntervalSince1970: 1_800_000_000)
            model.chats = [chat, next]
            model.renameChat(chat, to: "  Review   storage \n recovery ")
            chat.terminalTitle = "Provider changed its title"
            check("sidebar \(provider): manual title survives provider updates", chat.displayTitle == "Review storage recovery")
            model.renameChat(chat, to: " \n ")
            check("sidebar \(provider): empty rename does not erase manual title", chat.userTitle == "Review storage recovery")
            let pin = chat.pinnedAt, worktree = chat.worktree, session = chat.sessionID, transcript = chat.transcriptPath
            model.select(chat.id)
            model.finishArchive(chat, at: Date(timeIntervalSince1970: 1_800_000_100))
            check("sidebar \(provider): archive removes only active row and selects neighbor", model.sidebarOrder.map(\.id) == [next.id] && model.selectedChatID == next.id && model.archivedChats.map(\.id) == [chat.id])
            check("sidebar \(provider): archive preserves native identity and checkout", chat.sessionID == session && chat.transcriptPath == transcript && chat.worktree == worktree && chat.pinnedAt == pin)
            model.reopenLastChat()
            check("sidebar \(provider): reopening restores original pin without launching", model.sidebarOrder.map(\.id) == [chat.id, next.id] && chat.status == .ended && chat.terminal == nil && chat.archivedAt == nil)
            model.renameChat(chat, to: nil)
            check("sidebar \(provider): reset explicitly uses provider title", chat.displayTitle == "Provider changed its title")
            chat.launchPhase = .starting
            let token = chat.launchToken
            model.prepareChat(chat)
            check("sidebar \(provider): duplicate launch request does not start preflight", chat.launchToken == token && chat.launchPhase == .starting)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var saved = SavedState()
        let project = Project(path: root.path)
        saved.projects = [project]
        let id = UUID()
        saved.selectedChatID = id
        saved.chats = [SavedChat(id: id, projectID: project.id, agentID: "codex", sessionID: "22222222-2222-4222-8222-222222222222",
                                title: "Automatic", createdAt: now, userTitle: "My name", archivedAt: now,
                                seenSessionID: "22222222-2222-4222-8222-222222222222", seenThrough: now,
                                seenCompletionKey: "events|120|digest", manualUnread: true, lastSelectedAt: now, requestedWorktree: true)]
        let roundtrip = (try? JSONEncoder.hantuu.encode(saved)).flatMap(SavedState.read)
        check("sidebar: archive, name, selection, read state and launch choice round-trip", roundtrip?.selectedChatID == id && roundtrip?.chats.first?.userTitle == "My name" && roundtrip?.chats.first?.archivedAt == now && roundtrip?.chats.first?.manualUnread == true && roundtrip?.chats.first?.seenCompletionKey == "events|120|digest" && roundtrip?.chats.first?.requestedWorktree == true)
        check("sidebar: lifecycle busy phases exclude retryable failure", ChatLaunchPhase.creatingWorktree.isBusy && ChatLaunchPhase.reconnecting.isBusy && !ChatLaunchPhase.failed("fixture").isBusy && !ChatLaunchPhase.ready.isBusy)

        let model = AppModel()
        var collapsed = Project(path: root.path)
        collapsed.expanded = false
        model.projects = [collapsed]
        model.chats = (0..<12).map { index in
            let chat = Chat(projectID: collapsed.id, agentID: index.isMultiple(of: 2) ? "claude" : "codex")
            chat.status = .ended
            chat.terminalTitle = "Chat \(index + 1)"
            return chat
        }
        let first = model.chats[0], last = model.chats[11]
        model.selectChat(index: 8)
        check("sidebar: numeric shortcut reveals collapsed section", model.selectedChatID == model.chats[8].id && model.projects[0].expanded)
        model.select(last.id)
        model.previousNextChat(1)
        check("sidebar: next chat wraps beyond nine chats", model.selectedChatID == first.id)
        model.previousNextChat(-1)
        check("sidebar: previous chat wraps in stable order", model.selectedChatID == last.id)
        model.projects[0].expanded = false
        check("sidebar: arrow navigation excludes collapsed chats", model.visibleSidebarTargets == [.project(collapsed.id)])
        model.sidebarCursor = .project(collapsed.id)
        _ = model.sidebarKey(124)
        _ = model.sidebarKey(119)
        check("sidebar: right expands and End reaches last visible row", model.sidebarCursor == .chat(last.id))
        _ = model.sidebarKey(115)
        check("sidebar: Home reaches first visible section", model.sidebarCursor == .project(collapsed.id))
        model.select(first.id)
        let child = SidebarSubagent(SubagentInfo(id: "child", title: "Review output"))
        model.updateSubagents([child], for: first.id)
        model.selectSubagent("child", in: first.id)
        model.select(last.id)
        model.navigateHistory(-1)
        check("sidebar: Back restores child view without parent input", model.selectedChatID == first.id && model.subagentBrowser.selection?.agent.id == "child")
        model.navigateHistory(-1)
        check("sidebar: child-to-parent transition has its own history entry", model.selectedChatID == first.id && model.subagentBrowser.selection == nil)
        model.navigateHistory(1)
        check("sidebar: Forward returns to inspected child", model.subagentBrowser.selection?.agent.id == "child")
        model.finishArchive(first)
        first.launchPhase = .preparing
        model.restoreChat(first)
        check("sidebar: restore cannot overlap checkout cleanup", first.archivedAt != nil && first.launchPhase == .preparing)
        first.launchPhase = .ready
        model.navigateHistory(-1)
        check("sidebar: navigation history skips archived targets", model.selectedChatID != first.id)
        let cleanupRepo = root.appendingPathComponent("cleanup-repo", isDirectory: true)
        Paths.ensure(cleanupRepo)
        _ = Worktrees.run(["init", "-q", "-b", "main"], in: cleanupRepo.path)
        _ = Worktrees.run(["-c", "core.hooksPath=/dev/null", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Fixture"], in: cleanupRepo.path)
        let checkout = root.appendingPathComponent("cleanup-checkout")
        let made = Worktrees.run(["-c", "core.hooksPath=/dev/null", "worktree", "add", "-b", "hantuu/fixture", checkout.path], in: cleanupRepo.path)
        if made.code == 0 {
            let info = WorktreeInfo(repo: cleanupRepo.path, root: checkout.path, directory: checkout.path, branch: "hantuu/fixture")
            check("sidebar: cleanup permits verified clean checkout", AppModel.worktreeCleanupProblem(info) == nil)
            try? Data("keep".utf8).write(to: checkout.appendingPathComponent("untracked.txt"))
            check("sidebar: cleanup catches newly dirty checkout", AppModel.worktreeCleanupProblem(info) != nil)
            try? FileManager.default.removeItem(at: checkout.appendingPathComponent("untracked.txt"))
            try? Data("scratch-secret\n".utf8).write(to: cleanupRepo.appendingPathComponent(".git/info/exclude"))
            try? Data("fixture only".utf8).write(to: checkout.appendingPathComponent("scratch-secret"))
            check("sidebar: cleanup preserves ignored local files", AppModel.worktreeCleanupProblem(info) != nil)
            var replaced = info
            replaced.branch = "main"
            check("sidebar: cleanup rejects reused branch identity", AppModel.worktreeCleanupProblem(replaced) != nil)
        } else { check("sidebar: cleanup fixture checkout created", false, made.err) }
        sidebarParitySnapshots(root)
    }

    private static func sidebarParitySnapshots(_ root: URL) {
        let model = AppModel()
        let project = Project(path: root.path)
        model.projects = [project]
        let names = ["Review the storage change", "Create isolated checkout", "Reconnect saved session", "Launch needs attention"]
        let phases: [ChatLaunchPhase] = [.ready, .creatingWorktree, .reconnecting, .failed("Codex was not found. Install it, then retry.")]
        model.chats = zip(names, phases).enumerated().map { index, pair in
            let chat = Chat(projectID: project.id, agentID: index.isMultiple(of: 2) ? "claude" : "codex")
            chat.terminalTitle = pair.0
            chat.launchPhase = pair.1
            chat.status = .ended
            return chat
        }
        let archived = Chat(projectID: project.id, agentID: "codex")
        archived.terminalTitle = "Earlier investigation"
        archived.status = .ended
        archived.archivedAt = Date()
        model.chats.append(archived)
        model.lastArchivedID = archived.id
        model.sidebarKeyboardFocus = true
        model.sidebarCursor = .chat(model.chats[0].id)
        let window = makeWindow()
        defer { window.close() }
        func capture<V: View>(_ content: V, name: String, dark: Bool, height: CGFloat) {
            let host = NSHostingView(rootView: content.environmentObject(model)
                .environment(\.colorScheme, dark ? .dark : .light).frame(width: 330, height: height).background(Color.hChrome))
            host.sizingOptions = []
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 330, height: height)
            window.contentView?.addSubview(host)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            check("sidebar snapshot: \(name)", render(host, to: root.appendingPathComponent(name + ".png")))
            host.removeFromSuperview()
        }
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            capture(VStack(spacing: 8) {
                SidebarHistoryControls()
                ProjectSection(project: project)
                ArchiveUndoBar()
                Spacer()
            }.padding(8), name: "sidebar-lifecycle-navigation-\(theme)", dark: dark, height: 370)
            model.renamingChatID = model.chats[0].id
            capture(ChatRow(chat: model.chats[0], index: 0).padding(8), name: "sidebar-rename-\(theme)", dark: dark, height: 75)
            model.renamingChatID = nil
            let waiting = Chat(projectID: project.id, agentID: "codex")
            waiting.terminalTitle = "Switching saved session"
            waiting.codexTitleIdentity.waiting = true
            capture(ChatRow(chat: waiting, index: nil).padding(8), name: "sidebar-session-identity-\(theme)", dark: dark, height: 90)
            capture(ProjectSection(project: Project(path: root.appendingPathComponent("Disconnected folder").path)).padding(8), name: "sidebar-missing-folder-\(theme)", dark: dark, height: 85)
        }
    }
}
