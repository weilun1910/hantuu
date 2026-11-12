import Foundation
import Combine

/// Durable receipts for review feedback. Transport and acknowledgement remain reader-owned.
final class PanelFeedbackDelivery: ObservableObject {
    static let shared = PanelFeedbackDelivery()
    enum State: String, Codable { case queued, sending, delivered, failed }
    struct Batch: Codable, Identifiable {
        var id: String
        var chatID: UUID
        var comments: [ReviewComment]
        var text: String
        var state: State
        var detail: String?
    }
    @Published private(set) var batches: [Batch] = []
    private var subscriptions = Set<AnyCancellable>()
    private weak var model: AppModel?
    private var timer: Timer?
    private var acknowledgements: [String: ([ReviewComment]) -> Void] = [:]
    private let url: URL?

    init(url: URL? = Paths.dataDir.appendingPathComponent("panel-feedback.json")) {
        self.url = url
        if let url { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder.hantuu.decode([Batch].self, from: data) {
            batches = saved.map { batch in
                var b = batch
                if b.state == .queued || b.state == .sending {
                    b.state = .failed
                    b.detail = "Delivery was not confirmed before restart. Check the conversation before retrying."
                }
                return b
            }
        }
    }

    deinit { timer?.invalidate() }

    func latest(for chatID: UUID?) -> Batch? { batches.last { $0.chatID == chatID } }

    func connect(_ model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        subscriptions.removeAll()
        model.readerAppend.sink { [weak self] chatID, entries in
            for entry in entries {
                if let id = entry.replacesPendingID { self?.acknowledge(id: id, chatID: chatID) }
                for id in entry.replacesPendingIDs ?? [] { self?.acknowledge(id: id, chatID: chatID) }
            }
        }.store(in: &subscriptions)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkPending() }
    }

    @discardableResult
    func send(comments: [ReviewComment], folder: String, chatID: UUID, model: AppModel,
              acknowledged: @escaping ([ReviewComment]) -> Void) -> Bool {
        connect(model)
        guard !comments.isEmpty, !batches.contains(where: { $0.chatID == chatID && ($0.state == .queued || $0.state == .sending) }) else { return false }
        let id = "pending-review-" + UUID().uuidString
        let text = CommentMessage.build(comments, folder: folder)
        let busy = model.chats.first { $0.id == chatID }?.activity == .working
        batches.append(Batch(id: id, chatID: chatID, comments: comments, text: text, state: busy ? .queued : .sending))
        acknowledgements[id] = acknowledged
        save()
        guard ReaderModeController.main?.sendPanelFeedback(text: text, chatID: chatID, id: id) == true else {
            fail(id: id, detail: "The agent is not ready. Resume the chat or copy the review; comments are retained.")
            return false
        }
        return true
    }

    func acknowledge(id: String, chatID: UUID) {
        guard let i = batches.firstIndex(where: { $0.id == id && $0.chatID == chatID && $0.state != .delivered }) else { return }
        batches[i].state = .delivered
        batches[i].detail = nil
        let comments = batches[i].comments
        save()
        acknowledgements.removeValue(forKey: id)?(comments)
    }

    private func fail(id: String, detail: String) {
        guard let i = batches.firstIndex(where: { $0.id == id }) else { return }
        batches[i].state = .failed
        batches[i].detail = detail
        acknowledgements.removeValue(forKey: id)
        save()
    }

    private func checkPending() {
        guard let model else { return }
        for b in batches where b.state == .queued || b.state == .sending {
            guard let chat = model.chats.first(where: { $0.id == b.chatID }), chat.status != .ended,
                  chat.pendingMessages.entries.contains(where: { $0.id == b.id }) else {
                fail(id: b.id, detail: "Delivery was interrupted or unconfirmed. Check the conversation before retrying.")
                continue
            }
            if chat.agent.transcript == nil, ReaderModeController.main?.hasPanelFeedbackTransport(id: b.id) != true {
                chat.pendingMessages.remove(id: b.id)
                fail(id: b.id, detail: "This agent has no transcript acknowledgement. Check its terminal before retrying; your comments are retained.")
            }
        }
    }

    private func save() {
        guard let url else { return }
        Paths.ensure(url.deletingLastPathComponent())
        if let data = try? JSONEncoder.hantuu.encode(batches) { try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
