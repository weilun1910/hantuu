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
                    IconButton(symbol: "sidebar.left", help: "Hide Sidebar  ⌘0") { model.sidebarVisible = false }
                    NewChatButton(projectID: nil, compact: false)
                }
                .padding(.trailing, 10)
            }
            .frame(height: 40)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
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
                let chats = model.chats(in: project)
                ForEach(chats) { chat in
                    ChatRow(chat: chat, index: model.globalIndex(of: chat))
                }
                if chats.isEmpty {
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

struct ChatRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var chat: Chat
    let index: Int?
    @State private var hovering = false

    var selected: Bool { model.selectedChatID == chat.id }

    var body: some View {
        HStack(spacing: 9) {
            StatusDot(status: chat.status).frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.displayTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.hText : Color.hText.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(chat.agent.name)
                    if chat.status == .needsYou {
                        Text("Needs you").foregroundStyle(Color(nsColor: Theme.needsYou))
                    } else if chat.status == .ended {
                        Text("Ended")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.hTertiary)
                .lineLimit(1)
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
            if chat.status == .ended {
                Button(chat.sessionID != nil && chat.agent.resumeArguments(sessionID: "x") != nil ? "Resume" : "Start Again") { model.resume(chat) }
            }
            Button("Show Reader") {
                model.select(chat.id)
                model.panelTab = .reader
                model.panelVisible = true
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
        let ordered = projects.flatMap { p in chats.filter { $0.projectID == p.id } }
        return ordered.firstIndex(where: { $0.id == chat.id })
    }
}

/// Click: a new chat with the default agent. Hover: a dropdown of every installed agent.
/// The dropdown waits a moment after the cursor leaves the button, so there's time to reach it,
/// and stays open while the cursor is on it.
struct NewChatButton: View {
    @EnvironmentObject var model: AppModel
    let projectID: UUID?
    let compact: Bool
    var isOpen: Binding<Bool>? = nil
    @State private var hoverButton = false
    @State private var hoverMenu = false
    @State private var showMenu = false
    @State private var pending: DispatchWorkItem?

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
            if h { if !showMenu { schedule(open: true, after: 0.35) } else { cancel() } }
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
        .help(agent.path ?? agent.id)
    }
}

struct SidebarFooter: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var keepAwake: KeepAwake

    init() { _keepAwake = ObservedObject(wrappedValue: AppModel.shared.keepAwake) }

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "folder.badge.plus", help: "Add Project…  ⇧⌘O") { model.addProjectWithPanel() }
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
                : "Keep the Mac running with the lid shut. Asks for your password."))
            IconButton(symbol: "gearshape", help: "Settings  ⌘,") { AppDelegate.shared?.showSettings() }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }
}
