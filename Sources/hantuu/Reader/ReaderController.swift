import AppKit
import Combine

private struct ReaderPayload: Encodable {
    var chatID: String?
    var entries: [ReaderEntry]
    var emptyText: String
    /// The chat's folder, so reader mode can show paths inside it relative to it.
    var base: String? = nil
}

/// Shows the selected chat's transcript in the reader page and keeps it live.
final class ReaderController {
    let page: WebPage
    private let model: AppModel
    private var shownChatID: UUID?
    private var bag = Set<AnyCancellable>()

    /// Reader mode makes a second one for the main area, with `layout=main` in the page URL.
    init(model: AppModel, page: String = "reader.html", identifier: String = "hantuu.reader", focusless: Bool = false) {
        self.page = WebPage(page: page, identifier: identifier, focusless: focusless)
        self.model = model
        self.page.onReady = { [weak self] in self?.reload() }
        self.page.onMessage = { [weak self] msg in self?.handle(msg) }
        model.$selectedChatID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &bag)
        model.readerReload
            .sink { [weak self] id in if id == model.selectedChatID { self?.reload() } }
            .store(in: &bag)
        model.readerAppend
            .sink { [weak self] id, entries in
                guard let self, id == self.shownChatID else { return }
                self.page.call("append", ReaderPayload(chatID: id.uuidString, entries: entries, emptyText: ""))
            }
            .store(in: &bag)
    }

    var view: NSView { page.webView }

    func reload() {
        let chat = model.selectedChat
        shownChatID = chat?.id
        let empty: String
        if let chat {
            if chat.agent.transcript == nil {
                empty = "\(chat.agent.name) doesn't keep a transcript hantuu can read yet. The terminal has the whole conversation."
            } else if chat.follower == nil {
                empty = "The conversation shows up here once you send \(chat.agent.name) your first message."
            } else {
                empty = "Nothing to show yet."
            }
        } else {
            empty = "Pick a chat to read it here."
        }
        page.call("reset", ReaderPayload(chatID: chat?.id.uuidString, entries: chat?.allEntries ?? [], emptyText: empty,
                                         base: chat.map { model.workingDirectory(of: $0) }))
    }

    private func handle(_ msg: [String: Any]) {
        let base = model.selectedChat.flatMap { model.project($0.projectID)?.path }
        switch msg["type"] as? String {
        case "open":
            guard let path = msg["path"] as? String else { return }
            let line = msg["line"] as? Int
            if var route = FileRouter.shared.route(for: path, base: base) {
                if case .code(let p, _) = route, let line { route = .code(p, line) }
                FileRouter.shared.perform(route)
            }
        case "link":
            guard let href = msg["href"] as? String else { return }
            let b = (msg["base"] as? String) ?? base
            FileRouter.shared.open(href.removingPercentEncoding ?? href, base: b)
        case "popout":
            // The pop-out button on an image or PDF: open it as a tab in the Code tab.
            ReaderPopout.open(msg, model: model)
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
