import AppKit
import SwiftUI

/// The "In a new worktree" switch under the agents in the new-chat popover. Remembered per
/// project, and only shown for projects in a git repo.
struct WorktreeToggleRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings = SessionSettings.shared
    let projectID: UUID?

    var project: Project? { projectID.flatMap { model.project($0) } ?? model.currentProject }

    var body: some View {
        if let p = project, settings.isGitRepo(p.id) {
            VStack(spacing: 0) {
                Rectangle().fill(Color.hDivider).frame(height: 1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.hSecondary)
                        .frame(width: 13)
                    Text("In a new worktree")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.hSecondary)
                    Spacer()
                    Toggle("", isOn: Binding(get: { settings.usesWorktree(p.id) },
                                             set: { settings.setUsesWorktree(p.id, $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .help("New chats in \(p.name) get their own git worktree and branch, so parallel chats don't step on each other")
            }
        }
    }
}

/// "New Chat in Worktree" in a project's menu, for projects in a git repo.
struct WorktreeMenuItem: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings = SessionSettings.shared
    let project: Project

    var body: some View {
        if settings.isGitRepo(project.id) {
            Button("New Chat in Worktree") { model.newChat(agentID: nil, projectID: project.id, worktree: true) }
        }
    }
}

/// The branch a worktree chat is on, in small grey type with a branch symbol. Takes its font
/// and colour from where it's placed.
struct WorktreeBranchLabel: View {
    @ObservedObject var chat: Chat

    var body: some View {
        if let wt = chat.worktree {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch").imageScale(.small)
                Text(wt.branch)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .help(wt.root)
        }
    }
}

/// The Sessions section of Settings.
struct SessionSettingsSection: View {
    @ObservedObject var settings = SessionSettings.shared

    var body: some View {
        Section {
            Toggle("Keep agents running after hantuu quits", isOn: $settings.keepAgentsRunning)
        } header: {
            Text("Sessions")
        } footer: {
            Text(settings.keepAgentsRunning
                 ? "Agents keep working when hantuu quits or crashes, and their chats pick up where they are next time it opens. Closing a chat still stops its agent."
                 : "Quitting hantuu stops every agent, after asking. Chats can be resumed next time.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// "New Chat in Worktree" in the File menu (Shift-Cmd-N). Enabled when the current project is
/// in a git repo.
final class SessionMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = SessionMenuTarget()

    static func newChatInWorktreeItem() -> NSMenuItem {
        let it = NSMenuItem(title: "New Chat in Worktree", action: #selector(newChatInWorktree(_:)), keyEquivalent: "n")
        it.keyEquivalentModifierMask = [.command, .shift]
        it.target = shared
        return it
    }

    @objc func newChatInWorktree(_ sender: Any?) {
        AppModel.shared.newChat(agentID: nil, projectID: nil, worktree: true)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let p = AppModel.shared.currentProject else { return false }
        return SessionSettings.shared.isGitRepo(p.id)
    }
}

/// Alerts for worktree chats.
enum WorktreePrompt {
    enum CloseChoice: Equatable {
        case cancel
        case keepWorktree
        /// `force` when the user ticked the box despite uncommitted changes or unmerged commits.
        case deleteWorktree(force: Bool)
    }

    /// The close alert for a worktree chat, with a checkbox for deleting the worktree and its
    /// branch. The checkbox starts off when that would lose work.
    static func closeAlert(agentName: String, worktree wt: WorktreeInfo, running: Bool, dirty: Bool, unmerged: Int) -> (NSAlert, NSButton) {
        let a = NSAlert()
        a.messageText = running ? "Close this chat?" : "Remove this chat?"
        var lines: [String] = []
        if running { lines.append("\(agentName) is still running. Closing the chat stops it.") }
        lines.append("It works in its own worktree on the branch \(wt.branch).")
        if dirty { lines.append("The worktree has uncommitted changes.") }
        if unmerged > 0 { lines.append("The branch has \(unmerged) commit\(unmerged == 1 ? "" : "s") that aren't on any other branch.") }
        a.informativeText = lines.joined(separator: " ")
        let box = NSButton(checkboxWithTitle: "Also delete the worktree and its branch", target: nil, action: nil)
        box.state = dirty || unmerged > 0 ? .off : .on
        box.sizeToFit()
        a.accessoryView = box
        a.addButton(withTitle: running ? "Close" : "Remove")
        a.addButton(withTitle: "Cancel")
        return (a, box)
    }

    static func confirmClose(agentName: String, worktree wt: WorktreeInfo, running: Bool) -> CloseChoice {
        let dirty = Worktrees.isDirty(wt)
        let unmerged = Worktrees.unmergedCommits(wt)
        let (a, box) = closeAlert(agentName: agentName, worktree: wt, running: running, dirty: dirty, unmerged: unmerged)
        guard a.runModal() == .alertFirstButtonReturn else { return .cancel }
        return box.state == .on ? .deleteWorktree(force: dirty || unmerged > 0) : .keepWorktree
    }

    static func showCreateFailed(_ error: Error, project: String) {
        let a = NSAlert()
        a.messageText = "Couldn't make a worktree in \(project)"
        a.informativeText = error.localizedDescription
        a.runModal()
    }

    static func showMissing(_ wt: WorktreeInfo) {
        let a = NSAlert()
        a.messageText = "This chat's worktree is gone"
        a.informativeText = "\(wt.root) no longer exists, so the chat can't start there again."
        a.runModal()
    }

    static func report(_ result: Worktrees.RemoveResult, _ wt: WorktreeInfo) {
        switch result {
        case .removed, .dirty: return
        case .removedKeptBranch:
            Log.write("worktree removed, branch kept: \(wt.branch)")
        case .failed(let message):
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = "Couldn't delete the worktree"
                a.informativeText = "\(wt.root)\n\n\(message)"
                a.runModal()
            }
        }
    }
}
