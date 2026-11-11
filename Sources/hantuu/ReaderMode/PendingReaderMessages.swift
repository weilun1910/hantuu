import Foundation

/// Messages reader mode has sent that the transcript has not acknowledged yet.
/// This lives on the chat, so changing the selected chat does not lose its queue.
struct PendingReaderMessages {
    private struct Message {
        var entry: ReaderEntry
        var existingIDs: Set<String>
        var expectedText: String
        var imagePaths: [String]
    }

    private var messages: [Message] = []
    var entries: [ReaderEntry] { messages.map(\.entry) }
    var isEmpty: Bool { messages.isEmpty }

    mutating func enqueue(id: String, text: String?, files: [ComposerMessage.OutgoingFile],
                          agentID: String, existing: [ReaderEntry]) {
        let steps = ComposerMessage.steps(text: text, files: files, agentID: agentID)
        let body = steps.compactMap { step -> String? in
            if case .paste(let text) = step { return text }
            return nil
        }.joined()
        let paths = files.filter(\.image).map(\.path)
        var entry = ReaderEntry(id: id, kind: .user, text: ComposerMessage.prepare(body) ?? "", images: paths)
        entry.pending = true
        messages.append(Message(entry: entry, existingIDs: Set(existing.map(\.id)),
                                expectedText: entry.text, imagePaths: paths))
    }

    /// Each delivered entry consumes at most one pending send. Old identical prompts and
    /// repeated reloads cannot acknowledge a newer send with the same words.
    mutating func reconcile(_ entries: [ReaderEntry]) -> [ReaderEntry] {
        entries.map { entry in
            if entry.kind == .notice && (entry.text == "Interrupted" || entry.text == "Turn interrupted") {
                messages.removeAll { !$0.existingIDs.contains(entry.id) }
            }
            guard let index = messages.firstIndex(where: { message in
                !message.existingIDs.contains(entry.id) && Self.matches(entry, message)
            }) else { return entry }
            var delivered = entry
            delivered.replacesPendingID = messages.remove(at: index).entry.id
            for i in messages.indices { messages[i].existingIDs.insert(entry.id) }
            return delivered
        }
    }

    /// A stopped agent can put a message back in its input box without a transcript line.
    func isRestored(in screen: String) -> Bool {
        let sent = messages.flatMap { message -> [String] in
            var parts = message.entry.text.isEmpty ? [] : [message.entry.text]
            if !message.imagePaths.isEmpty { parts.append("[Image #") }
            return parts
        }
        return ComposerMessage.restoredLength(screen: screen, sent: sent) > 0
    }

    mutating func remove(id: String) { messages.removeAll { $0.entry.id == id } }
    mutating func removeAll() { messages.removeAll() }

    private static func matches(_ entry: ReaderEntry, _ message: Message) -> Bool {
        guard entry.kind == .user || entry.kind == .notice else { return false }
        var text = entry.text
        if entry.kind == .notice {
            guard text.hasPrefix("Ran /"), message.expectedText.hasPrefix("/") else { return false }
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
        return (ComposerMessage.prepare(text) ?? "") == message.expectedText
    }
}
