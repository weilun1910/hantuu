import SwiftUI
import AppKit

struct ChatHistoryView: View {
    @ObservedObject var model: AppModel
    @StateObject private var store = ChatHistoryStore()
    @State private var query = ""
    @State private var scope: ChatHistoryScope
    @State private var location: ChatHistoryLocation = .all
    @State private var fullHistory: Bool
    @State private var native = false
    @State private var selected: String?
    var onClose: () -> Void

    init(model: AppModel, initialScope: ChatHistoryScope = .active, onClose: @escaping () -> Void) {
        self.model = model; self.onClose = onClose
        _scope = State(initialValue: initialScope)
        _fullHistory = State(initialValue: initialScope != .active)
    }

    private var chosen: ChatHistoryHit? { store.result.hits.first { $0.id == selected } }
    private var currentFolder: String? { model.selectedProjectID.flatMap { id in model.projects.first { $0.id == id }?.path } }
    var body: some View {
        VStack(spacing: 0) {
            ChatHistoryHeader(query: $query, scope: $scope, location: $location, fullHistory: $fullHistory,
                              native: $native, loading: store.loading, onClose: onClose, onSubmit: activate)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("\(store.result.hits.count) results").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh", action: refresh).font(.caption)
                    }.padding(12)
                    if store.result.hits.isEmpty {
                        ChatHistoryEmpty(loading: store.loading)
                    } else {
                        List(selection: $selected) {
                            ForEach(store.result.hits) { hit in
                                ChatHistoryRow(hit: hit).tag(hit.id).contextMenu {
                                    if let id = hit.record.localChatID, let chat = model.archivedChats.first(where: { $0.id == id }) {
                                        Button("Restore") { model.restoreChat(chat); refresh() }
                                        if chat.worktree != nil { Button("Clean Up Worktree...") { model.cleanupArchivedWorktree(chat) } }
                                        Button("Remove hantuu record", role: .destructive) { model.removeArchivedRecord(chat); refresh() }
                                    }
                                }
                            }
                        }.listStyle(.inset)
                    }
                }.frame(minWidth: 280, idealWidth: 340)
                if fullHistory {
                    ChatHistoryPreview(hit: chosen).frame(minWidth: 370)
                }
            }
            if store.result.partial {
                Text("Partial index: up to 500 files and 32 MB per pass. Refresh continues larger transcripts. Search reads complete records incrementally. Previews retain 80 recent messages plus the first match.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 8)
            }
            ForEach(store.result.warnings, id: \.self) { warning in Text(warning).font(.caption).foregroundStyle(.orange).padding(.horizontal, 20) }
            Divider().padding(.top, 8)
            HStack {
                Text(fullHistory ? "Preview is read-only. Provider history is never changed." : "Return focuses the selected chat. Arrow keys move through results.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let hit = chosen {
                    if let id = hit.record.localChatID {
                        Button(hit.record.archived ? "Restore and focus" : "Focus existing") { focus(id) }.keyboardShortcut(.defaultAction)
                        if let chat = model.chats.first(where: { $0.id == id }), chat.status == .ended, chat.sessionID != nil {
                            Button("Resume saved session") {
                                if chat.archivedAt != nil { model.restoreChat(chat) }
                                model.resume(chat); onClose()
                            }
                        }
                    } else {
                        Button("Open read-only") { fullHistory = true }
                        Button("Resume saved session") {
                            if model.importHistory(hit.record, resume: true) { onClose() }
                        }.disabled(!hit.record.identityVerified || hit.record.providerArchived || hit.record.cwd.isEmpty || hit.record.issue != nil)
                    }
                }
            }.padding(16)
        }
        .frame(width: fullHistory ? 940 : 620, height: 620)
        .background(HistoryArrowKeys { delta in moveResult(delta) }.frame(width: 0, height: 0))
        .onAppear { refresh() }
        .onDisappear { store.cancel() }
        .onChange(of: query) { _ in refresh() }
        .onChange(of: scope) { _ in refresh() }
        .onChange(of: location) { _ in refresh() }
        .onChange(of: native) { _ in refresh() }
        .onChange(of: fullHistory) { enabled in if !enabled { native = false }; refresh() }
        .onChange(of: store.result.hits.map(\.id)) { ids in
            if selected == nil || !ids.contains(selected!) { selected = ids.first }
        }
        .onMoveCommand { direction in
            guard direction == .up || direction == .down else { return }
            moveResult(direction == .down ? 1 : -1)
        }
    }
    private func moveResult(_ delta: Int) {
        let ids = store.result.hits.map(\.id)
        guard !ids.isEmpty else { return }
        let index = ids.firstIndex(of: selected ?? "") ?? 0
        selected = ids[max(0, min(ids.count - 1, index + delta))]
    }
    private func activate() {
        if let id = chosen?.record.localChatID { focus(id) }
        else { fullHistory = true }
    }
    private func focus(_ id: UUID) {
        if let chat = model.archivedChats.first(where: { $0.id == id }) { model.restoreChat(chat) }
        model.select(id); onClose()
    }
    private func refresh() {
        let records = model.chats.map { chat in
            ChatHistoryRecord(localChatID: chat.id, agentID: chat.agentID, sessionID: chat.sessionID,
                              title: chat.displayTitle, cwd: model.workingDirectory(of: chat), transcriptPath: chat.transcriptPath,
                              branch: chat.worktree?.branch, projectName: model.projects.first { $0.id == chat.projectID }?.name, status: chat.activity.rawValue + " " + chat.activityDetail,
                              archived: chat.archivedAt != nil, modifiedAt: chat.lastSelectedAt ?? chat.lastTurnEndedAt ?? chat.createdAt)
        }
        store.search(records: records, query: query, scope: scope, location: location, folder: currentFolder, native: native && fullHistory, fullText: fullHistory)
    }
}

