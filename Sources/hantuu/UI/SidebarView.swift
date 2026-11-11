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

            Rectangle().fill(Color.hDivider).frame(height: 1)
            SidebarFooter()
        }
        .background(Color.hChrome.ignoresSafeArea())
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
                .opacity(hovering || menuOpen ? 1 : 0)
                .allowsHitTesting(hovering || menuOpen)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { model.toggleExpanded(project.id) } }
            .onHover { hovering = $0 }
            .contextMenu { projectMenu }
            .help(project.path)

            if project.expanded {
                let chats = model.unpinnedChats(in: project)
                ForEach(chats) { chat in
                    ChatRow(chat: chat, index: model.globalIndex(of: chat))
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
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
        Divider()
        Button("Remove Project") { model.removeProject(project.id) }
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

            if model.pinnedExpanded {
                ForEach(model.pinnedChats) { chat in
                    ChatRow(chat: chat, index: model.globalIndex(of: chat), showProject: true)
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

    var selected: Bool { model.selectedChatID == chat.id }

    var body: some View {
        HStack(spacing: 9) {
            ActivityDot(activity: chat.activity).frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.displayTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.hText : Color.hText.opacity(chat.activity == .ended ? 0.62 : 0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
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
                    ActivityDetailText(chat: chat)
                }
            }
            Spacer(minLength: 0)
            if let index, index < 9, hovering || selected {
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
        .onTapGesture { model.select(chat.id) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(chat.pinnedAt == nil ? "Pin Chat" : "Unpin Chat") { model.setPinned(chat, chat.pinnedAt == nil) }
            Divider()
            if chat.status == .ended {
                Button(chat.sessionID != nil && chat.agent.resumeArguments(sessionID: "x") != nil ? "Resume" : "Start Again") { model.resume(chat) }
            }
            Button(readerMode.face(of: chat) == .reader ? "Show Terminal" : "Show as Reader") {
                model.select(chat.id)
                ReaderModeMenuTarget.shared.toggle(model: model)
            }
            if let p = chat.transcriptPath {
                Button("Reveal Transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
            }
            Divider()
            Button(chat.status == .ended ? "Remove Chat" : "Close Chat") { model.closeChat(chat) }
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
            else { schedule(open: false, after: showMenu ? 0.9 : 0) }
        }
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            AgentPicker(projectID: projectID) { showMenu = false }
                .environmentObject(model)
                .onHover { h in
                    hoverMenu = h
                    if h { cancel() } else { schedule(open: false, after: 0.35) }
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
            Spacer()
            // No icon here: at the narrowest sidebar width an icon pushed the footer past the edge.
            HStack(spacing: 7) {
                Text("Keep awake")
                    .font(.system(size: 12))
                    .foregroundStyle(keepAwake.isOn ? Color(nsColor: Theme.needsYou) : Color.hSecondary)
                    .lineLimit(1)
                    .fixedSize()
                Toggle("", isOn: Binding(get: { keepAwake.isOn }, set: { _ in keepAwake.toggle() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(keepAwake.busy)
            }
            .help(keepAwake.lastError ?? (keepAwake.isOn
                ? "On: sleep is disabled (pmset disablesleep 1), even with the lid shut"
                : "Keep the Mac running with the lid shut. Asks for your password. With the lid open, hantuu already stops idle sleep while agents work."))
            IconButton(symbol: "gearshape", help: "Settings  ⌘,") { AppDelegate.shared?.showSettings() }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }
}
