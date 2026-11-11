import AppKit
import SwiftUI

struct DiffPayload: Encodable {
    struct Comment: Encodable, Equatable {
        var id: String
        var side: String
        var start: Int
        var end: Int
        var body: String
    }

    var key: String
    var path: String
    var rows: [DiffRow]
    var comments: [Comment]
    var keepScroll: Bool
    var notice: String? = nil
    var large: Int? = nil
}

/// The diff web page (diff.html): one file's unified diff with highlighting, line numbers and
/// inline comment boxes. Comments live in Swift; the page only draws them and reports edits.
final class DiffPage {
    let page = WebPage(page: "diff.html", identifier: "hantuu.diff")
    weak var center: ReviewCenter?
    private var lastShown: DiffPayload?
    private var cleared: String?

    init() {
        page.onReady = { [weak self] in
            guard let self else { return }
            if let p = self.lastShown { self.page.call("show", p) } else if let c = self.cleared { self.page.call("clear", c) }
        }
        page.onMessage = { [weak self] msg in self?.handle(msg) }
    }

    var view: NSView { page.webView }

    func show(_ p: DiffPayload) {
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
        guard let center else { return }
        switch msg["type"] as? String {
        case "addComment":
            guard let path = msg["path"] as? String, let start = msg["start"] as? Int, let end = msg["end"] as? Int,
                  let body = msg["body"] as? String else { return }
            center.addComment(path: path, side: (msg["side"] as? String) ?? "new", start: start, end: end,
                              quoted: (msg["quoted"] as? [String]) ?? [], body: body)
        case "removeComment":
            if let id = msg["id"] as? String { center.removeComment(id: id) }
        case "send":
            center.sendComments()
        case "showLarge":
            center.loadDiff(force: true)
        case "openLine":
            if let line = msg["line"] as? Int { center.openLine(line) }
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
