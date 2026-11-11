import AppKit
import UniformTypeIdentifiers
import WebKit

/// Serves the reader and code viewer without any network access:
///   hantuu://app/<file>        bundled pages, CSS, JS libraries, KaTeX fonts
///   hantuu://file/<abs path>   local files the chat points at (images, PDFs), read-only
///   hantuu://thumb/<abs path>  PDF page images, or page sizes with ?info=1
final class HantuuSchemeHandler: NSObject, WKURLSchemeHandler {
    private var stopped = Set<ObjectIdentifier>()
    private static let thumbnailQueue = DispatchQueue(label: "local.hantuu.thumbnail-requests", qos: .userInitiated)

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let host = url.host else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        if host == "thumb" {
            // Drawn off the main thread; the task may be stopped by then.
            let path = url.path.removingPercentEncoding ?? url.path
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let h = items.first { $0.name == "h" }?.value.flatMap(Int.init) ?? 400
            let width = items.first { $0.name == "w" }?.value.flatMap(Int.init)
            let page = items.first { $0.name == "page" }?.value.flatMap(Int.init) ?? 1
            let info = items.first { $0.name == "info" }?.value == "1"
            let id = ObjectIdentifier(task)
            Self.thumbnailQueue.async {
                let data = info ? PDFThumbnails.info(path: path) : PDFThumbnails.png(path: path, page: page, width: width, height: h)
                DispatchQueue.main.async {
                    guard self.stopped.remove(id) == nil else { return }
                    self.respond(task, url: url, data: data, mime: info ? "application/json" : "image/png")
                }
            }
            return
        }
        let fileURL: URL?
        switch host {
        case "app":
            let rel = url.path.removingPercentEncoding ?? url.path
            if rel.contains("..") { fileURL = nil } else { fileURL = Paths.webRoot?.appendingPathComponent(String(rel.drop(while: { $0 == "/" }))) }
        case "file":
            let p = url.path.removingPercentEncoding ?? url.path
            fileURL = URL(fileURLWithPath: p)
        default:
            fileURL = nil
        }
        guard let fileURL, let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
            task.didFinish()
            return
        }
        let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let headers = ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-store"]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { stopped.insert(ObjectIdentifier(task)) }

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data?, mime: String) {
        guard let data else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
            task.didFinish()
            return
        }
        let headers = ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-store"]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    static func fileURLString(_ path: String) -> String {
        "hantuu://file" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
    }
}

/// A WKWebView that loads one bundled page and talks to Swift through `hantuu` messages.
class HantuuWebView: WKWebView {
    override var acceptsFirstResponder: Bool { true }
}

final class WebPage: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: HantuuWebView
    private(set) var ready = false
    private var queue: [String] = []
    var onMessage: (([String: Any]) -> Void)?
    var onReady: (() -> Void)?

    /// `focusless` makes reader mode's page, which never takes the keyboard (ReaderMode/).
    init(page: String, identifier: String, focusless: Bool = false) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(HantuuSchemeHandler(), forURLScheme: "hantuu")
        // Nothing is stored between launches.
        config.websiteDataStore = .nonPersistent()
        let ucc = WKUserContentController()
        config.userContentController = ucc
        config.preferences.isElementFullscreenEnabled = false
        webView = focusless ? FocuslessWebView(frame: .zero, configuration: config) : HantuuWebView(frame: .zero, configuration: config)
        super.init()
        ucc.add(self, name: "hantuu")
        webView.identifier = NSUserInterfaceItemIdentifier(identifier)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.isInspectable = true
        webView.allowsMagnification = true
        if let url = URL(string: "hantuu://app/\(page)") { webView.load(URLRequest(url: url)) }
    }

    /// Calls `hantuu.<fn>(<json>)` once the page is ready.
    func call(_ fn: String, _ payload: Any? = nil) {
        var arg = "null"
        if let payload {
            if let enc = payload as? Encodable, let d = try? JSONEncoder().encode(AnyEncodable(enc)) {
                arg = String(decoding: d, as: UTF8.self)
            } else if JSONSerialization.isValidJSONObject(payload), let d = try? JSONSerialization.data(withJSONObject: payload) {
                arg = String(decoding: d, as: UTF8.self)
            }
        }
        let js = "window.hantuu && hantuu.\(fn)(\(arg));"
        if ready {
            webView.evaluateJavaScript(js) { _, err in if let err { Log.write("js \(fn) failed: \(err)") } }
        } else {
            queue.append(js)
        }
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["type"] as? String == "ready" {
            ready = true
            let pending = queue
            queue = []
            for js in pending { webView.evaluateJavaScript(js, completionHandler: nil) }
            onReady?()
            return
        }
        onMessage?(body)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.scheme == "hantuu" && action.navigationType != .linkActivated { return decisionHandler(.allow) }
        if url.scheme == "about" { return decisionHandler(.allow) }
        // Any link that would navigate the page goes to the router instead.
        decisionHandler(.cancel)
        if url.scheme == "http" || url.scheme == "https" { NSWorkspace.shared.open(url) }
    }

    func webView(_ webView: WKWebView, webContentProcessDidTerminate webView2: WKWebView) {
        ready = false
        webView.reload()
    }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ v: Encodable) { value = v }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
