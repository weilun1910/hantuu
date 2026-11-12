import Foundation

/// Only the configured leading session-id item is evidence. Thread names are never searched.
struct CodexTitleIdentity: Equatable {
    let prefix: String
    let truncated: Bool
    let displayTitle: String

    static func parse(_ title: String) -> CodexTitleIdentity? {
        let full = #"^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?=$|[ |])"#
        let short = #"^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{5})\.\.\.(?=$|[ |])"#
        for (pattern, truncated) in [(full, false), (short, true)] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
                  let prefixRange = Range(match.range(at: 1), in: title),
                  let tokenRange = Range(match.range, in: title) else { continue }
            let display = title[tokenRange.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " |"))
            return CodexTitleIdentity(prefix: title[prefixRange].lowercased(), truncated: truncated, displayTitle: display)
        }
        return nil
    }
    func sameIdentity(as other: CodexTitleIdentity?) -> Bool {
        other?.prefix == prefix && other?.truncated == truncated
    }

    /// A matching saved full UUID is preserved while a truncated title is verified.
    /// Only a genuinely different identity clears queued input and seen watermarks.
    func preservesSession(_ sessionID: String?) -> Bool { matches(sessionID) }

    func matches(_ sessionID: String?) -> Bool {
        guard let sessionID, UUID(uuidString: sessionID) != nil else { return false }
        return truncated ? sessionID.lowercased().hasPrefix(prefix) : sessionID.lowercased() == prefix
    }
}

enum CodexTitleLookup {
    enum Outcome: Equatable {
        case found(id: String, path: String)
        case missing, ambiguous, incomplete, cancelled
    }
    /// Scan active rollouts only. A partial directory walk cannot establish uniqueness.
    static func resolve(_ hint: CodexTitleIdentity, root: URL, limit: Int = 100_000,
                        cancellation: ChatHistoryCancellation = ChatHistoryCancellation()) -> Outcome {
        var failed = false
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return true }) else { return .missing }
        var matches: [String: String] = [:]
        var count = 0
        for case let url as URL in files {
            if cancellation.cancelled { return .cancelled }
            count += 1
            if count > limit { return .incomplete }
            guard let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { failed = true; continue }
            if attributes.isSymbolicLink == true { files.skipDescendants(); continue }
            guard attributes.isRegularFile == true, url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl", url.lastPathComponent.lowercased().contains("-" + hint.prefix) else { continue }
            guard let metadata = metadata(url) else { failed = true; continue }
            if metadata.child { continue }
            guard hint.matches(metadata.id), url.lastPathComponent.lowercased().hasSuffix("-" + metadata.id.lowercased() + ".jsonl") else { continue }
            let key = metadata.id.lowercased()
            // Duplicate files with the same native UUID are the same identity. Use a
            // stable path rather than modification time, growth, or working directory.
            matches[key] = min(matches[key] ?? url.path, url.path)
            if matches.count > 1 { return .ambiguous }
        }
        if failed { return .incomplete }
        guard let found = matches.first else { return .missing }
        return .found(id: found.key, path: found.value)
    }

    static func metadata(_ url: URL) -> (id: String, cwd: String, child: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024),
              let end = data.firstIndex(of: 10),
              let object = (try? JSONSerialization.jsonObject(with: data[..<end])) as? [String: Any],
              object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any],
              let id = payload["id"] as? String, UUID(uuidString: id) != nil,
              let cwd = payload["cwd"] as? String, !cwd.isEmpty else { return nil }
        let source = payload["source"] as? [String: Any]
        let child = payload["parent_thread_id"] != nil || source?["subagent"] != nil ||
            ["subagent", "guardian_review"].contains(payload["thread_source"] as? String ?? "")
        return (id, cwd, child)
    }
}

/// Owned by each Chat. All state changes occur on main; only value snapshots cross queues.
final class CodexTitleIdentityState {
    var hint: CodexTitleIdentity?
    var waiting = false
    var blocksInput = false
    var generation = UUID()
    var cancellation: ChatHistoryCancellation?
    var retry: DispatchWorkItem?
    var attempts = 0
    var inFlight = false
    var needsLookup: Bool { waiting && !inFlight && retry == nil }

    func allows(_ sessionID: String?) -> Bool {
        if let hint { return hint.matches(sessionID) }
        if waiting { return sessionID.flatMap(UUID.init(uuidString:)) != nil }
        return true
    }
    let queue = DispatchQueue(label: "hantuu.codex-title-identity", qos: .utility)

    func cancel() {
        generation = UUID(); cancellation?.cancel(); cancellation = nil; inFlight = false
        retry?.cancel(); retry = nil
    }
    deinit { cancellation?.cancel(); retry?.cancel() }
}

extension Chat {
    var codexIdentityWaiting: Bool { agentID == "codex" && codexTitleIdentity.waiting && codexTitleIdentity.blocksInput }
}

