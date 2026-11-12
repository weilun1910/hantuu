import AppKit
import SwiftUI
import WebKit

extension SelfTest {
    static func browserTab(_ dir: URL) {
        // Mark this as a directory before it exists so parent-URL equality stays exact.
        let root = dir.appendingPathComponent("browser-tab", isDirectory: true)
        Paths.ensure(root)
        let previousDataDir = Paths.dataDir
        Paths.dataDir = root.appendingPathComponent("data", isDirectory: true)
        defer { Paths.dataDir = previousDataDir }
        browserLogic(root)
        browserFixture(root)
        browserComposer(root)
    }

    private static func browserLogic(_ dir: URL) {
        let good = [("3000", "http://localhost:3000"), ("localhost:5173", "http://localhost:5173"),
                    ("127.0.0.1:8000/path", "http://127.0.0.1:8000/path"),
                    ("https://example.test/a?q=1", "https://example.test/a?q=1"),
                    ("example.test", "https://example.test"), ("dev.local:8080", "http://dev.local:8080"), ("[::1]:8080", "http://[::1]:8080")]
        for (input, expected) in good { check("browser address: \(input)", BrowserAddress.parse(input)?.absoluteString == expected) }
        for input in ["", "junk", "a b", "0", "65536", "localhost:0", "javascript:alert(1)", "javascript:123", "file:///tmp/a", "hantuu://app/index.html", "data:text/html,test", "https://user:pass@example.test"] {
            check("browser address: refuses \(input)", BrowserAddress.parse(input) == nil)
        }
        check("browser policy: only web schemes", ["file:///tmp/a", "hantuu://file/tmp/a", "javascript:1", "mailto:a@example.test", "data:text/html,x", "about:blank"].allSatisfy { !BrowserAddress.allowed(URL(string: $0)) })
        let ports = [ListeningPort(port: 5432, pid: 1, command: "postgres"), ListeningPort(port: 3000, pid: 2, command: "node"), ListeningPort(port: 5173, pid: 3, command: "node")]
        check("browser server: prefers a development listener and keeps no-server empty", BrowserAddress.defaultServer(ports)?.port == 5173 && BrowserAddress.defaultServer([]) == nil)
        var history = BrowserHistory(BrowserSavedState())
        history.visit("http://localhost:3000/a"); history.visit("http://localhost:3000/b")
        check("browser history: back and forward", history.move(-1)?.path == "/a" && history.canForward && history.move(1)?.path == "/b")
        _ = history.move(-1); history.visit("http://localhost:3000/c")
        check("browser history: a new branch discards forward entries", !history.canForward && history.urls.count == 2 && history.current?.hasSuffix("/c") == true)
        for n in 0..<120 { history.visit("http://localhost:3000/\(n)") }
        check("browser history: bounded at 100", history.urls.count == 100 && history.index == 99)
        let model = AppModel(), a = Project(path: dir.path), b = Project(path: dir.appendingPathComponent("b").path)
        model.projects = [a, b]
        let one = Chat(projectID: a.id, agentID: "claude"), two = Chat(projectID: a.id, agentID: "codex"), other = Chat(projectID: b.id, agentID: "claude")
        model.chats = [one, two, other]
        model.select(one.id)
        let state = BrowserSavedState(url: history.current, history: history.urls, historyIndex: history.index, dataStoreID: UUID())
        model.setBrowserPanelState(state, project: a.id)
        model.panelTab = .browser
        model.select(other.id)
        check("browser project: new project has no browser history", model.browserPanelState(project: b.id).url == nil)
        model.select(two.id)
        check("browser project: chats share history and tab", model.browserPanelState(project: a.id) == state && model.panelTab == .browser)
        var saved = SavedState(); saved.projects = [a,b]; saved.projectPanels = model.savedProjectPanels()
        let decoded = (try? JSONEncoder.hantuu.encode(saved)).flatMap(SavedState.read)
        check("browser project: URL, history and profile ID survive saving", decoded?.projectPanels?[a.id.uuidString]?.browser == state)
        let damaged = "{\"projectPanels\":{\"\(a.id)\":{\"tab\":\"Browser\",\"browser\":{\"url\":17,\"history\":false,\"dataStoreID\":\"\(state.dataStoreID!)\"}}}}"
        check("browser project: malformed fields preserve the profile ID", SavedState.read(Data(damaged.utf8))?.projectPanels?[a.id.uuidString]?.browser?.dataStoreID == state.dataStoreID)
        let old = try? JSONDecoder().decode(ProjectPanelState.self, from: Data("{}".utf8))
        check("browser project: older panel records load", old != nil && old?.browser == nil)
        var lru = BrowserLRU(capacity: 3)
        let ids = (0..<4).map { _ in UUID() }
        for id in ids.prefix(3) { _ = lru.touch(id) }
        _ = lru.touch(ids[0])
        check("browser LRU: least recently used is evicted", lru.touch(ids[3]) == [ids[1]] && lru.order.count == 3)
        var logs = BrowserLogBuffer()
        for n in 0..<550 { logs.append(level: "log", text: "line \(n)", url: "http://localhost:3000") }
        check("browser logs: bounded buffer keeps the newest 500", logs.entries.count == 500 && logs.entries.first?.text == "line 50")
        logs.append(level: "error", text: String(repeating: "x", count: 3000), url: "http://localhost")
        check("browser logs: long entries are trimmed", logs.entries.last?.text.count == 2000)
        logs.append(level: "command", text: "ignored", url: "http://localhost")
        check("browser logs: unknown levels refused", logs.entries.last?.level == "error")
        browserFeedbackLogic(dir)
    }

