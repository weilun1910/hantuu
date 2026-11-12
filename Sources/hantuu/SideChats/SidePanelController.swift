import AppKit
import Combine
import SwiftUI

final class SidePanelState: ObservableObject {
    @Published var chatID: UUID?
    @Published var agent = ""
    @Published var native: [NativeSideChat] = []
    @Published var selection = ""
    @Published var drafts: [UUID: String] = [:]
    @Published var focusGeneration = 0
    var ask: (() -> Void)?
    var select: (() -> Void)?
}

final class SidePanelController {
    let root = FillView(color: Theme.background)
    let reader: ReaderController
    let state = SidePanelState()
    private let model: AppModel
    private let store: SideChatStore
    private let index: NativeSideChatIndex
    private let queue = DispatchQueue(label: "hantuu.side-rollouts", qos: .utility)
    private var bag = Set<AnyCancellable>()
    private var timer: Timer?
    private var follower: TranscriptFollower?
    private var followedID: String?
    private var session: String?
    private var scanning = false
    private var active = false
    private var lastScan = Date.distantPast

    init(model: AppModel, store: SideChatStore? = nil, codexRoot: URL = Paths.codexSessions) {
        self.model = model
        self.store = store ?? model.sideChats
        index = NativeSideChatIndex(root: codexRoot)
        reader = ReaderController(model: model, identifier: "hantuu.side-reader", observesSelection: false)
        let host = ChromeHostingView(rootView: SidePanelContent(state: state, store: self.store, reader: reader.view))
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: root.topAnchor),
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        self.store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.render() }.store(in: &bag)
        self.store.showQuestions.receive(on: DispatchQueue.main).sink { [weak self] id in
            guard let self, self.model.selectedChat?.id == id else { return }
            self.state.selection = ""
            self.state.focusGeneration += 1
            self.render()
        }.store(in: &bag)
        state.ask = { [weak self] in self?.ask() }
        state.select = { [weak self] in self?.render() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.active else { return }
            self.sync(active: true)
        }
    }

    deinit { timer?.invalidate(); follower?.stop() }

    func sync(active: Bool) {
        self.active = active
        guard active else { follower?.stop(); follower = nil; followedID = nil; return }
        let chat = model.selectedChat
        if state.chatID != chat?.id || session != chat?.sessionID {
            state.chatID = chat?.id
            state.agent = chat?.agentID ?? ""
            session = chat?.sessionID
            state.native = []
            state.selection = ""
            follower?.stop()
            follower = nil
            followedID = nil
            lastScan = .distantPast
            if let chat { store.load(chat.id) }
        }
        render()
        guard chat?.agentID == "codex", let parent = chat?.sessionID, !scanning, Date().timeIntervalSince(lastScan) >= 5 else { return }
        scanning = true
        lastScan = Date()
        let chatID = chat?.id
        queue.async { [weak self] in
            guard let self else { return }
            let items = self.index.scan(parent: parent)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scanning = false
                guard self.state.chatID == chatID, self.session == parent else { return }
                self.state.native = items
                if !self.state.selection.isEmpty && !items.contains(where: { $0.id == self.state.selection }) { self.state.selection = "" }
                self.render()
            }
        }
    }

    func render() {
        guard active else { return }
        guard let chat = model.selectedChat else {
            reader.updateTranscript(id: "side-empty", entries: [], base: nil, emptyText: "Select a chat to ask a side question.")
            return
        }
        let base = model.workingDirectory(of: chat)
        if let native = state.native.first(where: { $0.id == state.selection }) {
            guard followedID != native.id else { return }
            follower?.stop()
            followedID = native.id
            reader.showTranscript(id: "side-native-" + native.id, entries: [], base: base, emptyText: "Waiting for a recorded side conversation boundary and messages.")
            let tail = TranscriptFollower(url: native.url, kind: .codex, baseDir: base, scope: .side)
            tail.onAppend = { [weak self, weak tail] entries in
                guard let self, let tail, self.follower === tail else { return }
                self.reader.appendTranscript(entries)
            }
            tail.onReset = { [weak self, weak tail] in
                guard let self, let tail, self.follower === tail else { return }
                self.reader.showTranscript(id: "side-native-" + native.id, entries: [], base: base, emptyText: "Nothing to show yet.")
            }
            follower = tail
            tail.start()
        } else {
            follower?.stop()
            follower = nil
            followedID = nil
            reader.updateTranscript(id: "side-" + chat.id.uuidString, entries: store.entries(chat.id), base: base,
                                    emptyText: "Ask about this chat without interrupting its work.")
        }
    }

    private func ask() {
        guard let chat = model.selectedChat, state.chatID == chat.id else { return }
        state.selection = ""
        if model.askSideQuestion(state.drafts[chat.id] ?? "", in: chat) { state.drafts[chat.id] = "" }
        render()
    }
}

private struct SidePanelContent: View {
    @ObservedObject var state: SidePanelState
    @ObservedObject var store: SideChatStore
    let reader: NSView
    var body: some View {
        VStack(spacing: 0) {
            SideSources(state: state)
            DiffWebView(webView: reader).frame(maxWidth: .infinity, maxHeight: .infinity)
            SideControls(state: state, store: store)
        }
    }
}

private struct SideSources: View {
    @ObservedObject var state: SidePanelState
    var body: some View {
        if !state.native.isEmpty {
            HStack(spacing: 8) {
                Picker("Conversation", selection: $state.selection) {
                    Text("Side questions").tag("")
                    ForEach(state.native) { item in Text(item.title).tag(item.id) }
                }
                .labelsHidden()
                .onChange(of: state.selection) { _, _ in state.select?() }
                if !state.selection.isEmpty { Text("Read-only").font(.system(size: 11)).foregroundStyle(Color.hSecondary) }
            }
            .padding(8)
        }
    }
}

private struct SideControls: View {
    @ObservedObject var state: SidePanelState
    @ObservedObject var store: SideChatStore
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let id = state.chatID {
                if let error = store.errors[id] { Text(error).font(.system(size: 11.5)).foregroundStyle(Color.hSecondary).textSelection(.enabled) }
                if state.selection.isEmpty {
                    if state.agent == "claude" || state.agent == "codex" {
                        HStack(alignment: .bottom, spacing: 8) {
                            TextField("Ask a side question", text: Binding(get: { state.drafts[id] ?? "" }, set: { state.drafts[id] = $0 }), axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .lineLimit(1...5)
                                .onSubmit { if !store.running.contains(id) { state.ask?() } }
                                .accessibilityLabel("Side question")
                                .focused($focused)
                            if store.running.contains(id) {
                                IconButton(symbol: "stop.fill", size: 12, help: "Stop side question") { store.stop(id) }
                            } else {
                                IconButton(symbol: "arrow.up", size: 12, help: "Ask side question") { state.ask?() }
                                    .disabled((state.drafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        Text("Uses this chat's context and your agent's usage allowance.")
                            .font(.system(size: 10.5)).foregroundStyle(Color.hTertiary)
                    } else {
                        Text("Side questions are not supported for this agent yet.")
                            .font(.system(size: 12)).foregroundStyle(Color.hSecondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.hBackground)
        .overlay(Rectangle().fill(Color.hDivider).frame(height: 1), alignment: .top)
        .onChange(of: state.chatID) { _, _ in focused = true }
        .onChange(of: state.focusGeneration) { _, _ in focused = true }
    }
}
