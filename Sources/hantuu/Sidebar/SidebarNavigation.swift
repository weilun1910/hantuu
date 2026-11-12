import AppKit
import SwiftUI

/// Sidebar focus follows only rendered rows. Positional shortcuts keep their established
/// full-chat order and reveal the target's section when used.
enum SidebarTarget: Hashable, Identifiable {
    case pinned, project(UUID), chat(UUID), child(UUID, String)
    var id: String {
        switch self {
        case .pinned: return "pinned"
        case .project(let id): return "project-\(id)"
        case .chat(let id): return "chat-\(id)"
        case .child(let chat, let child): return "child-\(chat)-\(child)"
        }
    }
}

struct ChatDestination: Equatable {
    var chatID: UUID
    var child: SubagentBrowser.Selection?
}

struct ChatNavigation {
    private(set) var entries: [ChatDestination] = []
    private(set) var index = -1
    var restoring = false

    mutating func visit(_ destination: ChatDestination) {
        guard !restoring, index < 0 || entries[index] != destination else { return }
        entries = Array(entries.prefix(index + 1))
        entries.append(destination)
        if entries.count > 100 { entries.removeFirst() }
        index = entries.count - 1
    }

    mutating func move(_ delta: Int, valid: (UUID) -> Bool) -> ChatDestination? {
        var next = index + delta
        while entries.indices.contains(next) {
            if valid(entries[next].chatID) { index = next; return entries[next] }
            next += delta
        }
        return nil
    }
}

extension AppModel {
    var visibleSidebarTargets: [SidebarTarget] {
        var result: [SidebarTarget] = []
        func append(_ chat: Chat) {
            result.append(.chat(chat.id))
            if subagentBrowser.expanded.contains(chat.id) {
                result += subagentBrowser.rows(for: chat.id).map { .child(chat.id, $0.id) }
            }
        }
        if !pinnedChats.isEmpty {
            result.append(.pinned)
            if pinnedExpanded { pinnedChats.forEach(append) }
        }
        for project in projects {
            result.append(.project(project.id))
            if project.expanded { unpinnedChats(in: project).forEach(append) }
        }
        return result
    }

    func revealChat(_ chat: Chat) {
        sidebarRevealRequest += 1
        if chat.pinnedAt != nil { pinnedExpanded = true }
        else if let index = projects.firstIndex(where: { $0.id == chat.projectID }), !projects[index].expanded {
            projects[index].expanded = true
        }
    }

    func previousNextChat(_ delta: Int) {
        let order = sidebarOrder
        guard !order.isEmpty else { return }
        let index = order.firstIndex { $0.id == selectedChatID } ?? (delta > 0 ? -1 : 0)
        select(order[(index + delta + order.count) % order.count].id)
    }

    func focusSidebar() {
        sidebarVisible = true
        if let chat = selectedChat { revealChat(chat) }
        let childTarget: SidebarTarget? = subagentBrowser.selection.map { .child($0.chatID, $0.agent.id) }
        if let childTarget, visibleSidebarTargets.contains(childTarget) { sidebarCursor = childTarget }
        else { sidebarCursor = selectedChatID.map { .chat($0) } ?? visibleSidebarTargets.first }
        sidebarKeyboardFocus = true
    }

    func focusConversation() {
        sidebarKeyboardFocus = false
        if let controller = AppDelegate.shared?.windowController, controller.model === self {
            controller.mainArea.focusVisibleConversation()
        } else if let terminal = selectedChat?.terminal { focusRequest.send(terminal) }
        else { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    func sidebarKey(_ code: UInt16) -> Bool {
        let rows = visibleSidebarTargets
        guard !rows.isEmpty else {
            if code == 53 { focusConversation(); return true }
            return false
        }
        let index = sidebarCursor.flatMap { rows.firstIndex(of: $0) } ?? 0
        switch code {
        case 125: sidebarCursor = rows[min(index + 1, rows.count - 1)]
        case 126: sidebarCursor = rows[max(index - 1, 0)]
        case 115: sidebarCursor = rows.first
        case 119: sidebarCursor = rows.last
        case 123, 124:
            let expand = code == 124
            switch rows[index] {
            case .pinned: pinnedExpanded = expand
            case .project(let id):
                if let i = projects.firstIndex(where: { $0.id == id }) { projects[i].expanded = expand }
            case .chat(let id):
                if subagentBrowser.count(for: id) > 0, subagentBrowser.expanded.contains(id) != expand { subagentBrowser.toggle(id) }
                else if !expand, let chat = chats.first(where: { $0.id == id }) { sidebarCursor = chat.pinnedAt == nil ? .project(chat.projectID) : .pinned }
            case .child(let id, _): sidebarCursor = .chat(id)
            }
            scheduleSave()
        case 36, 76:
            activateSidebarTarget(rows[index])
            focusConversation()
        case 53: focusConversation()
        default: return false
        }
        return true
    }

    func activateSidebarTarget(_ target: SidebarTarget) {
        switch target {
        case .pinned: togglePinnedExpanded()
        case .project(let id): toggleExpanded(id)
        case .chat(let id): select(id, focus: false)
        case .child(let id, let child): selectSubagent(child, in: id)
        }
    }

    func recordNavigationBeforeLeaving() { recordNavigationDestination() }
    func recordNavigationDestination() {
        if let id = selectedChatID { navigation.visit(ChatDestination(chatID: id, child: subagentBrowser.selection)) }
    }

    func navigateHistory(_ delta: Int) {
        let available = Set(chats.filter { $0.archivedAt == nil }.map(\.id))
        guard let destination = navigation.move(delta, valid: { available.contains($0) }) else { return }
        navigation.restoring = true
        if let child = destination.child {
            subagentBrowser.selection = child
            selectedChatID = destination.chatID
            selectedProjectID = selectedChat?.projectID
            if let chat = selectedChat { revealChat(chat) }
            sidebarCursor = .child(destination.chatID, child.agent.id)
        } else { select(destination.chatID) }
        navigation.restoring = false
        StatusCenter.shared.refreshVisibleConversation()
    }
}

/// An explicit responder keeps arrow keys out of the hidden parent terminal. It only
/// claims focus after Focus Sidebar, never when a background status redraws the sidebar.
struct SidebarKeyboardCapture: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeNSView(context: Context) -> SidebarKeyView { SidebarKeyView(model: model) }
    func updateNSView(_ view: SidebarKeyView, context: Context) {
        if model.sidebarKeyboardFocus, view.window?.firstResponder !== view {
            DispatchQueue.main.async {
                guard model.sidebarKeyboardFocus else { return }
                view.window?.makeFirstResponder(view)
            }
        }
    }
}

final class SidebarKeyView: NSView {
    weak var model: AppModel?
    init(model: AppModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool {
        model?.sidebarKeyboardFocus = false
        return true
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           model?.sidebarKey(event.keyCode) == true { return }
        super.keyDown(with: event)
    }
}

struct SidebarFocusOutline: ViewModifier {
    @EnvironmentObject var model: AppModel
    let target: SidebarTarget
    func body(content: Content) -> some View {
        content.id(target.id).overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(model.sidebarKeyboardFocus && model.sidebarCursor == target ? Color.hSecondary : .clear, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}
