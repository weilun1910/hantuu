import Foundation

/// The sidebar keeps only the small part of an agent's work needed to browse its chat.
struct SidebarSubagent: Equatable, Identifiable {
    var id: String
    var parentID: String?
    var title: String
    var state: WorkState
    var step: String?
    var transcript: String?

    init(_ agent: SubagentInfo) {
        id = agent.id
        parentID = agent.parentID
        title = agent.title
        state = agent.state
        step = agent.step
        transcript = agent.transcript
    }

    var detail: String {
        if !state.isActive { return state == .done ? "Finished" : "Finished - \(state.rawValue.capitalized)" }
        return step ?? (state == .waiting ? "Waiting on subagents" : "Working")
    }

    var activity: AgentActivity { state.isActive ? (state == .waiting ? .background : .working) : .idle }
}

/// Session-only navigation. A subagent never enters the saved chat list or shortcut order.
struct SubagentBrowser: Equatable {
    struct Selection: Equatable {
        var chatID: UUID
        var agent: SidebarSubagent
    }

    struct Row: Identifiable {
        var agent: SidebarSubagent
        var depth: Int
        var id: String { agent.id }
    }

    private(set) var open: [UUID: [SidebarSubagent]] = [:]
    private(set) var expanded: Set<UUID> = []
    var selection: Selection?

    func count(for chatID: UUID) -> Int { open[chatID]?.count ?? 0 }

    mutating func toggle(_ chatID: UUID) {
        guard count(for: chatID) > 0 else { return }
        if !expanded.insert(chatID).inserted { expanded.remove(chatID) }
    }

    mutating func update(_ agents: [SidebarSubagent], for chatID: UUID) {
        let live = agents.filter { $0.state.isActive }
        open[chatID] = live.isEmpty ? nil : live
        if live.isEmpty { expanded.remove(chatID) }
        if var selected = selection, selected.chatID == chatID {
            if let current = agents.first(where: { $0.id == selected.agent.id }) {
                var current = current
                if current.transcript == nil { current.transcript = selected.agent.transcript }
                selected.agent = current
            } else if selected.agent.state.isActive {
                selected.agent.state = .stopped
                selected.agent.step = nil
            }
            selection = selected
        }
    }

    mutating func select(_ agentID: String, in chatID: UUID) {
        guard let agent = open[chatID]?.first(where: { $0.id == agentID }) else { return }
        expanded.insert(chatID)
        selection = Selection(chatID: chatID, agent: agent)
    }

    mutating func forget(_ chatID: UUID) {
        open[chatID] = nil
        expanded.remove(chatID)
        if selection?.chatID == chatID { selection = nil }
    }

    /// Flatten the tree in launch order. Orphans stay visible and cycles cannot recurse.
    func rows(for chatID: UUID) -> [Row] {
        let agents = open[chatID] ?? []
        let ids = Set(agents.map(\.id))
        var seen = Set<String>()
        var result: [Row] = []
        func visit(_ agent: SidebarSubagent, depth: Int) {
            guard seen.insert(agent.id).inserted else { return }
            result.append(Row(agent: agent, depth: depth))
            for child in agents where child.parentID == agent.id { visit(child, depth: depth + 1) }
        }
        for agent in agents where agent.parentID == nil || !ids.contains(agent.parentID!) { visit(agent, depth: 0) }
        for agent in agents where !seen.contains(agent.id) { visit(agent, depth: 0) }
        return result
    }
}

extension AppModel {
    func updateSubagents(_ agents: [SidebarSubagent], for chatID: UUID) {
        guard chats.contains(where: { $0.id == chatID }) else { return }
        var next = subagentBrowser
        next.update(agents, for: chatID)
        if next != subagentBrowser { subagentBrowser = next }
    }

    func selectSubagent(_ agentID: String, in chatID: UUID) {
        guard chats.contains(where: { $0.id == chatID }),
              subagentBrowser.open[chatID]?.contains(where: { $0.id == agentID }) == true else { return }
        // Install the child selection first, so status never acknowledges the hidden parent.
        recordNavigationBeforeLeaving()
        subagentBrowser.select(agentID, in: chatID)
        selectedChatID = chatID
        selectedProjectID = selectedChat?.projectID
        if let chat = selectedChat { chat.lastSelectedAt = Date(); revealChat(chat) }
        sidebarCursor = .child(chatID, agentID)
        recordNavigationDestination()
        StatusCenter.shared.refreshVisibleConversation()
    }

    @discardableResult
    func backFromSubagent() -> Bool {
        guard let selected = subagentBrowser.selection else { return false }
        select(selected.chatID)
        return true
    }
}
