import Foundation

/// Messages reader mode has sent that the transcript has not acknowledged yet.
/// This lives on the chat, so changing the selected chat does not lose its queue.
struct PendingReaderMessages: Codable {
    enum Stage: String, Codable { case waiting, preparing, typing, sent, delivering, unconfirmed, failed }
    struct Recovery {
        var text: String?
        var attachments: [ComposerAttachment]
        var files: [ComposerMessage.OutgoingFile]
        var sessionID: String?
    }
    private struct Message: Codable {
        var entry: ReaderEntry
        var existingIDs: Set<String>
        var expectedText: String
        var imagePaths: [String]
        var agentID: String
        var commandName: String?
        var submitted = false
        var deliveryBatch: String? = nil
        var stage: Stage = .sent
        var originalText: String? = nil
        var attachments: [ComposerAttachment] = []
        var files: [ComposerMessage.OutgoingFile] = []
        var sessionID: String? = nil
        var detail: String? = nil
        var changedAt = Date()
    }

    private var messages: [Message] = []
    private var acknowledgedCommands: [String: Int] = [:]
    private var seenResultIDs = Set<String>()
    var sendNowEnabled = false
    var queuePaused = false
    var inputNeedsReview = false
    var firstWaitingID: String? { messages.first(where: { $0.stage == .waiting })?.entry.id }
    var hasAgentOwned: Bool { messages.contains { [.sent, .delivering, .unconfirmed].contains($0.stage) } }
    var referencedAttachmentPaths: Set<String> { Set(messages.flatMap { $0.files.map(\.path) + $0.attachments.flatMap { [$0.url.path] + ($0.preparedURL.map { [$0.path] } ?? []) } }) }
    func recovery(id: String) -> Recovery? {
        messages.first { $0.entry.id == id }.map { Recovery(text: $0.originalText ?? $0.expectedText, attachments: $0.attachments, files: $0.files, sessionID: $0.sessionID) }
    }
    func stage(id: String) -> Stage? { messages.first { $0.entry.id == id }?.stage }

    var entries: [ReaderEntry] {
        messages.map { message in
            var entry = message.entry
            entry.pendingState = message.stage == .waiting ? (queuePaused ? "Queue paused" : "Queued") : [
                Stage.preparing: "Preparing", .typing: "Preparing to send", .sent: "Sent to agent", .delivering: "Delivering",
                .unconfirmed: "Delivery unconfirmed", .failed: "Not sent"
            ][message.stage]
            entry.pendingDetail = message.detail
            let sendAction = hasAgentOwned && QueuedSendNow.action(agentID: message.agentID) != nil ? "sendWithQueue" : "send"
            entry.pendingActions = message.stage == .waiting ? [sendAction, "edit", "up", "down", "remove"] : ["restore", "terminal"]
            if message.stage == .waiting && queuePaused { entry.pendingActions?.append("resume") }
            if sendNowEnabled && message.submitted && entry.deliveryRequested != true && message.commandName == nil {
                entry.sendNowLabel = QueuedSendNow.action(agentID: message.agentID)?.label
            }
            return entry
        }
    }
    var isEmpty: Bool { messages.isEmpty }

    mutating func enqueue(id: String, text: String?, files: [ComposerMessage.OutgoingFile],
                          agentID: String, existing: [ReaderEntry], stage: Stage = .sent,
                          attachments: [ComposerAttachment] = [], sessionID: String? = nil) {
        let replacing = messages.firstIndex { $0.entry.id == id }
        let steps = ComposerMessage.steps(text: text, files: files, agentID: agentID)
        let body = steps.compactMap { step -> String? in
            switch step {
            case .paste(let text), .command(let text): return text
            case .image, .pressReturn: return nil
            }
        }.joined()
        let commandName = steps.compactMap { step -> String? in
            if case .command(let text) = step { return ComposerCommandTransport.invocation(text)?.name }
            return nil
        }.first
        let paths = files.filter(\.image).map(\.path)
        var entry = ReaderEntry(id: id, kind: .user, text: ComposerMessage.prepare(body) ?? text ?? "", images: paths.isEmpty ? attachments.filter(\.isPicture).map { $0.url.path } : paths)
        entry.pending = true
        messages.append(Message(entry: entry, existingIDs: Set(existing.map(\.id)),
                                expectedText: entry.text, imagePaths: paths,
                                agentID: agentID, commandName: commandName, stage: stage, originalText: text,
                                attachments: attachments, files: files, sessionID: sessionID))
        if let replacing {
            messages.remove(at: replacing)
            let replacement = messages.removeLast()
            messages.insert(replacement, at: replacing)
        }
    }

    mutating func prepareTransport(id: String, files: [ComposerMessage.OutgoingFile], attachments: [ComposerAttachment]) {
        guard let index = messages.firstIndex(where: { $0.entry.id == id }) else { return }
        let body = ComposerMessage.steps(text: messages[index].originalText, files: files, agentID: messages[index].agentID).compactMap { step -> String? in
            switch step { case .paste(let text), .command(let text): return text; default: return nil }
        }.joined()
        messages[index].expectedText = ComposerMessage.prepare(body) ?? ""
        messages[index].imagePaths = files.filter(\.image).map(\.path)
        messages[index].entry.images = messages[index].imagePaths
        messages[index].files = files
        messages[index].attachments = attachments
        messages[index].stage = .typing
    }

