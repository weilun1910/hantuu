import AppKit
import SwiftUI

struct DiffPayload: Encodable {
    struct Comment: Encodable, Equatable {
        var id: String
        var side: String
        var start: Int
        var end: Int
        var body: String
        var quoted: [String] = []
        var revision: String? = nil
    }

    var key: String
    var path: String
    var rows: [DiffRow]
    var comments: [Comment]
    var keepScroll: Bool
    var notice: String? = nil
    var large: Int? = nil
    var context: String? = nil
    var scrollTop: Double? = nil
    var revision: String? = nil
    var token: String? = nil
    var chat: String? = nil
    var draft: ReviewCommentDraft? = nil
}

/// The diff web page (diff.html): one file's unified diff with highlighting, line numbers and
/// inline comment boxes. Comments live in Swift; the page only draws them and reports edits.
final class DiffPage {
    let page = WebPage(page: "diff.html", identifier: "hantuu.diff")
    weak var center: ReviewCenter?
    private var lastShown: DiffPayload?
    private var cleared: String?
    // Old render callbacks may save drafts only to their original chat/file. Mutation
    // actions still require the current token. This also covers a save during clear().
    private var draftOrigins: [String: (chat: String?, key: String, context: String?)] = [:]
    private var draftOriginOrder: [String] = []

    init() {
        page.onReady = { [weak self] in
            guard let self else { return }
            if let p = self.lastShown { self.page.call("show", p) } else if let c = self.cleared { self.page.call("clear", c) }
        }
        page.onMessage = { [weak self] msg in self?.handle(msg) }
    }

    var view: NSView { page.webView }

    func show(_ payload: DiffPayload) {
        var p = payload
        p.context = center?.panelContextKey
        p.token = UUID().uuidString
        p.chat = center?.chatID?.uuidString
        if let token = p.token {
            draftOrigins[token] = (p.chat, p.key, p.context)
            draftOriginOrder.append(token)
            if draftOriginOrder.count > 32 { draftOrigins.removeValue(forKey: draftOriginOrder.removeFirst()) }
        }
        p.draft = ReviewCommentDraftStore.shared.get(chat: p.chat, key: p.key)
        p.scrollTop = center?.diffScroll[p.key]
        lastShown = p
        cleared = nil
        page.call("show", p)
    }

    func setComments(_ c: [DiffPayload.Comment]) {
        lastShown?.comments = c
        page.call("setComments", c)
    }

    func clear(_ text: String) {
        lastShown = nil
        cleared = text
        page.call("clear", text)
    }

    /// Lets the web view go. WebKit holds a page's message handler strongly, so without this
    /// a repository section's diff page would outlive the section, with its web process.
    func close() {
        center = nil
        page.webView.configuration.userContentController.removeScriptMessageHandler(forName: "hantuu")
    }

    private func handle(_ msg: [String: Any]) {
        if msg["type"] as? String == "commentDraft" {
            guard let token = msg["token"] as? String, let origin = draftOrigins[token],
                  msg["chat"] as? String == origin.chat, msg["context"] as? String == origin.context else { return }
            let draft = (msg["draft"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { try? JSONDecoder().decode(ReviewCommentDraft.self, from: $0) }
            if lastShown?.token == token { lastShown?.draft = draft }
            ReviewCommentDraftStore.shared.set(draft, chat: origin.chat, key: origin.key)
            return
        }
        guard let center else { return }
        if msg["type"] as? String != "scroll" {
            guard let shown = lastShown, msg["token"] as? String == shown.token,
                  msg["chat"] as? String == center.chatID?.uuidString,
                  msg["context"] as? String == center.panelContextKey else { return }
        }
        switch msg["type"] as? String {
        case "scroll":
            guard let key = msg["key"] as? String, let top = msg["top"] as? Double,
                  msg["context"] as? String == center.panelContextKey else { return }
            center.recordDiffScroll(key: key, top: top)
        case "addComment":
            guard let path = msg["path"] as? String, let start = msg["start"] as? Int, let end = msg["end"] as? Int,
                  let body = msg["body"] as? String else { return }
            center.addComment(path: path, side: (msg["side"] as? String) ?? "new", start: start, end: end,
                              quoted: (msg["quoted"] as? [String]) ?? [], body: body, revision: lastShown?.revision)
        case "editComment":
            if let id = msg["id"] as? String, let body = msg["body"] as? String { center.editComment(id: id, body: body) }
        case "removeComment":
            if let id = msg["id"] as? String { center.removeComment(id: id) }
        case "send":
            center.sendComments()
        case "showLarge":
            center.loadDiff(force: true)
        case "openLine":
            if let line = msg["line"] as? Int { center.openLine(line, side: (msg["side"] as? String) ?? "new") }
        default:
            break
        }
    }
}

/// Hosts the diff web view inside SwiftUI. The web view is long-lived and owned by DiffPage;
/// this container just holds it while the Changes tab shows a diff.
struct DiffWebView: NSViewRepresentable {
    let webView: NSView

    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        attach(to: box)
        return box
    }

    func updateNSView(_ box: NSView, context: Context) { attach(to: box) }

    private func attach(to box: NSView) {
        guard webView.superview !== box else { return }
        webView.removeFromSuperview()
        webView.frame = box.bounds
        webView.autoresizingMask = [.width, .height]
        box.addSubview(webView)
    }
}
