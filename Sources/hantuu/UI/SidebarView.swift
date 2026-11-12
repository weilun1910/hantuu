import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            // The traffic lights sit over the left of this strip.
            ZStack {
                WindowDragArea()
                HStack(spacing: 2) {
                    Spacer()
                    NeedsYouButton()
                    IconButton(symbol: "sidebar.left", help: "Hide Sidebar  ⌘0") { model.sidebarVisible = false }
                    IconButton(symbol: "folder.badge.plus", help: "New Project…  ⇧⌘O") { model.addProjectWithPanel() }
                }
                .padding(.trailing, 10)
            }
            .frame(height: 40)

            SidebarHistoryControls()
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !model.pinnedChats.isEmpty {
                        PinnedSection()
                    }
                    ForEach(model.projects) { project in
                        ProjectSection(project: project)
                    }
                    if model.projects.isEmpty {
                        Text("No projects yet")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.hTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            .onChange(of: model.sidebarCursor) { _, target in
                if let target { proxy.scrollTo(target.id, anchor: .center) }
            }
            .onChange(of: model.sidebarRevealRequest) { _, _ in
                DispatchQueue.main.async {
                    if let target = model.sidebarCursor { proxy.scrollTo(target.id, anchor: .center) }
                }
            }
            }
            ArchiveUndoBar()

            Rectangle().fill(Color.hDivider).frame(height: 1)
            SidebarFooter()
        }
        .background(Color.hChrome.ignoresSafeArea())
        .background(SidebarKeyboardCapture(model: model).frame(width: 0, height: 0))
        .sheet(isPresented: $model.historyPresented) {
            ChatHistoryView(model: model, initialScope: model.historyScope) { model.historyPresented = false }
        }
    }
}

struct ProjectSection: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    @State private var hovering = false
    @State private var menuOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.hTertiary)
                    .rotationEffect(.degrees(project.expanded ? 90 : 0))
                    .frame(width: 12)
                Text(project.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.hSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !project.folderExists {
                    Image(systemName: "folder.badge.questionmark").foregroundStyle(Color.hSecondary)
                        .help("Folder missing. Use Locate Folder in the project menu.")
                } else if !project.expanded {
                    let count = model.chats(in: project).count
                    Text("\(count)").font(.system(size: 10)).foregroundStyle(Color.hTertiary)
                    if model.chats(in: project).contains(where: { $0.activity.wantsAttention }) {
                        Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(Color.hSecondary)
                    }
                }
                Spacer(minLength: 4)
                // Always in the hierarchy and only faded out: removing the button when the
                // cursor left the row also dismissed its agent popover before you could reach it.
                Group {
                    NewChatButton(projectID: project.id, compact: true, isOpen: $menuOpen)
                    Menu {
                        projectMenu
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(Color.hSecondary)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .frame(width: 22)
                }
                .opacity(hovering || menuOpen || model.sidebarCursor == .project(project.id) ? 1 : 0)
                .allowsHitTesting(hovering || menuOpen || model.sidebarCursor == .project(project.id))
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { model.toggleExpanded(project.id) } }
            .onHover { hovering = $0 }
            .contextMenu { projectMenu }
            .help(project.path)
            .modifier(SidebarFocusOutline(target: .project(project.id)))

            if project.expanded {
                let chats = model.unpinnedChats(in: project)
                ForEach(chats) { chat in
                    ChatBranch(chat: chat)
                }
                // A project whose only chats are pinned shows nothing here rather than "No chats".
                if model.chats(in: project).isEmpty {
                    Text("No chats")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.hTertiary)
                        .padding(.leading, 22)
                        .frame(height: 22)
                }
            }
        }
    }

    @ViewBuilder var projectMenu: some View {
        Button("New Chat") { model.newChat(agentID: nil, projectID: project.id) }
        Menu("New Chat With") {
            ForEach(model.agents) { a in
                Button(a.name) { model.newChat(agentID: a.id, projectID: project.id) }
            }
        }
        WorktreeMenuItem(project: project)
        Button("New Terminal") {
            model.selectedProjectID = project.id
            model.newTerminalTab()
        }
        Divider()
        if !project.folderExists {
            Button("Locate Folder...") { model.locateProject(project) }
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
        Divider()
        Button("Rename Project...") { model.renameProject(project) }
        if project.alias != nil { Button("Use Folder Name") { model.renameProject(project, reset: true) } }
        Button("Remove Project") { model.removeProject(project.id) }
            .disabled(model.chats(in: project).contains { $0.launchPhase.isBusy })
    }
}