    mutating func markSubmitted(id: String, existing: [ReaderEntry]? = nil) {
        guard let index = messages.firstIndex(where: { $0.entry.id == id }) else { return }
        if let existing { messages[index].existingIDs.formUnion(existing.map(\.id)) }
        messages[index].submitted = true
        messages[index].stage = .sent
        messages[index].changedAt = Date()
    }

    /// The terminal action can affect more than the clicked bubble. Keep those bubbles until
    /// their real transcript entries arrive, including across the resulting interruption.
    @discardableResult
    mutating func requestDelivery(id: String) -> Bool {
        guard sendNowEnabled, let target = messages.first(where: { $0.entry.id == id }), target.submitted,
              target.entry.deliveryRequested != true, target.commandName == nil,
              let action = QueuedSendNow.action(agentID: target.agentID) else { return false }
        let batch = UUID().uuidString
        for index in messages.indices where messages[index].entry.deliveryRequested != true && messages[index].submitted && messages[index].agentID == target.agentID {
            if action.scope == .all || messages[index].entry.id == id {
                messages[index].stage = .delivering
                messages[index].changedAt = Date()
                messages[index].entry.deliveryRequested = true
                messages[index].deliveryBatch = batch
            }
        }
        return true
    }

    /// Each delivered entry consumes at most one pending send. Old identical prompts and
    /// repeated reloads cannot acknowledge a newer send with the same words.
    mutating func reconcile(_ entries: [ReaderEntry]) -> [ReaderEntry] {
        entries.map { entry in
            if entry.kind == .notice && (entry.text == "Interrupted" || entry.text == "Turn interrupted") {
                for index in messages.indices where !messages[index].existingIDs.contains(entry.id) {
                    queuePaused = true
                    sendNowEnabled = false
                    if messages[index].stage != .waiting && messages[index].stage != .failed {
                        messages[index].stage = messages[index].submitted ? .unconfirmed : .failed
                        messages[index].detail = "The turn was interrupted. Check the terminal before restoring or resending."
                    }
                }
            }
            for index in messages.indices where [.waiting, .preparing, .typing].contains(messages[index].stage) {
                messages[index].existingIDs.insert(entry.id)
            }
            // Codex can combine a promoted batch into one canonical user message. Match
            // the whole ordered batch before attempting an individual acknowledgement.
            let batches = Set(messages.compactMap(\.deliveryBatch))
            for batch in batches {
                let group = messages.filter { $0.deliveryBatch == batch }
                guard group.count > 1, group.allSatisfy({ $0.agentID == "codex" && !$0.existingIDs.contains(entry.id) }) else { continue }
                var combined = group[0]
                combined.expectedText = group.map(\.expectedText).joined(separator: "\n")
                combined.imagePaths = group.flatMap(\.imagePaths)
                guard Self.matches(entry, combined) else { continue }
                let ids = group.map { $0.entry.id }
                messages.removeAll { $0.deliveryBatch == batch }
                for index in messages.indices { messages[index].existingIDs.insert(entry.id) }
                var delivered = entry
                delivered.replacesPendingIDs = ids
                return delivered
            }
            let resultCommand = Self.resultCommand(entry)
            if let command = resultCommand {
                guard seenResultIDs.insert(entry.id).inserted else { return entry }
                // An invocation and its later result acknowledge the same send.
                if acknowledgedCommands[command, default: 0] > 0 {
                    acknowledgedCommands[command, default: 0] -= 1
                    return entry
                }
            }
            guard let index = messages.firstIndex(where: { message in
                [Stage.sent, .delivering, .unconfirmed].contains(message.stage) && !message.existingIDs.contains(entry.id) && Self.matches(entry, message)
            }) else { return entry }
            var delivered = entry
            let message = messages.remove(at: index)
            delivered.replacesPendingID = message.entry.id
            if resultCommand == nil, let command = message.commandName, ["compact", "model"].contains(command) {
                acknowledgedCommands[command, default: 0] += 1
            }
            for i in messages.indices { messages[i].existingIDs.insert(entry.id) }
            return delivered
        }
    }

    /// A stopped agent can put a message back in its input box without a transcript line.
    func isRestored(in screen: String) -> Bool {
        // Native promotion can briefly restore input while interrupting and resubmitting.
        // That intermediate frame is not evidence that the promoted queue was cancelled.
        guard !messages.contains(where: { $0.entry.deliveryRequested == true }) else { return false }
        let sent = messages.filter(\.submitted).flatMap { message -> [String] in
            var parts = message.entry.text.isEmpty ? [] : [message.entry.text]
            if !message.imagePaths.isEmpty { parts.append("[Image #") }
            return parts
        }
        return ComposerMessage.restoredLength(screen: screen, sent: sent) > 0
    }