    private static func browserFeedbackLogic(_ dir: URL) {
        let image = dir.appendingPathComponent("fixture image.png")
        let fixtures = [BrowserFeedback.screenshot(url: "http://localhost:3000", width: 500, height: 400, image: image),
                        BrowserFeedback.element(url: "http://localhost:3000", width: 500, height: 400, payload: "{\"selector\":\"#save\"}", image: image),
                        BrowserFeedback.logs(url: "http://localhost:3000", width: 500, height: 400, entries: [BrowserLogEntry(level: "error", text: "fixture error", url: "http://localhost:3000")])]
        for (n, feedback) in fixtures.enumerated() {
            var attachments: [ComposerAttachment] = [], text = "", steps: [SendStep] = []
            feedback.compose(reader: true, agentID: "claude", addToReader: { attachments = $0; text = $1 }, pasteToTerminal: { steps = $0 })
            check("browser feedback \(n): reader gets text and chips without terminal input", text == feedback.text && attachments.count == (n == 2 ? 0 : 1) && steps.isEmpty)
            for agent in ["claude", "codex"] {
                feedback.compose(reader: false, agentID: agent, addToReader: { _, _ in check("browser feedback: wrong destination", false) }, pasteToTerminal: { steps = $0 })
                check("browser feedback \(n): \(agent) never receives Return", !steps.contains(.pressReturn) && !steps.contains { if case .command = $0 { return true }; return false })
                if n < 2 { check("browser feedback \(n): image path has its own paste", steps.first == .image(ShellEscape.escape(image.path)) && steps.count == 2) }
            }
        }
        check("browser feedback: page terminal control bytes are stripped", BrowserFeedback(text: "data\u{1b}[201~\rmore", image: nil).draftText == "data[201~more")
    }

    private static func browserJS(_ session: BrowserSession, _ source: String, world: WKContentWorld = .page) -> Any? {
        var done = false, value: Any?
        session.webView.evaluateJavaScript(source, in: nil, in: world) { result in
            if case .success(let result) = result { value = result }
            done = true
        }
        _ = waitUntil(5) { done }
        return value
    }