/// Chats pinned from any project, above the projects. Right-click a chat to pin or unpin it.
struct PinnedSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.hTertiary)
                    .rotationEffect(.degrees(model.pinnedExpanded ? 90 : 0))
                    .frame(width: 12)
                Text("Pinned")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.hSecondary)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { model.togglePinnedExpanded() } }
            .modifier(SidebarFocusOutline(target: .pinned))

            if model.pinnedExpanded {
                ForEach(model.pinnedChats) { chat in
                    ChatBranch(chat: chat, showProject: true)
                }
            }
        }
    }
}

/// Both project and pinned sections use the same subagent tree.
struct ChatBranch: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var chat: Chat
    var showProject = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ChatRow(chat: chat, index: model.globalIndex(of: chat), showProject: showProject)
            if model.subagentBrowser.expanded.contains(chat.id) {
                ForEach(model.subagentBrowser.rows(for: chat.id)) { row in
                    SubagentRow(chatID: chat.id, agent: row.agent, depth: row.depth)
                }
            }
        }
    }
}

struct SubagentRow: View {
    @EnvironmentObject var model: AppModel
    let chatID: UUID
    let agent: SidebarSubagent
    let depth: Int
    @State private var hovering = false

    var selected: Bool {
        model.subagentBrowser.selection?.chatID == chatID && model.subagentBrowser.selection?.agent.id == agent.id
    }

