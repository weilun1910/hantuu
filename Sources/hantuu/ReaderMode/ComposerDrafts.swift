import AppKit

/// Stored input is never submitted while restoring. Main and Side use distinct scope keys.
struct ComposerDraft: Codable, Equatable {
    var text: String
    var selectionLocation: Int
    var selectionLength: Int
    var attachments: [ComposerAttachment]
    var updatedAt: Date

    init(text: String, selection: NSRange, attachments: [ComposerAttachment], updatedAt: Date = Date()) {
        self.text = text
        selectionLocation = selection.location
        selectionLength = selection.length
        self.attachments = attachments
        self.updatedAt = updatedAt
    }

    var clampedSelection: NSRange {
        let count = (text as NSString).length
        var location = min(max(0, selectionLocation), count)
        let ns = text as NSString
        if location < count { location = ns.rangeOfComposedCharacterSequence(at: location).location }
        var end = min(count, location + min(max(0, selectionLength), count - location))
        if end < count && end > location { end = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: end - 1)) }
        return NSRange(location: location, length: end - location)
    }

    func restoredAttachments() -> [ComposerAttachment] {
        attachments.map { original in
            var item = original
            if item.preparation == .preparing {
                item.preparation = .failed("Preparation was interrupted. Retry or remove this attachment.")
            } else if !FileManager.default.fileExists(atPath: (item.preparedURL ?? item.url).path) {
                item.preparation = .failed("This file is missing. Reattach it or remove this attachment.")
            }
            return item
        }
    }
}

/// Main-thread owner, with debounced atomic persistence and explicit lifecycle flush.
final class ComposerDraftStore {
    private struct Document: Codable { var version = 1; var drafts: [String: ComposerDraft] }
    private let url: URL
    private var drafts: [String: ComposerDraft] = [:]
    private var pending: DispatchWorkItem?
    private var dirty = false
    var onFailure: ((Error) -> Void)?

    init(url: URL = Paths.dataDir.appendingPathComponent("composer-drafts.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 {
            drafts = document.drafts
        }
    }
    deinit { pending?.cancel() }
    private func key(_ chatID: UUID, _ scope: String) -> String { chatID.uuidString + ":" + scope }
    func draft(chatID: UUID, scope: String = "main") -> ComposerDraft? { drafts[key(chatID, scope)] }
    func save(_ draft: ComposerDraft?, chatID: UUID, scope: String = "main") {
        drafts[key(chatID, scope)] = draft
        dirty = true
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do { try self.flush() } catch { self.onFailure?(error) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    func flush() throws {
        pending?.cancel()
        pending = nil
        guard dirty else { return }
        let data = try JSONEncoder().encode(Document(drafts: drafts))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        dirty = false
    }
    var referencedAttachmentPaths: Set<String> {
        Set(drafts.values.flatMap { $0.attachments }.flatMap { [$0.url, $0.preparedURL].compactMap { $0?.standardizedFileURL.path } })
    }
}

/// Only pass entries from the main chat parser (never a subagent or Side transcript).
enum ComposerPromptHistory {
    static func prompts(from entries: [ReaderEntry]) -> [String] {
        entries.compactMap { entry in
            guard entry.kind == .user, entry.pending != true, !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let value = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let excluded = ["<system-reminder>", "<task-notification>", "<environment_context>", "<INSTRUCTIONS>", "# AGENTS.md instructions", "<user_instructions>", "<turn_aborted>", "<subagent_notification>"]
            guard !excluded.contains(where: value.hasPrefix) else { return nil }
            // Keep repeated human prompts: equality is not message identity.
            return entry.text
        }
    }
}

struct ComposerPromptRecall {
    private(set) var index: Int?
    private var savedText = ""
    private var savedSelection = NSRange(location: 0, length: 0)
    mutating func reset() { index = nil; savedText = "" }
    mutating func move(older: Bool, text: String, selection: NSRange, history: [String]) -> (String, NSRange)? {
        guard selection.length == 0, !history.isEmpty else { return nil }
        let ns = text as NSString
        guard selection.location <= ns.length else { return nil }
        if older {
            // First logical line only; ordinary multiline motion stays with AppKit.
            guard !ns.substring(to: selection.location).contains("\n") else { return nil }
            if index == nil { savedText = text; savedSelection = selection }
            let next = min(history.count - 1, max(0, (index ?? history.count) - 1))
            index = next
            return (history[next], NSRange(location: 0, length: 0))
        }
        guard let current = index, !ns.substring(from: selection.location).contains("\n") else { return nil }
        let next = current + 1
        if next < history.count {
            index = next
            return (history[next], NSRange(location: (history[next] as NSString).length, length: 0))
        }
        let result = (savedText, savedSelection)
        reset()
        return result
    }
}