extension AppModel {
    /// Returns true when the configured identity prefix was handled, including its title.
    @discardableResult
    func acceptCodexTitle(_ chat: Chat, title: String) -> Bool {
        guard chat.agentID == "codex" else { return false }
        let state = chat.codexTitleIdentity
        guard let hint = CodexTitleIdentity.parse(title) else {
            state.cancel(); state.hint = nil
            // A custom /title disables the title guard. If a changed identity was
            // unresolved, keep the empty reader until authoritative notify identifies it.
            return false
        }
        chat.terminalTitle = hint.displayTitle.isEmpty ? "Codex" : hint.displayTitle
        if hint.sameIdentity(as: state.hint) {
            state.hint = hint
            if state.needsLookup { resolveCodexTitle(chat) }
            objectWillChange.send(); scheduleSave()
            return true
        }
        let hasPriorIdentity = chat.sessionID != nil || chat.transcriptPath != nil || state.hint != nil || state.blocksInput
        let preserveSession = !hasPriorIdentity || hint.preservesSession(chat.sessionID)
        state.cancel(); state.hint = hint; state.attempts = 0
        if !hint.truncated, hint.matches(chat.sessionID), chat.transcriptPath != nil {
            state.waiting = false; state.blocksInput = false
            objectWillChange.send(); scheduleSave()
            return true
        }
        // Hide the reader while uniqueness is checked. A matching saved full UUID keeps
        // its queued input and seen watermarks until native metadata verifies the title.
        state.waiting = true
        // Codex exposes a new thread ID before it creates the rollout. Its first input
        // must be allowed to create that file. Replacing an existing identity stays gated.
        state.blocksInput = hasPriorIdentity
        chat.discoveryTimer?.invalidate(); chat.transcriptRecovery = nil
        chat.follower?.stop(); chat.follower = nil
        if !preserveSession { chat.sessionID = nil }
        chat.transcriptPath = nil
        chat.earlierEntries = []; chat.liveEntries = []
        if !preserveSession {
            subagentBrowser.forget(chat.id)
            chat.firstPrompt = nil
            chat.pendingMessages.removeAll()
            chat.seenSessionID = nil; chat.seenThrough = nil; chat.seenCompletionKey = nil; chat.manualUnread = false
        }
        readerReload.send(chat.id); objectWillChange.send(); scheduleSave()
        resolveCodexTitle(chat)
        return true
    }

    /// Gate followSession, not just the discovery callback. A late old notify must not
    /// reattach the conversation that the terminal has already left.
    func codexTitleAllowsFollow(_ chat: Chat, session: HookLineParser.Session) -> Bool {
        guard chat.agentID == "codex" else { return true }
        let state = chat.codexTitleIdentity
        guard state.allows(session.id) else { return false }
        return true
    }

    /// Only validated native metadata can release the input gate. A process-owned rollout
    /// can supersede an old title, while later hook signals still obey the current hint.
    func confirmCodexSession(_ chat: Chat, session: HookLineParser.Session) {
        guard chat.agentID == "codex" else { return }
        let state = chat.codexTitleIdentity
        state.cancel()
        if let hint = state.hint, !hint.matches(session.id) { state.hint = nil }
        state.waiting = false; state.blocksInput = false
    }

    private func resolveCodexTitle(_ chat: Chat) {
        let state = chat.codexTitleIdentity
        guard state.waiting, let hint = state.hint, chat.status != .ended,
              chats.contains(where: { $0 === chat }), chat.archivedAt == nil else { state.cancel(); return }
        guard !state.inFlight else { return }
        state.inFlight = true; state.retry = nil
        let generation = state.generation, launch = chat.launchToken
        let cancellation = ChatHistoryCancellation(); state.cancellation = cancellation
        let root = transcriptLocations.codex
        state.queue.async { [weak self, weak chat] in
            let outcome = CodexTitleLookup.resolve(hint, root: root, cancellation: cancellation)
            DispatchQueue.main.async { [weak self, weak chat] in
                guard let self, let chat, chat.codexTitleIdentity === state,
                      state.generation == generation, !cancellation.cancelled,
                      state.waiting, chat.launchToken == launch, chat.status != .ended,
                      chat.archivedAt == nil, self.chats.contains(where: { $0 === chat }) else { return }
                state.inFlight = false
                switch outcome {
                case let .found(id, path):
                    // followSession runs the same state-reset and follower path as notify.
                    self.followSession(chat, session: HookLineParser.Session(id: id, path: path), verifiedCodex: true)
                case .cancelled: break
                case .missing, .ambiguous, .incomplete:
                    state.attempts += 1
                    let work = DispatchWorkItem { [weak self, weak chat, weak state] in
                        guard let self, let chat, let state, state.generation == generation else { return }
                        state.retry = nil
                        self.resolveCodexTitle(chat)
                    }
                    state.retry = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + (state.attempts < 3 ? 2 : 10), execute: work)
                }
            }
        }
    }
}