    var body: some View {
        Button { model.selectSubagent(agent.id, in: chatID) } label: {
            HStack(spacing: 9) {
                ActivityDot(activity: agent.activity).frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.title).font(.system(size: 12)).foregroundStyle(Color.hText).lineLimit(1)
                    Text(agent.detail).font(.system(size: 11)).foregroundStyle(Color.hTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            // A direct child's dot occupies its parent's title column.
            .padding(.leading, CGFloat(31 + depth * 21))
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.hSelection : (hovering ? Color.hHover : .clear)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(agent.title + "\n" + agent.detail)
        .modifier(SidebarFocusOutline(target: .child(chatID, agent.id)))
        .contextMenu {
            if let path = agent.transcript {
                Button("Reveal Transcript in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        }
    }
}

struct ChatRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var chat: Chat
    /// So the menu's Show as Reader / Show Terminal follows the chat's face.
    @ObservedObject private var readerMode = ReaderMode.shared
    let index: Int?
    /// In Pinned, rows come from every project, so the grey line starts with the project.
    var showProject = false
    @State private var hovering = false

    var selected: Bool { model.selectedChatID == chat.id && model.subagentBrowser.selection == nil }

    var body: some View {
        HStack(spacing: 9) {
            ActivityDot(activity: chat.activity).frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                if model.renamingChatID == chat.id {
                    ChatNameEditor(chat: chat)
                } else {
                    Text(chat.displayTitle)
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? Color.hText : Color.hText.opacity(chat.activity == .ended ? 0.62 : 0.88))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // What the agent is doing: "Wants to run Bash: npm test", "Done 2m ago".
                // A worktree chat's branch comes first (Sessions/).
                HStack(spacing: 6) {
                    if showProject, let p = model.project(chat.projectID) {
                        Text(p.name)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.hTertiary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    WorktreeBranchLabel(chat: chat)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.hTertiary)
                    if chat.launchPhase.label != nil {
                        ChatLaunchDetail(chat: chat)
                    } else {
                        Text(chat.agent.name).font(.system(size: 10)).foregroundStyle(Color.hTertiary).lineLimit(1)
                        if chat.agentID == "codex", chat.status != .ended, chat.sessionID == nil || chat.codexIdentityWaiting {
                            Text("Waiting for session identity").font(.system(size: 11)).foregroundStyle(Color.hTertiary)
                        } else { ActivityDetailText(chat: chat) }
                    }
                }
            }
            Spacer(minLength: 0)
            let count = model.subagentBrowser.count(for: chat.id)
            if count > 0 {
                Button { model.subagentBrowser.toggle(chat.id) } label: {
                    HStack(spacing: 4) {
                        Text("\(count)").font(.system(size: 10.5))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(model.subagentBrowser.expanded.contains(chat.id) ? 90 : 0))
                            .frame(width: 12)
                    }
                    .foregroundStyle(Color.hTertiary)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("\(count) open subagents. Show or hide their chats.")
                .accessibilityLabel("Subagents for \(chat.displayTitle)")
                .accessibilityValue("\(count), " + (model.subagentBrowser.expanded.contains(chat.id) ? "Expanded" : "Collapsed"))
            } else if let index, index < 9, hovering || selected {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.hTertiary)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.hSelection : (hovering ? Color.hHover : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.renamingChatID = chat.id }
        .onTapGesture {
            if model.renamingChatID == chat.id { return }
            if NSEvent.modifierFlags.contains(.option), model.subagentBrowser.count(for: chat.id) > 0 {
                model.subagentBrowser.toggle(chat.id)
            } else { model.select(chat.id) }
        }
        .onHover { hovering = $0 }
        .modifier(SidebarFocusOutline(target: .chat(chat.id)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(chat.displayTitle + ", " + chat.agent.name)
        .accessibilityAction(named: Text("Open chat")) { model.select(chat.id) }
        .accessibilityAction(named: Text("Rename chat")) { model.renamingChatID = chat.id }
        .contextMenu {
            Button("Rename...") { model.renamingChatID = chat.id }
            if chat.userTitle != nil { Button("Reset to Automatic Name") { model.renameChat(chat, to: nil) } }
            Button(chat.manualUnread || chat.activity == .doneUnseen ? "Mark Read" : "Mark Unread") {
                StatusCenter.shared.setRead(chat: chat, read: chat.manualUnread || chat.activity == .doneUnseen)
            }
            Button(chat.pinnedAt == nil ? "Pin Chat" : "Unpin Chat") { model.setPinned(chat, chat.pinnedAt == nil) }
            Divider()
            if chat.status == .ended {
                Button(chat.resumeOnRetry && chat.sessionID != nil && chat.agent.resumeArguments(sessionID: "x") != nil ? "Resume" : "Start Again") { model.resume(chat) }
            }
            Button(readerMode.face(of: chat) == .reader ? "Show Terminal" : "Show as Reader") {
                model.select(chat.id)
                ReaderModeMenuTarget.shared.toggle(model: model)
            }
            if let p = chat.transcriptPath {
                Button("Reveal Transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
            }
            Divider()
            if case .failed = chat.launchPhase {
                Button("Retry Launch or Reconnect") { model.prepareChat(chat) }
                Button("Reveal App Log") { NSWorkspace.shared.activateFileViewerSelecting([Paths.logFile]) }
            }
            if let worktree = chat.worktree, !FileManager.default.fileExists(atPath: worktree.directory) {
                Button("Locate Worktree...") { model.locateWorktree(chat) }
            }
            if chat.status != .ended {
                Button("Stop Agent") { model.stopChat(chat) }.disabled(chat.launchPhase.isBusy)
            }
            Button("Archive Chat") { model.archiveChat(chat) }.disabled(chat.launchPhase.isBusy)
        }
    }
}

extension AppModel {
    func globalIndex(of chat: Chat) -> Int? {
        sidebarOrder.firstIndex(where: { $0.id == chat.id })
    }
}

/// Click: a new chat with the default agent. Hover: a dropdown of every installed agent.
/// The dropdown opens almost at once (a short wait so a cursor passing over doesn't flash it),
/// waits a moment after the cursor leaves the button so there's time to reach it, and stays
/// open while the cursor is on it.
struct NewChatButton: View {
    @EnvironmentObject var model: AppModel
    let projectID: UUID?
    let compact: Bool
    var isOpen: Binding<Bool>? = nil
    @State private var hoverButton = false
    @State private var hoverMenu = false
    @State private var showMenu = false
    @State private var pending: DispatchWorkItem?
    /// How long the cursor rests on the plus before the agent list opens. Was 0.35s.
    static let openDelay = 0.08
    static let leaveButtonDelay = 0.9
    static let leaveMenuDelay = 0.35

    var defaultName: String { model.agents.first(where: { $0.id == model.defaultAgentID })?.name ?? "the default agent" }

    var body: some View {
        Button {
            cancel()
            showMenu = false
            model.newChat(agentID: nil, projectID: projectID)
        } label: {
            Image(systemName: compact ? "plus" : "square.and.pencil")
                .font(.system(size: compact ? 11 : 13, weight: .regular))
                .foregroundStyle(hoverButton ? Color.hText : Color.hSecondary)
                .frame(width: compact ? 20 : 26, height: compact ? 20 : 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(hoverButton ? Color.hHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New chat with \(defaultName)  ⌘N")
        .onHover { h in
            hoverButton = h
            if h { if !showMenu { schedule(open: true, after: NewChatButton.openDelay) } else { cancel() } }
            else { schedule(open: false, after: showMenu ? Self.leaveButtonDelay : 0) }
        }
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            AgentPicker(projectID: projectID) { showMenu = false }
                .environmentObject(model)
                .onHover { h in
                    hoverMenu = h
                    if h { cancel() } else { schedule(open: false, after: Self.leaveMenuDelay) }
                }
        }
        .onChange(of: showMenu) { _, open in
            if !open { hoverMenu = false }
            isOpen?.wrappedValue = open
        }
    }

    private func cancel() { pending?.cancel(); pending = nil }

    private func schedule(open: Bool, after: Double) {
        cancel()
        let w = DispatchWorkItem {
            if open {
                if model.agents.count > 0 { showMenu = true }
            } else if !hoverButton && !hoverMenu {
                showMenu = false
            }
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: w)
    }
}

struct AgentPicker: View {
    @EnvironmentObject var model: AppModel
    let projectID: UUID?
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(projectName)
                .font(.system(size: 11))
                .foregroundStyle(Color.hTertiary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(model.agents) { agent in
                AgentPickerRow(agent: agent, isDefault: agent.id == model.defaultAgentID) {
                    done()
                    model.newChat(agentID: agent.id, projectID: projectID)
                }
            }
            WorktreeToggleRow(projectID: projectID)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .frame(width: 240)
    }

    var projectName: String {
        if let id = projectID, let p = model.project(id) { return "New chat in \(p.name)" }
        if let p = model.currentProject { return "New chat in \(p.name)" }
        return "New chat"
    }
}

struct AgentPickerRow: View {
    let agent: AgentDefinition
    let isDefault: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(agent.name).font(.system(size: 13)).foregroundStyle(Color.hText)
                Spacer()
                if isDefault { Text("Default").font(.system(size: 11)).foregroundStyle(Color.hTertiary) }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.hSelection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct SidebarFooter: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var keepAwake: KeepAwake

    init() { _keepAwake = ObservedObject(wrappedValue: AppModel.shared.keepAwake) }

    var body: some View {
        HStack(spacing: 4) {
            // How much of each agent's weekly limit is left (Usage/). The inset before the
            // rings gives way first, so at the narrowest sidebar everything still fits.
            HStack(spacing: 0) {
                Color.clear.frame(minWidth: 0, idealWidth: 0, maxWidth: 5, maxHeight: 1)
                UsageRings().fixedSize()
            }
            Spacer(minLength: 0)
            // No icon here: at the narrowest sidebar width an icon pushed the footer past the edge.
            KeepAwakeControl(keepAwake: keepAwake)
            IconButton(symbol: "gearshape", help: "Settings  ⌘,") { AppDelegate.shared?.showSettings() }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }
}