struct ChatHistoryRow: View {
    let hit: ChatHistoryHit
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(hit.record.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
            Text("\(hit.record.agentID.capitalized) | \((hit.record.cwd as NSString).lastPathComponent)\(hit.record.archived ? " | Archived" : "")")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let branch = hit.record.branch { Text(branch).font(.caption2).foregroundStyle(.secondary) }
            if !hit.snippet.isEmpty { Text(hit.snippet).font(.caption).lineLimit(3) }
            if let issue = hit.record.issue { Text(issue).font(.caption).foregroundStyle(.orange).lineLimit(2) }
        }.padding(.vertical, 5).help(hit.record.cwd)
    }
}

/// Standalone value-based view supports snapshots without AppModel or provider sessions.
struct ChatHistoryPreview: View {
    var hit: ChatHistoryHit?
    var body: some View {
        Group {
            if let hit {
                VStack(alignment: .leading, spacing: 10) {
                    Text(hit.record.title).font(.headline)
                    Text(hit.record.cwd).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if hit.record.providerArchived { Text("Archived by Codex. Open it in Codex to restore before resuming here.").font(.caption).foregroundStyle(.secondary) }
                    if let issue = hit.record.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
                    Text("Preview shows recent messages and the first search match. Long messages are shortened.").font(.caption2).foregroundStyle(.secondary)
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                if hit.entries.isEmpty { Text("No indexed messages available. Refresh to retry reading this transcript.").foregroundStyle(.secondary) }
                                ForEach(Array(hit.entries.enumerated()), id: \.offset) { _, entry in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(entry.kind.rawValue.capitalized).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        Text(entry.text).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }.padding(10).background(entry.id == hit.matchedMessageID ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6)).id(entry.id)
                                }
                            }
                        }
                        .onAppear { if let id = hit.matchedMessageID { proxy.scrollTo(id, anchor: .top) } }
                        .onChange(of: hit.id + (hit.matchedMessageID ?? "")) { _ in if let id = hit.matchedMessageID { proxy.scrollTo(id, anchor: .top) } }
                    }
                }.padding(16)
            } else {
                Text("Select a chat to preview its messages.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Value-only controls are shared by the live sheet and isolated rendering fixtures.
struct ChatHistoryHeader: View {
    @Binding var query: String
    @Binding var scope: ChatHistoryScope
    @Binding var location: ChatHistoryLocation
    @Binding var fullHistory: Bool
    @Binding var native: Bool
    var loading: Bool
    var onClose: () -> Void
    var onSubmit: () -> Void
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(fullHistory ? "Chat history" : "Switch chat").font(.title2.weight(.semibold))
                Spacer()
                Toggle("Full history", isOn: $fullHistory).toggleStyle(.switch).controlSize(.small)
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            }.padding(20)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(fullHistory ? "Search titles, folders and messages" : "Search titles, folders, agents and status", text: $query)
                    .textFieldStyle(.plain).focused($searchFocused).onSubmit(onSubmit)
                if loading { ProgressView().controlSize(.small) }
            }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 20)
            HStack {
                Picker("History scope", selection: $scope) { ForEach(ChatHistoryScope.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 150)
                Picker("Location", selection: $location) { ForEach(ChatHistoryLocation.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 170)
                Spacer()
                if fullHistory { Toggle("Include native Claude and Codex history", isOn: $native).toggleStyle(.checkbox).font(.caption) }
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }.onAppear { searchFocused = true }
    }
}

struct ChatHistoryEmpty: View {
    var loading: Bool
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: loading ? "clock" : "magnifyingglass").font(.title)
            Text(loading ? "Searching history..." : "No matching chats")
            Text("Try another phrase or a broader scope.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


/// Arrow navigation also works while the native search field owns the insertion point.
private struct HistoryArrowKeys: NSViewRepresentable {
    var move: (Int) -> Void
    func makeNSView(context: Context) -> HistoryArrowView { HistoryArrowView(move: move) }
    func updateNSView(_ view: HistoryArrowView, context: Context) { view.move = move }
}

private final class HistoryArrowView: NSView {
    var move: (Int) -> Void
    private var monitor: Any?
    init(move: @escaping (Int) -> Void) {
        self.move = move
        super.init(frame: .zero)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  !self.isHiddenOrHasHiddenAncestor,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  event.keyCode == 125 || event.keyCode == 126 else { return event }
            self.move(event.keyCode == 125 ? 1 : -1)
            return nil
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
