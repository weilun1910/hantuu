import SwiftUI

struct ChatNameEditor: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var chat: Chat
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Chat name", text: $text)
            .font(.system(size: 13))
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear { text = chat.displayTitle; focused = true }
            .onSubmit {
                guard AppModel.manualTitle(text) != nil else { return }
                model.renameChat(chat, to: text)
                model.renamingChatID = nil
            }
            .onExitCommand { model.renamingChatID = nil }
            .accessibilityLabel("Rename chat. Return saves. Escape cancels.")
    }
}

struct ChatLaunchDetail: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var chat: Chat
    private var detail: String {
        let target = chat.worktree != nil || chat.requestedWorktree ? "worktree" : "project folder"
        return chat.launchPhase == .preparing ? "Checking \(chat.agent.name) for \(target)" : (chat.launchPhase.label ?? "")
    }
    var body: some View {
        HStack(spacing: 5) {
            if chat.launchPhase.isBusy { ProgressView().controlSize(.mini) }
            Text(detail)
                .font(.system(size: 11)).foregroundStyle(Color.hSecondary).lineLimit(2)
            if case .failed = chat.launchPhase {
                Button("Retry") { model.prepareChat(chat) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                    .accessibilityLabel("Retry \(chat.agent.name) in the same chat")
            }
        }
        .help(detail)
    }
}

struct SidebarHistoryControls: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            Button { model.historyScope = .active; model.historyPresented = true } label: {
                Label("Search chats", systemImage: "magnifyingglass")
                    .font(.system(size: 12)).foregroundStyle(Color.hSecondary)
            }
            .buttonStyle(.plain)
            .help("Switch or search chats  ⌘K")
            Spacer(minLength: 0)
            Menu {
                Button("All History") { model.historyScope = .all; model.historyPresented = true }
                Button("Archived Chats") { model.historyScope = .archived; model.historyPresented = true }
                Menu("Recently Closed") {
                    ForEach(Array(model.archivedChats.prefix(20))) { chat in
                        Button(chat.displayTitle + " - " + (model.project(chat.projectID)?.name ?? chat.agent.name)) { model.restoreChat(chat) }
                    }
                }.disabled(model.archivedChats.isEmpty)
            } label: { Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.hSecondary) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Chat history and recently closed chats")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}

struct ArchiveUndoBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let id = model.lastArchivedID, let chat = model.chats.first(where: { $0.id == id && $0.archivedAt != nil }) {
            HStack(spacing: 6) {
                Text("Chat archived").font(.system(size: 11)).foregroundStyle(Color.hSecondary)
                Spacer(minLength: 0)
                Button("Undo") { model.restoreChat(chat) }.buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                Button { model.lastArchivedID = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss archive notice")
            }.padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}
