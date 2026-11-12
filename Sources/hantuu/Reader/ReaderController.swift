import AppKit
import Combine

private struct ReaderPayload: Encodable {
    var chatID: String?
    var entries: [ReaderEntry]
    var pending: [ReaderEntry] = []
    var emptyText: String
    /// The chat's folder, so reader mode can show paths inside it relative to it.
    var base: String? = nil
}

/// Shows the selected chat's transcript in the reader page and keeps it live.
final class ReaderController {
    let page: WebPage
    private let model: AppModel
    private var shownChatID: UUID?
    private var externalPayload: ReaderPayload?
    private var bag = Set<AnyCancellable>()
    private var pendingSubscription: AnyCancellable?
    /// Esc shrinks an opened-out image or PDF (FileViewer/ReaderMedia.swift).
    let mediaKeys: ReaderMediaKeys
    var onSendNow: ((UUID, String) -> Void)?
    var onQueueAction: ((UUID, String, String) -> Void)?
    var onEditAsNew: ((UUID, String) -> Void)?
    var onFocusComposer: (() -> Void)?
    let interaction: ReaderInteraction
    var retryReading: (() -> Void)?

    /// Reader mode makes a second one for the main area, with `layout=main` in the page URL.
    init(model: AppModel, page: String = "reader.html", identifier: String = "hantuu.reader", focusless: Bool = false, observesSelection: Bool = true) {
        self.page = WebPage(page: page, identifier: identifier, focusless: focusless)
        self.model = model
        mediaKeys = ReaderMediaKeys(page: self.page)
        interaction = ReaderInteraction(page: self.page, model: model, ownsMainChat: focusless && observesSelection, observesSelection: observesSelection)
        self.page.onReady = { [weak self] in self?.reload() }
        self.page.onMessage = { [weak self] msg in self?.handle(msg) }
        guard observesSelection else { return }
        model.$selectedChatID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &bag)
        model.readerReload
            .sink { [weak self] id in
                guard let self, id == self.model.selectedChatID else { return }
                self.reload()
            }
            .store(in: &bag)
        model.readerAppend
            .sink { [weak self] id, entries in
                guard let self, id == self.shownChatID else { return }
                self.page.call("append", ReaderPayload(chatID: id.uuidString, entries: ReaderDelegation.applying(model.selectedChat?.readerWork, to: entries), pending: model.selectedChat?.pendingMessages.entries ?? [], emptyText: ""))
            }
            .store(in: &bag)
    }

    var view: NSView { page.webView }

    func showTranscript(id: String, entries: [ReaderEntry], base: String?, emptyText: String) {
        externalPayload = ReaderPayload(chatID: id, entries: entries, emptyText: emptyText, base: base)
        reload()
    }

    func appendTranscript(_ entries: [ReaderEntry]) {
        guard var payload = externalPayload else { return }
        payload.entries = ReaderEntries.merging(payload.entries, entries)
        externalPayload = payload
        payload.entries = entries
        page.call("append", payload)
    }

    /// Side answers grow in place. Keep the reader's scroll position and unchanged nodes.
    func updateTranscript(id: String, entries: [ReaderEntry], base: String?, emptyText: String) {
        let payload = ReaderPayload(chatID: id, entries: entries, emptyText: emptyText, base: base)
        externalPayload = payload
        page.call("reconcile", payload)
    }

    func reload() {
        defer { interaction.reset() }
        if let externalPayload { page.call("reset", externalPayload); return }
        let chat = model.selectedChat
        shownChatID = chat?.id
        pendingSubscription = chat?.$pendingMessages
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak chat] _ in
                guard let self, let chat, self.shownChatID == chat.id else { return }
                self.page.call("pending", ReaderPayload(chatID: chat.id.uuidString, entries: [],
                                                        pending: chat.pendingMessages.entries, emptyText: ""))
            }
        let entries = chat.map { $0.pendingMessages.reconcile($0.allEntries) } ?? []
        page.call("reset", ReaderPayload(chatID: chat?.id.uuidString, entries: entries, pending: chat?.pendingMessages.entries ?? [], emptyText: Self.emptyText(for: chat),
                                         base: chat.map { model.workingDirectory(of: $0) }))
    }

    /// What the reader says while a chat has nothing to show.
    static func emptyText(for chat: Chat?) -> String {
        guard let chat else { return "Pick a chat to read it here." }
        if chat.agent.transcript == nil {
            return "\(chat.agent.name) doesn't keep a transcript hantuu can read yet. The terminal has the whole conversation."
        }
        // Claude Code writes the transcript with the first message, so a new chat or one just
        // cleared with /clear has a follower waiting on a file that doesn't exist yet.
        if chat.follower.map({ !FileManager.default.fileExists(atPath: $0.url.path) }) ?? true {
            return "The conversation shows up here once you send \(chat.agent.name) your first message."
        }
        return "Nothing to show yet."
    }

    private func handle(_ msg: [String: Any]) {
        guard !interaction.message(msg) else { return }
        let base = model.selectedChat.flatMap { model.project($0.projectID)?.path }
        switch msg["type"] as? String {
        case "queueAction", "editAsNew":
            guard let raw = msg["chatID"] as? String, let chatID = UUID(uuidString: raw),
                  chatID == shownChatID, chatID == model.selectedChatID, let id = msg["id"] as? String else { return }
            if msg["type"] as? String == "editAsNew" { onEditAsNew?(chatID, id) }
            else if let action = msg["action"] as? String { onQueueAction?(chatID, id, action) }
        case "sendNow":
            guard let raw = msg["chatID"] as? String, let chatID = UUID(uuidString: raw),
                  chatID == shownChatID, chatID == model.selectedChatID,
                  let id = msg["id"] as? String else { return }
            onSendNow?(chatID, id)
        case "focusComposer":
            onFocusComposer?()
        case "retryReader":
            if let retryReading { retryReading() } else { model.selectedChat?.follower?.retry() }
            interaction.refresh()
        case "selectAgent":
            guard let id = msg["id"] as? String, let chat = model.selectedChat else { return }
            if let agent = chat.readerWork?.subagents.first(where: { $0.id == id }) {
                model.subagentBrowser.selection = SubagentBrowser.Selection(chatID: chat.id, agent: SidebarSubagent(agent))
            } else { model.selectSubagent(id, in: chat.id) }
        case "open":
            guard let path = msg["path"] as? String else { return }
            let line = msg["line"] as? Int
            if var route = FileRouter.shared.route(for: path, base: base) {
                if case .code(let p, _) = route, let line { route = .code(p, line) }
                FileRouter.shared.perform(route)
            } else { page.call("readerFileResult", ["path": path]) }
        case "link":
            guard let href = msg["href"] as? String else { return }
            let b = (msg["base"] as? String) ?? base
            FileRouter.shared.open(href.removingPercentEncoding ?? href, base: b)
        case "popout":
            // The pop-out button on an image or PDF: open it as a tab in the Code tab.
            ReaderPopout.open(msg, model: model)
        case "mediaExpanded":
            mediaKeys.update(expanded: msg["count"] as? Int ?? 0)
        case "pdfInfo":
            guard let id = msg["id"] as? String, let path = msg["path"] as? String else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let data = PDFThumbnails.info(path: path)
                let info = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                let pages = info?["pages"] as? [[String: Any]] ?? []
                DispatchQueue.main.async { [weak self] in
                    self?.page.call("pdfInfo", ["id": id, "path": path, "pages": pages] as [String: Any])
                }
            }
        case "copy":
            // Reader mode's copy buttons on messages and code blocks.
            guard let text = msg["text"] as? String, !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        default:
            break
        }
    }
}
