import AppKit
import Combine

/// libghostty actions that matter for status (OSC 9;4 progress, command finished), posted by
/// GhosttyApp on the main thread.
enum TerminalSignals {
    static var handler: ((TerminalView, StatusSignal) -> Void)?
    static func post(_ view: TerminalView, _ signal: StatusSignal) { handler?(view, signal) }
}

/// Keeps every chat's `activity` true. It tails each chat's events file (hooks, notify) and
/// transcript, folds what it reads through StatusReducer, and turns state changes into the
/// needs-you list, the Dock badge and macOS notifications.
///
/// It finds out about chats by watching AppModel, so AppModel only has to start agents with
/// AgentHooks' arguments and environment.
final class StatusCenter: ObservableObject {
    static let shared = StatusCenter()

    /// Chats that need you, in Cmd-J order: Needs states oldest first, then Done ones.
    @Published private(set) var attention: [UUID] = []
    let settings = StatusSettings()
    var notifier: AttentionNotifying = SystemNotifier()
    var appIsActive: () -> Bool = { NSApp?.isActive ?? false }
    var updatesDockBadge = false

    private weak var model: AppModel?
    private var trackers: [UUID: Tracker] = [:]
    /// Subagents and background tasks each live chat still has running (Status/BackgroundWork.swift).
    let background = BackgroundWatch()
    /// On when BackgroundWatch runs (the app, or a self test that drives it by hand).
    var watchingBackground = false
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    final class Tracker {
        let chat: Chat
        let kind: AgentKind
        var state = StatusState()
        var events: LineTail?
        var transcript: LineTail?
        var transcriptPath: String?
        var lastHeadKey = ""
        var lastStatus: ChatStatus
        var subs = Set<AnyCancellable>()

        init(chat: Chat) {
            self.chat = chat
            kind = AgentKind(agentID: chat.agentID)
            lastStatus = chat.status
        }
    }

    // MARK: Lifecycle

