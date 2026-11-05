import AppKit
import Combine

private struct ReaderPayload: Encodable {
    var chatID: String?
    var entries: [ReaderEntry]
    var emptyText: String
}

/// Shows the selected chat's transcript in the reader page and keeps it live.
final class ReaderController {
    let page = WebPage(page: "reader.html", identifier: "hantuu.reader")
    private let model: AppModel
    private var shownChatID: UUID?
    private var bag = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        page.onReady = { [weak self] in self?.reload() }
        page.onMessage = { [weak self] msg in self?.handle(msg) }
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
        page.call("reset", ReaderPayload(chatID: chat?.id.uuidString, entries: chat?.allEntries ?? [], emptyText: empty))
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
        default:
            break
        }
    }
}

struct CodePayload: Encodable {
    var path: String
    var name: String
    var text: String
    var preview: Bool
    var line: Int?
    var base: String
    var links: [DetectedPath]
    var truncated: Bool
    var error: String?
}

/// Read-only code viewer: one web view, the selected code tab rendered into it.
final class CodeViewerController {
    let page = WebPage(page: "code.html", identifier: "hantuu.code")
    private let model: AppModel
    private var lastKey = ""
    private var bag = Set<AnyCancellable>()
    static let maxBytes = 3_000_000

    init(model: AppModel) {
        self.model = model
        page.onReady = { [weak self] in
            self?.lastKey = ""
            self?.render()
        }
        page.onMessage = { msg in
            let base = msg["base"] as? String
            switch msg["type"] as? String {
            case "open":
                if let p = msg["path"] as? String { FileRouter.shared.open(p, base: base) }
            case "link":
                if let h = msg["href"] as? String { FileRouter.shared.open(h.removingPercentEncoding ?? h, base: base) }
            default: break
            }
        }
        model.$codeTabs.combineLatest(model.$selectedCodeTabID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.render() }
            .store(in: &bag)
    }

    var view: NSView { page.webView }

    func render() {
        guard let id = model.selectedCodeTabID, let tab = model.codeTabs.first(where: { $0.id == id }) else {
            if lastKey != "none" { page.call("clear") }
            lastKey = "none"
            return
        }
        let key = "\(tab.path)|\(tab.preview)|\(tab.line ?? 0)"
        guard key != lastKey else { return }
        lastKey = key
        page.call("show", Self.payload(for: tab))
    }

    static func payload(for tab: CodeTab) -> CodePayload {
        let base = (tab.path as NSString).deletingLastPathComponent
        var p = CodePayload(path: tab.path, name: tab.name, text: "", preview: tab.preview && tab.isMarkdown,
                            line: tab.line, base: base, links: [], truncated: false, error: nil)
        guard let h = FileHandle(forReadingAtPath: tab.path) else {
            p.error = "Couldn't open \(tab.name)."
            return p
        }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: maxBytes + 1)) ?? Data()
        p.truncated = data.count > maxBytes
        let slice = data.prefix(maxBytes)
        if slice.prefix(8192).contains(0) {
            p.error = "\(tab.name) isn't a text file."
            return p
        }
        p.text = String(data: slice, encoding: .utf8) ?? String(decoding: slice, as: UTF8.self)
        if p.preview { p.links = PathDetector.detect(in: p.text, base: base) }
        return p
    }
}