    mutating func update(id: String, stage: Stage, detail: String? = nil, attachments: [ComposerAttachment]? = nil,
                         files: [ComposerMessage.OutgoingFile]? = nil) {
        guard let index = messages.firstIndex(where: { $0.entry.id == id }) else { return }
        messages[index].stage = stage
        messages[index].detail = detail
        messages[index].changedAt = Date()
        if let attachments { messages[index].attachments = attachments }
        if let files { messages[index].files = files }
    }

    mutating func hold(reason: String) {
        queuePaused = true
        sendNowEnabled = false
        for index in messages.indices where messages[index].stage != .waiting && messages[index].stage != .failed {
            messages[index].stage = messages[index].submitted ? .unconfirmed : .failed
            messages[index].detail = reason
            messages[index].changedAt = Date()
        }
    }

    mutating func adoptInitialSession(_ sessionID: String) {
        guard !queuePaused else { return }
        for index in messages.indices where messages[index].sessionID == nil { messages[index].sessionID = sessionID }
    }

    mutating func replacedSession() {
        hold(reason: "The agent conversation changed. Restore this input for review before sending it to the new session.")
        for index in messages.indices {
            if messages[index].stage != .waiting { messages[index].stage = .failed }
            messages[index].deliveryBatch = nil
            messages[index].submitted = false
            messages[index].entry.deliveryRequested = false
        }
    }

    mutating func recoverAfterLaunch() {
        guard !isEmpty else { queuePaused = false; return }
        hold(reason: "Restored after relaunch. Delivery was not confirmed; nothing was replayed.")
    }

    mutating func expire(now: Date = Date()) -> Bool {
        var changed = false
        for index in messages.indices where [.sent, .delivering].contains(messages[index].stage) && now.timeIntervalSince(messages[index].changedAt) > 30 {
            messages[index].stage = .unconfirmed
            messages[index].detail = "No transcript acknowledgement yet. Check the terminal or restore a copy for review."
            changed = true
        }
        return changed
    }

    mutating func move(id: String, offset: Int) {
        guard let index = messages.firstIndex(where: { $0.entry.id == id && $0.stage == .waiting }) else { return }
        let waiting = messages.indices.filter { messages[$0].stage == .waiting }
        guard let position = waiting.firstIndex(of: index), waiting.indices.contains(position + offset) else { return }
        messages.swapAt(index, waiting[position + offset])
    }

    mutating func remove(id: String) { messages.removeAll { $0.entry.id == id } }
    mutating func removeAll() {
        messages.removeAll()
        acknowledgedCommands.removeAll()
        seenResultIDs.removeAll()
    }

    private static func resultCommand(_ entry: ReaderEntry) -> String? {
        guard entry.kind == .notice else { return nil }
        if entry.text == "Conversation compacted" { return "compact" }
        if entry.text.hasPrefix("Model changed to ") || entry.text.hasPrefix("Set model to ") { return "model" }
        return nil
    }

    private static func matches(_ entry: ReaderEntry, _ message: Message) -> Bool {
        guard entry.kind == .user || entry.kind == .notice else { return false }
        var text = entry.text
        if entry.kind == .notice {
            guard let command = message.commandName else { return false }
            // Compaction records omit the invocation and its optional instructions.
            if text == "Conversation compacted" { return command == "compact" }
            // A picker can record its result without recording the slash input itself.
            if command == "model" {
                let prefix = message.agentID == "codex" ? "Model changed to " : "Set model to "
                if text.hasPrefix(prefix), let invocation = ReaderCommandLogic.invocation(message.expectedText) {
                    let model = String(text.dropFirst(prefix.count))
                    return !model.isEmpty && (invocation.arguments.isEmpty || invocation.arguments == model)
                }
            }
            guard text.hasPrefix("Ran /") else { return false }
            text = String(text.dropFirst(4))
        }
        if !message.imagePaths.isEmpty {
            // The TUI replaces image paths with chips. Codex also writes image delimiters.
            text = text.replacingOccurrences(of: #"\[Image #\d+\]|</?image[^>]*>|\[/?Image \d+\]"#,
                                             with: "", options: .regularExpression)
            if entry.images.count < message.imagePaths.count {
                // An agent can leave an unsupported picture as a path instead of a chip.
                for path in message.imagePaths {
                    let escaped = ShellEscape.escape(path)
                    if text.contains(escaped) { text = text.replacingOccurrences(of: escaped, with: "") }
                    else if text.contains(path) { text = text.replacingOccurrences(of: path, with: "") }
                    else { return false }
                }
            }
        }
        let normalized = ComposerMessage.prepare(text) ?? ""
        if normalized == message.expectedText { return true }
        // Codex dispatches an inline /plan as an arguments-only UserMessage, retaining images.
        // Unsupported command fallbacks keep the prefix and match the ordinary path above.
        if entry.kind == .user, message.agentID == "codex", message.commandName == "plan",
           let invocation = ComposerCommandTransport.invocation(message.expectedText), !invocation.arguments.isEmpty {
            return normalized == invocation.arguments
        }
        return false
    }
}