    /// Call once after AppModel.load(). The self test passes `live: false` and polls by hand.
    func start(model: AppModel, live: Bool = true) {
        self.model = model
        Paths.ensure(AgentHooks.eventsDir)
        var first = true
        model.$chats
            .sink { [weak self] chats in
                self?.sync(chats, initial: first)
                first = false
            }
            .store(in: &bag)
        model.$selectedChatID
            .sink { [weak self] id in self?.focusChanged(selected: id) }
            .store(in: &bag)
        guard live else { return }
        updatesDockBadge = true
        TerminalSignals.handler = { [weak self] view, signal in self?.terminal(view, signal) }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.focusChanged(selected: self?.model?.selectedChatID) }
            .store(in: &bag)
        if let sys = notifier as? SystemNotifier { sys.onOpen = { [weak self] id in self?.open(id) } }
        notifier.prepare()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        background.deliver = { [weak self] id, s in self?.backgroundChanged(id, s) }
        background.start(model: model)
        watchingBackground = true
    }

    /// A chat's background work, every couple of seconds: running subagents and tasks keep it
    /// from reading Done, and the last one finishing is when it's done.
    func backgroundChanged(_ id: UUID, _ summary: BackgroundSummary) {
        guard let t = trackers[id], !t.state.ended else { return }
        apply(t, [OriginSignal(origin: .transcript, signal: .background(summary))], notify: true)
    }

    private func sync(_ chats: [Chat], initial: Bool) {
        let ids = Set(chats.map(\.id))
        for (id, t) in trackers where !ids.contains(id) {
            t.subs.removeAll()
            trackers[id] = nil
            notifier.withdraw(chatID: id)
            try? FileManager.default.removeItem(at: AgentHooks.eventsFile(for: id))
        }
        for chat in chats where trackers[chat.id] == nil { track(chat, initial: initial) }
        recomputeAttention()
    }

    private func track(_ chat: Chat, initial: Bool) {
        let t = Tracker(chat: chat)
        trackers[chat.id] = t
        let file = AgentHooks.eventsFile(for: chat.id)
        if chat.status == .ended {
            t.state.ended = true
            // It may have moved to another conversation before it ended, with hantuu closed.
            if t.kind == .claude { followSession(t, LineTail(url: file, from: .lastBytes(256 * 1024)).read()) }
        } else if initial {
            // Already running when hantuu started (a session that outlived the app): replay
            // the end of its events file to get back to where it was, without notifying.
            t.events = LineTail(url: file, from: .lastBytes(512 * 1024))
            ingest(t, notify: false)
        } else {
            t.events = LineTail(url: file, from: .beginning)
        }
        publish(t, notify: false)
        chat.$status
            .sink { [weak self, weak t] status in
                guard let self, let t else { return }
                self.statusChanged(t, status)
            }
            .store(in: &t.subs)
        chat.$transcriptPath
            .sink { [weak self, weak t] path in
                guard let self, let t else { return }
                self.attachTranscript(t, path: path)
            }
            .store(in: &t.subs)
    }

    private func statusChanged(_ t: Tracker, _ status: ChatStatus) {
        let previous = t.lastStatus
        t.lastStatus = status
        if status == .ended {
            guard !t.state.ended else { return }
            t.state = StatusState()
            t.state.ended = true
            t.events = nil
            t.transcript = nil
            publish(t, notify: false)
            return
        }
        guard previous == .ended else { return }
        // Resumed or started again: a fresh process, so a fresh state. The old events are
        // history; the file is trimmed if it grew large.
        let file = AgentHooks.eventsFile(for: t.chat.id)
        if LineTail.size(of: file) > 2 << 20 { try? Data().write(to: file) }
        t.state = StatusState()
        t.events = LineTail(url: file, from: .end)
        t.transcript = nil
        t.transcriptPath = nil
        attachTranscript(t, path: t.chat.transcriptPath)
        publish(t, notify: false)
    }

    private func attachTranscript(_ t: Tracker, path: String?) {
        guard let path else {
            t.transcriptPath = nil
            t.transcript = nil
            return
        }
        guard !t.state.ended, path != t.transcriptPath || t.transcript == nil else { return }
        t.transcriptPath = path
        let url = URL(fileURLWithPath: path)
        // A file this chat created is read from the top; an older one (a resumed Claude
        // session) only from now on.
        let created = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
        let fresh = created.map { $0 >= t.chat.startedAt.addingTimeInterval(-5) } ?? true
        t.transcript = LineTail(url: url, from: fresh ? .beginning : .end)
    }

    // MARK: Reading

    func poll() {
        for t in trackers.values where !t.state.ended { ingest(t, notify: true) }
    }

    private func ingest(_ t: Tracker, notify: Bool) {
        let cwd = model?.project(t.chat.projectID)?.path
        var signals: [OriginSignal] = []
        if let e = t.events {
            let lines = e.read()
            for line in lines { signals += HookLineParser.parse(line, cwd: cwd) }
            followSession(t, lines)
        }
        if let tr = t.transcript {
            for line in tr.read() {
                switch t.kind {
                case .codex: signals += CodexRolloutStatus.parse(line, cwd: cwd)
                case .claude: signals += ClaudeTranscriptStatus.parse(line)
                case .other: break
                }
            }
        }
        guard !signals.isEmpty else { return }
        apply(t, signals, notify: notify)
    }

    /// /resume and /clear move Claude Code to another conversation, and every main-agent hook
    /// names the one it is in. Only the latest one counts, so a replay never loads old histories.
    /// It re-points the chat's reader and saved resume ID, then this status tail.
    private func followSession(_ t: Tracker, _ lines: [Data]) {
        guard t.kind == .claude, let model else { return }
        var session: HookLineParser.Session?
        for line in lines {
            guard let next = HookLineParser.session(line) else { continue }
            let changedID = next.id != nil && next.id != (session?.id ?? t.chat.sessionID)
            session = HookLineParser.Session(id: next.id ?? session?.id, path: next.path ?? (changedID ? nil : session?.path))
        }
        guard let session else { return }
        model.followSession(t.chat, session: session)
        attachTranscript(t, path: t.chat.transcriptPath)
    }

    private func context(_ t: Tracker) -> StatusContext {
        StatusContext(agent: t.kind, focused: isFocused(t.chat), now: Date(),
                      watchesBackground: watchingBackground && t.kind != .other && t.chat.transcriptPath != nil)
    }

    private func isFocused(_ chat: Chat) -> Bool {
        appIsActive() && model?.selectedChatID == chat.id
    }

    private static let verbose = ProcessInfo.processInfo.environment["HANTUU_STATUS_LOG"] == "1"

    private func apply(_ t: Tracker, _ signals: [OriginSignal], notify: Bool) {
        var st = t.state
        let ctx = context(t)
        for s in signals {
            if Self.verbose { Log.write("status signal chat=\(t.chat.id) \(s.origin) \(String(describing: s.signal).prefix(240))") }
            StatusReducer.apply(s, to: &st, ctx: ctx)
        }
        t.state = st
        publish(t, notify: notify)
    }

    /// From AppModel.terminalNeedsAttention: "bell" or "notification: <title> <body>".
    func terminalAttention(_ chat: Chat, reason: String) {
        guard let t = trackers[chat.id] else { return }
        let text: String? = reason.hasPrefix("notification:")
            ? String(reason.dropFirst("notification:".count)).trimmingCharacters(in: .whitespaces) : nil
        apply(t, [OriginSignal(origin: .terminal, signal: .terminalNotice(text: text))], notify: true)
    }

    func terminal(_ view: TerminalView, _ signal: StatusSignal) {
        guard let t = trackers.values.first(where: { $0.chat.terminal === view }) else { return }
        apply(t, [OriginSignal(origin: .terminal, signal: signal)], notify: true)
    }

    /// Reader mode pressed Esc and the agent's screen shows its turn has stopped. Claude Code
    /// doesn't always write an interrupt line or fire a hook for that, so without this the
    /// chat would read Working until its next turn.
    func stoppedFromReader(_ chat: Chat) {
        guard let t = trackers[chat.id], chat.activity == .working else { return }
        apply(t, [OriginSignal(origin: .app, signal: .interrupted)], notify: false)
    }

    // MARK: Publishing

    private func publish(_ t: Tracker, notify: Bool) {
        let st = t.state
        let chat = t.chat
        let activity = st.activity
        if chat.activity != activity {
            Log.write("status chat=\(chat.id) \(chat.activity.rawValue) -> \(activity.rawValue) \"\(st.detail)\"")
            chat.activitySince = Date()
            chat.activity = activity
        }
        if chat.activityDetail != st.detail { chat.activityDetail = st.detail }
        if chat.lastTurnEndedAt != st.doneAt { chat.lastTurnEndedAt = st.doneAt }
        let key = st.headKey
        if key != t.lastHeadKey {
            t.lastHeadKey = key
            if notify { maybeNotify(t) }
            if !activity.wantsAttention { notifier.withdraw(chatID: chat.id) }
        }
        recomputeAttention()
    }

    /// One notification per state change, for a chat you aren't looking at.
    private func maybeNotify(_ t: Tracker) {
        let st = t.state
        let activity = st.activity
        guard activity.wantsAttention, settings.notificationsEnabled else { return }
        if activity == .doneUnseen && !settings.notifyWhenDone { return }
        if isFocused(t.chat) { return }
        notifier.post(notice(for: t.chat, state: st))
    }

    func notice(for chat: Chat, state st: StatusState) -> AttentionNotice {
        let project = model?.project(chat.projectID)?.name
        let title = project.map { "\(chat.displayTitle) in \($0)" } ?? chat.displayTitle
        let done = st.activity == .doneUnseen
        let body = done ? (st.idleNote ?? StatusText.lastLine(st.lastMessage) ?? "Finished its turn") : st.detail
        return AttentionNotice(chatID: chat.id, title: title, body: body, isDone: done)
    }

    func recomputeAttention() {
        guard let model else { return }
        let ids = Self.attentionOrder(model.chats)
        if ids != attention { attention = ids }
        if updatesDockBadge {
            let label = ids.isEmpty ? nil : "\(ids.count)"
            if NSApp.dockTile.badgeLabel != label {
                NSApp.dockTile.badgeLabel = label
                Log.write("dock badge \(label ?? "none")")
            }
        }
    }

    static func attentionOrder(_ chats: [Chat]) -> [UUID] {
        chats.filter { $0.activity.wantsAttention }
            .sorted { a, b in
                if a.activity.isNeeds != b.activity.isNeeds { return a.activity.isNeeds }
                return a.activitySince < b.activitySince
            }
            .map(\.id)
    }

    // MARK: Focus and navigation

    private func focusChanged(selected id: UUID?) {
        guard let id, appIsActive(), let t = trackers[id] else { return }
        var st = t.state
        StatusReducer.markSeen(&st, ctx: context(t))
        t.state = st
        publish(t, notify: false)
        notifier.withdraw(chatID: id)
    }

    /// Cmd-J: the next chat that needs you, oldest first, skipping the one you're on.
    func jumpToNext() {
        guard let model else { return }
        recomputeAttention()
        if let id = attention.first(where: { $0 != model.selectedChatID }) { model.select(id) }
    }

    /// A notification was clicked.
    func open(_ id: UUID) {
        NSApp.activate()
        AppDelegate.shared?.windowController?.window?.makeKeyAndOrderFront(nil)
        model?.select(id)
    }

    /// For the self test: the reduced state of one chat.
    func state(of id: UUID) -> StatusState? { trackers[id]?.state }

    /// For offscreen snapshots: show the needs-you list for chats whose activity is set by
    /// hand, without tracking anything.
    func preview(model: AppModel) {
        self.model = model
        recomputeAttention()
    }
}
