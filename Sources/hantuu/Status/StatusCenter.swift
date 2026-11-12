import AppKit
import Combine
import CryptoKit
import Darwin

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
    var conversationWindowIsVisible: () -> Bool = {
        guard let window = AppDelegate.shared?.windowController?.window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }
    var requiresVisibleWindow = true

    private weak var model: AppModel?
    private var trackers: [UUID: Tracker] = [:]
    /// Subagents and background tasks each live chat still has running (Status/BackgroundWork.swift).
    let background = BackgroundWatch()
    /// On when BackgroundWatch runs (the app, or a self test that drives it by hand).
    var watchingBackground = false
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    deinit { timer?.invalidate(); background.stop() }

    final class Tracker {
        let chat: Chat
        let kind: AgentKind
        var state = StatusState()
        var events: LineTail?
        var transcript: LineTail?
        var transcriptPath: String?
        var lastHeadKey = ""
        var suppressPublication = false
        var completionKey: String?
        var sessionID: String?
        var waitingForIdentity = false
        var lastStatus: ChatStatus
        var subs = Set<AnyCancellable>()

        init(chat: Chat) {
            self.chat = chat
            kind = AgentKind(agentID: chat.agentID)
            lastStatus = chat.status
            sessionID = chat.sessionID
        }
    }

    // MARK: Lifecycle

    /// Call once after AppModel.load(). The self test passes `live: false` and polls by hand.
    func start(model: AppModel, live: Bool = true) {
        self.model = model
        requiresVisibleWindow = live
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
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in self?.refreshVisibleConversation() }
                .store(in: &bag)
        }
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
            replayEnded(t, events: file)
        } else if initial {
            // Already running when hantuu started (a session that outlived the app): replay
            // the end of its events file to get back to where it was, without notifying.
            t.events = LineTail(url: file, from: .lastBytes(512 * 1024))
            ingest(t, notify: false)
        } else {
            t.events = LineTail(url: file, from: .beginning)
        }
        publish(t, notify: false)
        chat.$sessionID
            .sink { [weak self, weak t] sessionID in
                guard let self, let t else { return }
                self.identityChanged(t, to: sessionID)
            }
            .store(in: &t.subs)
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

    /// Published identity is delivered before Chat stores it. Reset using that supplied
    /// value and avoid publishing old completion data under the incoming native session.
    private func identityChanged(_ t: Tracker, to sessionID: String?) {
        guard t.sessionID != sessionID else { return }
        let ended = t.state.ended
        t.waitingForIdentity = sessionID == nil && t.sessionID != nil
        t.sessionID = sessionID
        t.state = StatusState()
        t.state.ended = ended
        t.completionKey = nil
        t.lastHeadKey = ""
        t.transcript = nil
        t.transcriptPath = nil
        if !t.state.ended && !t.suppressPublication {
            t.events = LineTail(url: AgentHooks.eventsFile(for: t.chat.id), from: .end)
        }
        t.chat.manualUnread = false
        t.chat.activity = t.state.activity
        t.chat.activityDetail = t.state.detail
        t.chat.lastTurnEndedAt = nil
        notifier.withdraw(chatID: t.chat.id)
        recomputeAttention()
    }

    /// Hooks from earlier native sessions can share an event file. Keep only the final
    /// session's suffix, including its compact events that omit session identity.
    private func sessionRecords(_ lines: [Data], tail: LineTail, tracker: Tracker) -> [(Data, UInt64)] {
        let all = records(lines, tail: tail)
        var start = 0
        for (index, record) in all.enumerated() {
            let session = tracker.kind == .claude ? HookLineParser.session(record.0) : TranscriptLookup.codexSession(record.0)
            if let id = session?.id, id != tracker.chat.sessionID { start = index + 1 }
        }
        return Array(all.dropFirst(start))
    }

    private func endProcess(_ t: Tracker) {
        let previous = t.state
        t.state = StatusState()
        t.state.ended = true
        t.state.doneAt = previous.doneAt
        t.state.unseen = previous.unseen
        t.state.lastMessage = previous.lastMessage
        t.state.idleNote = previous.idleNote
    }

    /// Ended sessions still have results to review. Only files that already exist are
    /// replayed; a provisional row with no records remains an ordinary ended chat.
    private func replayEnded(_ t: Tracker, events file: URL) {
        t.suppressPublication = true
        defer {
            endProcess(t)
            t.events = nil
            t.transcript = nil
            t.suppressPublication = false
        }
        if LineTail.size(of: file) > 0 {
            let tail = LineTail(url: file, from: .lastBytes(512 * 1024))
            let lines = tail.read()
            followSession(t, lines)
            let cwd = model?.project(t.chat.projectID)?.path
            for (line, end) in sessionRecords(lines, tail: tail, tracker: t) {
                applyRecord(t, line: line, end: end, source: "events",
                            signals: HookLineParser.parse(line, cwd: cwd), notify: false)
            }
        }
        guard t.state.doneAt == nil, let path = t.chat.transcriptPath else { return }
        let url = URL(fileURLWithPath: path)
        guard LineTail.size(of: url) > 0 else { return }
        let tail = LineTail(url: url, from: .lastBytes(512 * 1024))
        for (line, end) in records(tail.read(), tail: tail) {
            var signals: [OriginSignal]
            if t.kind == .codex {
                signals = CodexRolloutStatus.parse(line, cwd: model?.project(t.chat.projectID)?.path)
            } else if t.kind == .claude {
                signals = ClaudeTranscriptStatus.parse(line)
                if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                   object["type"] as? String == "assistant", object["isSidechain"] as? Bool != true,
                   let message = object["message"] as? [String: Any], message["stop_reason"] as? String == "end_turn" {
                    signals.append(OriginSignal(origin: .transcript, signal: .turnEnded(lastMessage: ClaudeTranscriptParser.textOf(message["content"]))))
                }
            } else { signals = [] }
            applyRecord(t, line: line, end: end, source: "transcript", signals: signals, notify: false)
        }
    }

    private func statusChanged(_ t: Tracker, _ status: ChatStatus) {
        let previous = t.lastStatus
        t.lastStatus = status
        if status == .ended {
            guard !t.state.ended else { return }
            // Drain the final complete records before the process lifecycle closes.
            ingest(t, notify: false)
            endProcess(t)
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
        // Existing bytes are history even when the file itself was created recently.
        if let tail = t.transcript { ingestTranscript(t, tail: tail, notify: false) }
    }

    // MARK: Reading

    func poll() {
        for t in trackers.values where !t.state.ended { ingest(t, notify: true) }
    }

    private func ingest(_ t: Tracker, notify: Bool) {
        t.suppressPublication = true
        defer { t.suppressPublication = false; publish(t, notify: notify) }
        let cwd = model?.project(t.chat.projectID)?.path
        if let e = t.events {
            let lines = e.read()
            followSession(t, lines)
            for (line, end) in sessionRecords(lines, tail: e, tracker: t) {
                applyRecord(t, line: line, end: end, source: "events", signals: HookLineParser.parse(line, cwd: cwd), notify: notify)
            }
        }
        if let tail = t.transcript { ingestTranscript(t, tail: tail, notify: notify) }
    }

    private func ingestTranscript(_ t: Tracker, tail: LineTail, notify: Bool) {
        let outerBatch = t.suppressPublication
        t.suppressPublication = true
        defer {
            t.suppressPublication = outerBatch
            if outerBatch && !notify { t.lastHeadKey = t.state.headKey }
            if !outerBatch { publish(t, notify: notify) }
        }
        let cwd = model?.project(t.chat.projectID)?.path
        for (line, end) in records(tail.read(), tail: tail) {
            let signals: [OriginSignal]
            switch t.kind {
            case .codex: signals = CodexRolloutStatus.parse(line, cwd: cwd)
            case .claude: signals = ClaudeTranscriptStatus.parse(line)
            case .other: signals = []
            }
            applyRecord(t, line: line, end: end, source: "transcript", signals: signals, notify: notify)
        }
    }

    /// Absolute line offsets keep identical replies distinct across app relaunches.
    func records(_ lines: [Data], tail: LineTail) -> [(Data, UInt64)] {
        guard !lines.isEmpty, let file = try? FileHandle(forReadingFrom: tail.url),
              LineTail.size(of: tail.url) >= tail.offset else { return [] }
        defer { try? file.close() }
        var cacheStart: UInt64 = 0
        var cache = Data()
        func byte(at offset: UInt64) -> UInt8? {
            if cache.isEmpty || offset < cacheStart || offset >= cacheStart + UInt64(cache.count) {
                cacheStart = offset / 4096 * 4096
                do {
                    try file.seek(toOffset: cacheStart)
                    cache = try file.read(upToCount: Int(min(4096, tail.offset - cacheStart))) ?? Data()
                } catch { return nil }
            }
            let index = Int(offset - cacheStart)
            return index < cache.count ? cache[index] : nil
        }
        var end = tail.offset
        // LineTail buffers an incomplete trailing record and omits empty lines.
        while end > 0, byte(at: end - 1) != 10 { end -= 1 }
        var result: [(Data, UInt64)] = []
        for line in lines.reversed() {
            while end >= 2, byte(at: end - 2) == 10 { end -= 1 }
            guard end >= UInt64(line.count + 1) else { return [] }
            result.append((line, end))
            end -= UInt64(line.count + 1)
        }
        return Array(result.reversed())
    }

    private func applyRecord(_ t: Tracker, line: Data, end: UInt64, source: String,
                             signals: [OriginSignal], notify: Bool) {
        guard !signals.isEmpty, !t.waitingForIdentity, !t.chat.codexIdentityWaiting else { return }
        let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        let at = CodexUsage.date(obj?["timestamp"] as? String)
        let completes = signals.contains { signal in
            switch signal.signal {
            case .turnEnded, .turnFailed, .codexTurnComplete: return true
            default: return false
            }
        }
        if completes {
            let digest = SHA256.hash(data: line).map { String(format: "%02x", $0) }.joined()
            t.completionKey = "\(source)|\(end)|\(digest)"
        }
        apply(t, signals, notify: notify, at: at)
    }

    /// Claude hooks and Codex completion notifications identify the active conversation.
    /// Only the latest one counts, so a replay never loads old histories.
    /// It re-points the chat's reader and saved resume ID, then this status tail.
    private func followSession(_ t: Tracker, _ lines: [Data]) {
        guard t.kind != .other, let model else { return }
        var session: HookLineParser.Session?
        for line in lines {
            let parsed = t.kind == .claude ? HookLineParser.session(line) : TranscriptLookup.codexSession(line)
            guard let next = parsed else { continue }
            let changedID = next.id != nil && next.id != (session?.id ?? t.chat.sessionID)
            session = HookLineParser.Session(id: next.id ?? session?.id, path: next.path ?? (changedID ? nil : session?.path))
        }
        guard let session else { return }
        model.followSession(t.chat, session: session)
        identityChanged(t, to: t.chat.sessionID)
        attachTranscript(t, path: t.chat.transcriptPath)
    }

    private func context(_ t: Tracker) -> StatusContext {
        StatusContext(agent: t.kind, focused: isFocused(t.chat), now: Date(),
                      watchesBackground: watchingBackground && t.kind != .other && t.chat.transcriptPath != nil)
    }

    private func isFocused(_ chat: Chat) -> Bool {
        appIsActive() && (!requiresVisibleWindow || conversationWindowIsVisible())
            && model?.selectedChatID == chat.id && model?.subagentBrowser.selection == nil && model?.historyPresented == false
            && chat.archivedAt == nil
            && !chat.codexIdentityWaiting
    }

    private static let verbose = ProcessInfo.processInfo.environment["HANTUU_STATUS_LOG"] == "1"

    private func apply(_ t: Tracker, _ signals: [OriginSignal], notify: Bool, at: Date? = nil) {
        guard !t.waitingForIdentity, !t.chat.codexIdentityWaiting else { return }
        var st = t.state
        var ctx = context(t)
        if let at { ctx.now = at }
        for s in signals {
            if Self.verbose { Log.write("status signal chat=\(t.chat.id) \(s.origin) \(String(describing: s.signal).prefix(240))") }
            StatusReducer.apply(s, to: &st, ctx: ctx)
        }
        t.state = st
        if !t.suppressPublication { publish(t, notify: notify) }
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
        // Drain already-written hooks before appending the observed interruption. Keeping
        // it in the same app-owned stream lets replay preserve native event ordering.
        ingest(t, notify: false)
        guard t.state.activity == .working else { return }
        if t.kind == .claude, let session = chat.sessionID, !session.isEmpty {
            let file = AgentHooks.eventsFile(for: chat.id)
            persistReaderStop(t, session: session, offset: LineTail.size(of: file), attempts: 20)
        }
        apply(t, [OriginSignal(origin: .app, signal: .interrupted)], notify: false)
    }

    /// Use the hook writers' POSIX record lock and O_APPEND. A delayed write may only
    /// target the exact event-stream position that was stopped, never a newer turn.
    private func persistReaderStop(_ tracker: Tracker, session: String, offset: UInt64, attempts: Int) {
        guard trackers[tracker.chat.id] === tracker, tracker.chat.sessionID == session,
              !tracker.state.ended else { return }
        let file = AgentHooks.eventsFile(for: tracker.chat.id)
        let fd = Darwin.open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { Log.write("reader stop: could not open event stream chat=\(tracker.chat.id)"); return }
        defer { Darwin.close(fd) }
        // F_TLOCK does not block the UI while another hook is writing. Closing this
        // descriptor releases the whole-file lock, including after the append moves it.
        guard lockf(fd, F_TLOCK, 0) == 0 else {
            guard attempts > 0 else { Log.write("reader stop: event stream remained locked chat=\(tracker.chat.id)"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak tracker] in
                guard let self, let tracker else { return }
                self.persistReaderStop(tracker, session: session, offset: offset, attempts: attempts - 1)
            }
            return
        }
        guard LineTail.size(of: file) == offset else {
            Log.write("reader stop: newer event superseded checkpoint chat=\(tracker.chat.id)")
            return
        }
        let record: [String: Any] = ["hantuu_event": "reader_interrupted", "session_id": session,
                                     "timestamp": ISO8601DateFormatter().string(from: Date())]
        guard var data = try? JSONSerialization.data(withJSONObject: record) else { return }
        data.append(10)
        let written = data.withUnsafeBytes { bytes -> Int in
            var count = 0
            while count < bytes.count {
                let result = Darwin.write(fd, bytes.baseAddress!.advanced(by: count), bytes.count - count)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { break }
                count += result
            }
            return count
        }
        if written != data.count {
            // Still under the hook lock: do not leave a partial JSON line in front of
            // the provider's next record if disk space or another I/O error stopped us.
            _ = ftruncate(fd, off_t(offset))
            Log.write("reader stop: incomplete event write chat=\(tracker.chat.id)")
        }
    }

    // MARK: Publishing

    private func publish(_ t: Tracker, notify: Bool) {
        let chat = t.chat
        identityChanged(t, to: chat.sessionID)
        if chat.seenSessionID == sessionScope(chat) {
            let seenKey = t.completionKey != nil && t.completionKey == chat.seenCompletionKey
            let seenDate = t.state.doneAt.map { done in chat.seenThrough.map { done <= $0 } ?? false } ?? false
            // A distinct record in the same stream is a new completion even if the
            // provider clock is behind the host clock. Dates bridge the notify and rollout streams.
            let sameStream = t.completionKey?.components(separatedBy: "|").first
                == chat.seenCompletionKey?.components(separatedBy: "|").first
            if seenKey || (seenDate && (!sameStream || chat.seenCompletionKey == nil)) { t.state.unseen = false }
        }
        if chat.manualUnread { t.state.unseen = true }
        if isFocused(chat), !chat.manualUnread, t.state.doneAt != nil { recordSeen(t) }
        let st = t.state
        let activity: AgentActivity = st.ended && (st.unseen || chat.manualUnread) ? .doneUnseen : st.activity
        if chat.activity != activity {
            Log.write("status chat=\(chat.id) \(chat.activity.rawValue) -> \(activity.rawValue) \"\(st.detail)\"")
            chat.activitySince = Date()
            chat.activity = activity
        }
        let detail = st.ended && (st.unseen || chat.manualUnread) ? "Ended - unread result" : st.detail
        if chat.activityDetail != detail { chat.activityDetail = detail }
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
        guard t.chat.archivedAt == nil, activity.wantsAttention, settings.notificationsEnabled else { return }
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
        chats.filter { $0.archivedAt == nil && $0.activity.wantsAttention }
            .sorted { a, b in
                if a.activity.isNeeds != b.activity.isNeeds { return a.activity.isNeeds }
                return a.activitySince < b.activitySince
            }
            .map(\.id)
    }

    // MARK: Focus and navigation

    private func focusChanged(selected id: UUID?) {
        guard let id, appIsActive(), (!requiresVisibleWindow || conversationWindowIsVisible()),
              model?.subagentBrowser.selection == nil, model?.historyPresented == false, let t = trackers[id], t.chat.archivedAt == nil, !t.chat.codexIdentityWaiting else { return }
        setRead(chat: t.chat, read: true)
    }

    func refreshVisibleConversation() { focusChanged(selected: model?.selectedChatID) }

    /// Providers without a native ID retain read state only within this saved chat.
    private func sessionScope(_ chat: Chat) -> String {
        chat.sessionID ?? "hantuu-chat:\(chat.id.uuidString)"
    }

    private func recordSeen(_ t: Tracker) {
        let chat = t.chat
        guard let through = t.state.doneAt else { return }
        guard chat.seenSessionID != sessionScope(chat) || chat.seenThrough != through
                || chat.seenCompletionKey != t.completionKey else { return }
        chat.seenSessionID = sessionScope(chat)
        chat.seenThrough = through
        chat.seenCompletionKey = t.completionKey
        model?.scheduleSave()
    }

    func setRead(chat: Chat, read: Bool) {
        chat.manualUnread = !read
        if let t = trackers[chat.id] {
            if read {
                StatusReducer.markSeen(&t.state, ctx: context(t))
                recordSeen(t)
                notifier.withdraw(chatID: chat.id)
            } else {
                t.state.unseen = true
            }
            publish(t, notify: false)
        }
        model?.scheduleSave()
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
