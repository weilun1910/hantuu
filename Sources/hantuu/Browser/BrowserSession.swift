import AppKit
import Combine
import WebKit

/// A project owns one session. This configuration never uses WebPage, the hantuu scheme,
/// or any privileged reader handler. A weak handler breaks WebKit's retain cycle.
final class BrowserMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserSession?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}

final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let world = WKContentWorld.world(name: "hantuu.browser.feedback")
    let projectID: UUID
    let dataStoreID: UUID
    let webView: WKWebView
    @Published private(set) var address = ""
    @Published private(set) var loading = false
    @Published private(set) var clearingData = false
    @Published private(set) var progress = 0.0
    @Published private(set) var error: String?
    @Published var notice: String?
    @Published private(set) var picking = false
    @Published private(set) var logs = BrowserLogBuffer()
    @Published var logsOpen = false
    @Published var selectedLogs = Set<UUID>()
    @Published private(set) var history: BrowserHistory
    private var observations: [NSKeyValueObservation] = []
    private let proxy = BrowserMessageProxy()
    private var navigationGeneration = 0
    private var initialLoad = false
    private var disposed = false
    private var pendingHistoryMove = false
    var save: ((BrowserSavedState) -> Void)?
    var onPick: (([String: Any]) -> Void)?

    init(projectID: UUID, saved: BrowserSavedState, store: WKWebsiteDataStore? = nil) {
        self.projectID = projectID
        dataStoreID = saved.dataStoreID ?? UUID()
        history = BrowserHistory(saved)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store ?? WKWebsiteDataStore(forIdentifier: dataStoreID)
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.preferences.isElementFullscreenEnabled = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        let content = WKUserContentController()
        config.userContentController = content
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        proxy.owner = self
        content.add(proxy, contentWorld: Self.world, name: "browserPicker")
        content.add(proxy, contentWorld: Self.world, name: "browserLogs")
        for (name, world, mainOnly) in [("picker", Self.world, true), ("log-relay", Self.world, true), ("page-hooks", WKContentWorld.page, true), ("deny-location", WKContentWorld.page, false)] {
            if let source = Self.script(name) {
                content.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: mainOnly, in: world))
            } else { notice = "Browser instrumentation could not load. Rebuild the app resources." }
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        observations = [
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in self?.loading = view.isLoading },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in self?.progress = view.estimatedProgress },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                guard let self, !self.disposed, !self.pendingHistoryMove, let url = view.url, BrowserAddress.allowed(url) else { return }
                self.address = url.absoluteString
                self.history.visit(url.absoluteString)
                self.persist()
            }
        ]
        address = history.current ?? ""
    }

    static func script(_ name: String) -> String? {
        guard let path = Paths.webRoot?.appendingPathComponent("browser/\(name).js") else { return nil }
        return try? String(contentsOf: path, encoding: .utf8)
    }

    var generation: Int { navigationGeneration }

    var state: BrowserSavedState {
        BrowserSavedState(url: history.current, history: history.urls, historyIndex: history.index, dataStoreID: dataStoreID)
    }
    var hasPage: Bool { !address.isEmpty || webView.url != nil }
    var viewport: (width: Int, height: Int) { (Int(webView.bounds.width), Int(webView.bounds.height)) }
    private func persist() { save?(state) }

    func openIfNeeded(ports: [ListeningPort]) {
        guard !initialLoad else { return }
        if let current = history.current, let url = URL(string: current) { navigate(url) }
        else if let url = BrowserAddress.defaultServer(ports) { navigate(url) }
    }

    func navigate(_ url: URL) { navigate(URLRequest(url: url)) }

    private func navigate(_ request: URLRequest) {
        guard !disposed, !clearingData, let url = request.url, BrowserAddress.allowed(url) else {
            notice = "Only http and https addresses open here."
            return
        }
        initialLoad = true
        pendingHistoryMove = false
        history.visit(url.absoluteString)
        address = url.absoluteString
        error = nil
        setPicking(false)
        persist()
        webView.load(request)
    }
    func navigate(_ input: String) {
        guard let url = BrowserAddress.parse(input) else { notice = "Enter an http or https address, localhost:3000, or a port number."; return }
        navigate(url)
    }
    func move(_ delta: Int) {
        guard !clearingData, let url = history.move(delta) else { return }
        pendingHistoryMove = true
        address = url.absoluteString
        error = nil
        setPicking(false)
        persist()
        // The app's history also survives eviction and restart. Revisit the address rather
        // than pretending WKBackForwardList can be restored through a public API.
        webView.load(URLRequest(url: url))
    }
    func reloadOrStop() {
        guard !clearingData else { return }
        if loading { webView.stopLoading(); return }
        guard let url = URL(string: address), BrowserAddress.allowed(url) else { return }
        error = nil
        if webView.url == url { webView.reload() } else { navigate(url) }
    }
    func setPicking(_ value: Bool) {
        picking = value && hasPage && error == nil && !loading && !clearingData
        evaluate("window.__hantuuPicker?.setEnabled(\(picking ? "true" : "false"))") { _ in }
    }
    func evaluate(_ script: String, completion: @escaping (Any?) -> Void) {
        webView.evaluateJavaScript(script, in: nil, in: Self.world) { result in
            switch result { case .success(let value): completion(value); case .failure: completion(nil) }
        }
    }

    func receive(_ message: WKScriptMessage) {
        guard !disposed, message.webView === webView, message.frameInfo.isMainFrame,
              message.world == Self.world,
              BrowserAddress.allowed(message.frameInfo.request.url),
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        if message.name == "browserPicker", picking {
            if kind == "cancel", body.count == 1 { setPicking(false); return }
            guard kind == "pick", body.count == 2, let payload = body["payload"] as? [String: Any],
                  Self.validElement(payload), !loading else { return }
            setPicking(false)
            onPick?(payload)
        } else if message.name == "browserLogs", kind == "logs", body.count == 2,
                  let entries = body["entries"] as? [[String: Any]], entries.count <= 500 {
            for entry in entries {
                guard entry.count == 2, let level = entry["level"] as? String,
                      let text = entry["text"] as? String, text.count <= 2000 else { continue }
                logs.append(level: level, text: text, url: message.frameInfo.request.url?.absoluteString ?? address)
            }
            selectedLogs.formIntersection(Set(logs.entries.map(\.id)))
        }
    }

    static func validElement(_ p: [String: Any]) -> Bool {
        guard Set(p.keys) == Set(["selector", "role", "name", "text", "html", "styles", "bounds", "viewport"]),
              let bounds = p["bounds"] as? [String: Double], Set(bounds.keys) == Set(["x", "y", "width", "height"]),
              bounds.values.allSatisfy({ $0.isFinite && abs($0) < 10_000_000 }),
              (bounds["width"] ?? 0) > 0, (bounds["height"] ?? 0) > 0,
              let viewport = p["viewport"] as? [String: Double], viewport.count == 2,
              viewport.values.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 100_000 }),
              let styles = p["styles"] as? [String: String], styles.count <= 12,
              styles.values.allSatisfy({ $0.count <= 200 }) else { return false }
        for (key, limit) in [("selector", 2048), ("role", 80), ("name", 240), ("text", 1000), ("html", 600)] {
            guard let value = p[key] as? String, value.count <= limit else { return false }
        }
        return true
    }

    func clearLogs() { logs.clear(); selectedLogs.removeAll() }
    func clearBrowsingData() {
        guard !clearingData, !disposed else { return }
        setPicking(false)
        clearingData = true
        webView.stopLoading()
        navigationGeneration += 1
        // Unload the old document before deletion so its timers cannot recreate cookies or
        // local storage while the data store is being cleared.
        webView.loadHTMLString("<!doctype html><title>Clearing browsing data</title>", baseURL: nil)
    }

    private func finishClearingData() {
        let store = webView.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.disposed else { return }
                self.clearingData = false
                self.loading = false
                self.clearLogs()
                self.notice = "Browsing data cleared for this project."
                if let url = URL(string: self.address), BrowserAddress.allowed(url) { self.navigate(url) }
            }
        }
    }

    func showInspector() {
        // isInspectable exposes this view in Safari's Develop menu. WebKit does not have
        // a public API for opening its inspector window from an app.
        let alert = NSAlert()
        alert.messageText = "Inspect this page in Safari"
        alert.informativeText = "In Safari, enable developer features in Settings > Advanced. Then choose Develop > this Mac > hantuu > this page."
        alert.addButton(withTitle: "OK")
        if let window = webView.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func snapshot(rect: CGRect? = nil, folder: URL? = nil, completion: @escaping (URL?) -> Void) {
        guard !disposed, !clearingData, error == nil, hasPage, !loading else { completion(nil); return }
        let generation = navigationGeneration
        let capturedURL = address
        // Resolve the destination now. A later change to the app data directory must not
        // redirect a screenshot already requested by a chat or a fixture.
        let destination = folder ?? PastedImages.folder
        let configuration = WKSnapshotConfiguration()
        if let rect {
            let clipped = rect.insetBy(dx: -12, dy: -12).intersection(webView.bounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { completion(nil); return }
            configuration.rect = clipped
        }
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self, !self.disposed, self.navigationGeneration == generation, self.address == capturedURL,
                  let data = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:]) else { completion(nil); return }
            completion(PastedImages.save(png, type: .png, in: destination))
        }
    }

    func dispose() {
        guard !disposed else { return }
        persist()
        disposed = true
        navigationGeneration += 1
        webView.stopLoading()
        webView.removeFromSuperview()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        observations.removeAll()
        let content = webView.configuration.userContentController
        content.removeScriptMessageHandler(forName: "browserPicker", contentWorld: Self.world)
        content.removeScriptMessageHandler(forName: "browserLogs", contentWorld: Self.world)
        content.removeAllUserScripts()
        proxy.owner = nil
        onPick = nil
        save = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if clearingData {
            decisionHandler(action.request.url?.absoluteString == "about:blank" && action.targetFrame?.isMainFrame == true ? .allow : .cancel)
            return
        }
        guard BrowserAddress.allowed(action.request.url), !action.shouldPerformDownload else {
            notice = action.shouldPerformDownload ? "Downloads are not supported in this browser yet." : "This browser only opens http and https links."
            decisionHandler(.cancel)
            return
        }
        if action.targetFrame == nil {
            decisionHandler(.cancel)
            navigate(action.request)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if clearingData {
            decisionHandler(response.response.url?.absoluteString == "about:blank" && response.isForMainFrame ? .allow : .cancel)
            return
        }
        let attachment = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        guard response.canShowMIMEType, !attachment, BrowserAddress.allowed(response.response.url) else {
            notice = "Downloads are not supported in this browser yet."
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { navigate(action.request) }
        return nil
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        initialLoad = true
        navigationGeneration += 1
        error = nil
        picking = false
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if pendingHistoryMove {
            pendingHistoryMove = false
            if let url = webView.url, BrowserAddress.allowed(url) {
                address = url.absoluteString
                history.visit(address)
            }
            persist()
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if clearingData { finishClearingData(); return }
        if let url = webView.url, BrowserAddress.allowed(url) {
            address = url.absoluteString
            history.visit(address)
            persist()
        }
    }
    private func failed(_ failure: Error) {
        guard (failure as NSError).code != NSURLErrorCancelled else { return }
        pendingHistoryMove = false
        clearingData = false
        loading = false
        picking = false
        let url = URL(string: address)
        if let host = url?.host, ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
           (failure as NSError).domain == NSURLErrorDomain,
           [NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost].contains((failure as NSError).code) {
            error = "Nothing is running on \(host)\(url?.port.map { ":\($0)" } ?? "")."
        } else { error = "Couldn't load this page. \(failure.localizedDescription)" }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { error = "The page stopped. Reload to continue."; loading = false }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    @available(macOS 27.0, *)
    @objc(webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}