    private static func browserFixture(_ dir: URL) {
        let model = AppModel(), project = Project(path: dir.path)
        model.projects = [project]; model.selectedProjectID = project.id
        let chat = Chat(projectID: project.id, agentID: "claude")
        model.chats = [chat]; model.select(chat.id); model.panelTab = .browser; model.panelVisible = true
        let review = ReviewCenter(loadSavedState: false); review.fixtureMode = true; review.configure(model: model)
        let browser = BrowserCoordinator(model: model, review: review)
        browser.storeFactory = { .nonPersistent() }
        browser.sync(visible: true)
        guard let session = browser.active else { check("browser fixture: session exists", false); return }
        let host = ChromeHostingView(rootView: VStack(spacing: 0) {
            PanelHeader().environmentObject(model).environmentObject(review).environmentObject(browser)
            BrowserPanel(browser: browser)
        })
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 560, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFrontRegardless()
        defer { browser.dispose(); window.orderOut(nil) }
        let out = dir.appendingPathComponent("snapshots"); Paths.ensure(out)
        func shot(_ name: String) {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            check("browser snapshot: \(name)", render(host, to: out.appendingPathComponent("browser-tab-\(name).png")))
        }
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
            window.appearance = NSAppearance(named: appearance); shot("empty-" + name)
        }
        window.setContentSize(NSSize(width: 360, height: 700)); shot("empty-narrow")
        window.setContentSize(NSSize(width: 560, height: 700))
        let html = """
        <!doctype html><html><head><meta name="color-scheme" content="light dark"><style>
        body { font: 15px -apple-system; margin: 28px; } h1 { font-size: 24px; font-weight: 600; }
        button { margin: 12px 0; padding: 12px 24px; } .card { border: 1px solid #8885; padding: 20px; }
        </style></head><body><h1>Project preview</h1><p>A local fixture for browser feedback.</p>
        <div class="card"><button id="save" aria-label="Save changes">Save changes</button><p>Ready to review.</p></div>
        <input type="password" value="fixture-secret"><script>console.info('Fixture ready');</script></body></html>
        """
        session.webView.loadHTMLString(html, baseURL: URL(string: "http://localhost:5173/fixture")!)
        check("browser fixture: loads locally with instrumentation", waitUntil(8) { browserJS(session, "!!document.querySelector('#save') && !!window.__hantuuPicker", world: BrowserSession.world) as? Bool == true })
        check("browser fixture: page console reaches isolated relay", waitUntil(3) { session.logs.entries.contains { $0.text.contains("Fixture ready") } })
        if #available(macOS 27.0, *) {
            check("browser permissions: native location denial selector is present", session.responds(to: NSSelectorFromString("webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:")))
        }
        check("browser security: no privileged scheme handler", session.webView.configuration.urlSchemeHandler(forURLScheme: "hantuu") == nil)
        check("browser security: page cannot see native picker or reader bridges", browserJS(session, "typeof window.__hantuuPicker === 'undefined' && !window.webkit?.messageHandlers?.browserPicker && !window.webkit?.messageHandlers?.hantuu") as? Bool == true)
        let payload = browserJS(session, "window.__hantuuPicker.payload(document.querySelector('#save'))", world: BrowserSession.world) as? [String: Any]
        check("browser picker: selector, accessible name and text", payload?["selector"] as? String == "#save" && payload?["name"] as? String == "Save changes" && payload?["text"] as? String == "Save changes")
        check("browser picker: bounds and schema are valid", payload.map(BrowserSession.validElement) == true && ((payload?["bounds"] as? [String: Double])?["width"] ?? 0) > 0)
        let secret = browserJS(session, "window.__hantuuPicker.payload(document.querySelector('input'))", world: BrowserSession.world) as? [String: Any]
        check("browser picker: password values are not included", secret?["name"] as? String == "[redacted]" && !(secret?["html"] as? String ?? "").contains("fixture-secret"))
        var picked = false
        var clickedPayload: [String: Any]?
        session.onPick = { picked = true; clickedPayload = $0 }
        _ = waitUntil(3) { !session.loading }
        session.setPicking(true)
        _ = browserJS(session, "document.querySelector('#save').click(); document.dispatchEvent(new CustomEvent('__hantuu_page_log',{detail:JSON.stringify({kind:'pick',payload:{selector:'#fake'}})})); 1")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check("browser security: page-generated clicks and forged log events cannot pick", !picked && session.picking)
        if let bounds = payload?["bounds"] as? [String: Double], let x = bounds["x"], let y = bounds["y"] {
            let point = NSPoint(x: x + 8, y: session.webView.isFlipped ? y + 8 : session.webView.bounds.height - y - 8)
            let location = session.webView.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(event) }
            }
        }
        check("browser picker: native click returns selected element", waitUntil(3) { picked } && clickedPayload?["selector"] as? String == "#save" && !session.picking)
        session.setPicking(true)
        window.makeFirstResponder(session.webView)
        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) { window.sendEvent(escape) }
        check("browser picker: Escape cancels", waitUntil(3) { !session.picking })
        _ = browserJS(session, "for(let n=0;n<550;n++) console.log('entry '+n); 1")
        check("browser logs: real hook caps at 500", waitUntil(4) { session.logs.entries.count == 500 && session.logs.entries.last?.text == "entry 549" })
        check("browser logs: oldest entries fall off", session.logs.entries.first?.text == "entry 50")
        _ = browserJS(session, "console.warn('warning'); console.error('error'); setTimeout(()=>{throw Error('uncaught fixture')},0); Promise.reject('rejection fixture'); 1")
        check("browser logs: errors and unhandled rejections captured", waitUntil(4) { session.logs.entries.contains { $0.text.contains("uncaught fixture") } && session.logs.entries.contains { $0.text.contains("rejection fixture") } })
        _ = browserJS(session, "window.locationResult='pending'; navigator.geolocation.getCurrentPosition(()=>window.locationResult='allowed',e=>window.locationResult=e.code); 1")
        check("browser permissions: fixture geolocation is denied", waitUntil(3) { browserJS(session, "window.locationResult") as? Int == 1 })
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
            window.appearance = NSAppearance(named: appearance)
            session.setPicking(false); session.logsOpen = false; shot("loaded-" + name)
            session.setPicking(true)
            _ = browserJS(session, "window.__hantuuPicker.outline(document.querySelector('#save')); 1", world: BrowserSession.world)
            shot("picker-" + name)
            session.setPicking(false); session.logsOpen = true; shot("logs-" + name)
        }
        session.logsOpen = false
        var screenshot: URL?, completed = false
        session.snapshot(folder: dir) { screenshot = $0; completed = true }
        check("browser screenshot: PNG is written only inside fixture folder", waitUntil(5) { completed } && screenshot?.deletingLastPathComponent() == dir && screenshot.flatMap { try? Data(contentsOf: $0) }?.prefix(4) == Data([137,80,78,71]),
              "completed=\(completed), expected=\(dir.absoluteString), actual=\(screenshot?.absoluteString ?? "nil")")
        // A default destination is captured at request time, even if the data directory
        // changes before WebKit finishes. Both candidate folders remain test fixtures.
        let requestDataDir = Paths.dataDir
        let requestAttachments = PastedImages.folder
        let laterDataDir = dir.appendingPathComponent("later-data", isDirectory: true)
        var defaultScreenshot: URL?, defaultCompleted = false
        session.snapshot { defaultScreenshot = $0; defaultCompleted = true }
        Paths.dataDir = laterDataDir
        let defaultFinished = waitUntil(5) { defaultCompleted }
        Paths.dataDir = requestDataDir
        check("browser screenshot: default folder is captured before the callback", defaultFinished && defaultScreenshot?.deletingLastPathComponent() == requestAttachments && defaultScreenshot.flatMap { try? Data(contentsOf: $0) }?.prefix(4) == Data([137,80,78,71]),
              "expected=\(requestAttachments.absoluteString), actual=\(defaultScreenshot?.absoluteString ?? "nil")")
        check("browser screenshot: later data directory is not used", !FileManager.default.fileExists(atPath: laterDataDir.appendingPathComponent("attachments", isDirectory: true).path))
        // Same-document targets exercise the policy without contacting a real server.
        _ = browserJS(session, "window.open('http://localhost:5173/fixture#popup', '_blank'); 1")
        check("browser navigation: window.open stays in the same session", waitUntil(3) { session.address.contains("#popup") } && browser.sessions.count == 1)
        _ = browserJS(session, "location.href='hantuu://file/tmp/private'; 1")
        check("browser navigation: privileged navigation is refused", waitUntil(3) { session.notice?.contains("http and https") == true } && session.webView.url?.scheme != "hantuu")
        if let cookie = HTTPCookie(properties: [.domain: "localhost", .path: "/", .name: "browser-fixture", .value: "local-only"]) {
            var stored = false
            session.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { stored = true }
            check("browser profile: fixture cookie is stored", waitUntil(3) { stored })
            let isolated = WKWebsiteDataStore.nonPersistent()
            var otherCookies: [HTTPCookie]?
            isolated.httpCookieStore.getAllCookies { otherCookies = $0 }
            check("browser profile: a separate project store has no fixture cookie", waitUntil(3) { otherCookies != nil } && otherCookies?.isEmpty == true)
            session.clearBrowsingData()
            check("browser profile: clear browsing data completes", waitUntil(5) { !session.clearingData })
            var remaining: [HTTPCookie]?
            session.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { remaining = $0 }
            check("browser profile: clearing removes the project's cookie", waitUntil(3) { remaining != nil } && remaining?.contains { $0.name == "browser-fixture" } == false)
        } else { check("browser profile: fixture cookie can be created", false) }
        let original = session
        for n in 0..<3 {
            let p = Project(path: dir.appendingPathComponent("project-\(n)").path)
            model.projects.append(p); model.selectedChatID = nil; model.selectedProjectID = p.id
            browser.sync(visible: true)
        }
        check("browser LRU: only three live sessions remain", browser.sessions.count == 3 && browser.sessions[project.id] == nil)
        check("browser LRU: eviction keeps URL and stable store identity", model.browserPanelState(project: project.id).dataStoreID == original.dataStoreID && model.browserPanelState(project: project.id).url?.contains("localhost") == true)
        let evictedState = model.browserPanelState(project: project.id)
        let replacement = BrowserSession(projectID: project.id, saved: evictedState, store: .nonPersistent())
        defer { replacement.dispose() }
        check("browser LRU: restoration creates a new view with the same profile", replacement !== original && replacement.dataStoreID == original.dataStoreID && replacement.state.url == evictedState.url)
    }

    private static func browserComposer(_ dir: URL) {
        guard let ghostty = GhosttyApp.shared ?? GhosttyApp.start() else { check("browser composer: terminal available", false); return }
        let model = AppModel(), project = Project(path: dir.path)
        model.projects = [project]
        let chat = Chat(projectID: project.id, agentID: "claude")
        let bytesFile = dir.appendingPathComponent("browser-input.bin")
        let terminal = recordingTerminal(ghostty, dir: dir, file: bytesFile)
        chat.terminal = terminal; model.chats = [chat]; model.select(chat.id)
        let settings = ChatSettings(file: dir.appendingPathComponent("chat-settings.json")); settings.showChatsAsReader = true
        let reader = ReaderModeController(model: model, mode: ReaderMode(settings: settings), commandCatalog: ReaderCommandCatalog(home: dir))
        reader.statusProvider = { _ in nil }; reader.imageWait = 0.05
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 700, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500)); window.contentView = host
        terminal.frame = host.bounds; host.addSubview(terminal); reader.install(in: host, top: host.topAnchor, above: terminal)
        window.orderFrontRegardless()
        defer { terminal.destroy(); window.orderOut(nil) }
        _ = reader.sync(selected: chat)
        check("browser composer: fake agent ready", waitUntil(8) { reader.refresh(); return reader.composerMode == .ready })
        let image = dir.appendingPathComponent("feedback.png")
        try? imageData(.systemBlue, width: 20, height: 20, type: .png).write(to: image)
        let feedback = BrowserFeedback.screenshot(url: "http://localhost:5173", width: 500, height: 400, image: image)
        reader.composer.textView.text = "My existing draft"
        check("browser composer: adds image chip and keeps existing reader draft", reader.insertBrowserFeedback(feedback, chatID: chat.id) && reader.composer.attachments.count == 1 && reader.composer.textView.string.hasPrefix("My existing draft\n\nBrowser context"))
        check("browser composer: reader insertion sends no terminal bytes", ((try? Data(contentsOf: bytesFile)) ?? Data()).isEmpty)
        check("browser composer: insertion focuses the reader input", window.firstResponder === reader.composer.textView)
        settings.showChatsAsReader = false; _ = reader.sync(selected: chat)
        check("browser composer: accepts terminal draft", reader.insertBrowserFeedback(feedback, chatID: chat.id))
        _ = waitUntil(5) { !reader.isTyping }
        let bytes = (try? Data(contentsOf: bytesFile)) ?? Data()
        let expected = "\u{1b}[200~" + ShellEscape.escape(image.path) + "\u{1b}[201~\u{1b}[200~ " + feedback.text + "\u{1b}[201~"
        check("browser composer: separate image paste and text, no Return", String(data: bytes, encoding: .utf8) == expected, String(data: bytes, encoding: .utf8)?.debugDescription ?? "")
        check("browser composer: stale chat cannot receive feedback", !reader.insertBrowserFeedback(feedback, chatID: UUID()))
    }
}
