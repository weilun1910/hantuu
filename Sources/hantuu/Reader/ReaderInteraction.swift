import AppKit

/// Keyboard navigation and live requests share the visible reader's ownership boundary.
final class ReaderInteraction {
    private let page: WebPage
    private weak var model: AppModel?
    private let ownsMainChat: Bool
    private let observesSelection: Bool
    private var monitor: Any?
    private var timer: Timer?
    private var leasedChat: UUID?
    private var leasedSession: String?
    private var requests: [ReaderRequest] = []
    var hasPendingRequest: Bool { !requests.isEmpty }
    private var health: ReaderHealth?
    var externalHealth: (() -> ReaderHealth)?
    private(set) var findOpen = false

    init(page: WebPage, model: AppModel, ownsMainChat: Bool, observesSelection: Bool) {
        self.page = page
        self.model = model
        self.ownsMainChat = ownsMainChat
        self.observesSelection = observesSelection
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    deinit {
        timer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let leasedChat { ReaderRequestBridge.release(chatID: leasedChat) }
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard page.ready, !page.webView.isHiddenOrHasHiddenAncestor, let window = page.webView.window,
              event.window === window else { return event }
        if let view = window.firstResponder as? NSView, view is TerminalView || view.hantuuIsInCodeViewer { return event }
        var responderView = window.firstResponder as? NSView
        var focusedReader: HantuuWebView?
        while let view = responderView {
            if let reader = view as? HantuuWebView { focusedReader = reader; break }
            responderView = view.superview
        }
        if let focusedReader {
            guard focusedReader === page.webView else { return event }
        } else if !ownsMainChat { return event }
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command, key == "f" {
            findOpen = true
            focusReader()
            page.call("readerFind", ["action": "open"])
            return nil
        }
        if flags.contains(.command), flags.subtracting([.command, .shift]).isEmpty, key == "g" {
            findOpen = true
            focusReader()
            page.call("readerFind", ["action": "next", "backwards": flags.contains(.shift)] as [String: Any])
            return nil
        }
        if event.keyCode == 53, flags.isEmpty, findOpen {
            findOpen = false
            page.call("readerFind", ["action": "close"])
            return nil
        }
        // Only the main composer routes native request keys. Focused web cards handle
        // their own keys, preserving text input, Find, sidebar and other reader scope.
        if ownsMainChat, !findOpen, flags.isEmpty,
           let controller = ReaderModeController.main,
           window.firstResponder === controller.composer.textView,
           !controller.composer.textView.hasMarkedText(), let request = requests.first {
            let requestKey: String?
            switch event.keyCode {
            case 126: requestKey = "ArrowUp"
            case 125: requestKey = "ArrowDown"
            case 48: requestKey = "Tab"
            case 53: requestKey = "Escape"
            case 36, 76: requestKey = "Enter"
            default: requestKey = key.flatMap { $0.count == 1 && "123456789".contains($0) ? $0 : nil }
            }
            if let requestKey {
                if event.isARepeat { return nil }
                refresh()
                guard requests.contains(where: { $0.id == request.id }),
                      model?.selectedChatID == request.chatID,
                      model?.selectedChat?.sessionID == request.sessionID,
                      model?.subagentBrowser.selection == nil else { return nil }
                focusReader()
                page.call("readerRequestKey", ["requestID": request.id.uuidString, "key": requestKey, "fromComposer": true] as [String: Any])
                return nil
            }
        }
        // Tab from the composer enters the visible transcript, never the hidden TUI.
        if event.keyCode == 48, flags == [.control, .option] {
            focusReader()
            page.webView.evaluateJavaScript("document.querySelector('#entries summary, #entries button')?.focus(); 0", completionHandler: nil)
            return nil
        }
        return event
    }

    private func focusReader() {
        (page.webView as? FocuslessWebView)?.allowsInteraction = true
        page.webView.window?.makeFirstResponder(page.webView)
    }

    func reset() {
        let sameOwner = leasedChat != nil && leasedChat == model?.selectedChatID && leasedSession == model?.selectedChat?.sessionID
        if !sameOwner { release(); findOpen = false }
        health = nil
        page.call("readerRequests", requests)
        refresh()
    }

    private func release() {
        if !requests.isEmpty { page.call("readerRequests", []) }
        if let leasedChat { ReaderRequestBridge.release(chatID: leasedChat) }
        leasedChat = nil
        leasedSession = nil
        requests = []
    }

    func refresh() {
        guard page.ready else { return }
        let visible = !page.webView.isHiddenOrHasHiddenAncestor && page.webView.window != nil
        if !visible { release(); return }
        guard let model else { return }
        let chat = model.selectedChat
        let nextHealth: ReaderHealth
        if let externalHealth { nextHealth = externalHealth() }
        else if !observesSelection { nextHealth = .connected }
        else if let chat, chat.agent.transcript == nil {
            nextHealth = ReaderHealth(state: "unsupported", message: "This provider does not expose a readable transcript. Open the terminal for the conversation.")
        } else if let chat, chat.status == .ended {
            nextHealth = chat.follower?.health.state == "incomplete"
                ? ReaderHealth(state: "incomplete", message: "The process ended with an incomplete transcript record. Earlier messages and completed tools are preserved.") : .disconnected
        } else { nextHealth = chat?.follower?.health ?? .locating }
        if nextHealth != health { health = nextHealth; page.call("readerHealth", nextHealth) }
        guard ownsMainChat, let chat, let provider = ReaderRequestProvider(rawValue: chat.agentID), chat.status != .ended,
              model.subagentBrowser.selection == nil, let session = chat.sessionID, !session.isEmpty else {
            if leasedChat != nil { release(); page.call("readerRequests", []) }
            return
        }
        if leasedChat != chat.id || leasedSession != session { release() }
        leasedChat = chat.id
        leasedSession = session
        let pending = ReaderRequestBridge.poll(chatID: chat.id, sessionID: session, provider: provider)
        if pending != requests { requests = pending; page.call("readerRequests", pending) }
    }

    /// Only live request IDs from this exact visible chat can cross the response bridge.
    func message(_ message: [String: Any]) -> Bool {
        switch message["type"] as? String {
        case "findState": findOpen = message["open"] as? Bool == true; return true
        case "focusRequested": focusReader(); return true
        case "composerFocus":
            (page.webView as? FocuslessWebView)?.allowsInteraction = false
            if ownsMainChat { ReaderModeController.main?.focusComposer() }
            return true
        case "readerRequest":
            guard ownsMainChat, !page.webView.isHiddenOrHasHiddenAncestor,
                  let text = message["requestID"] as? String, let id = UUID(uuidString: text),
                  let request = requests.first(where: { $0.id == id }), let model,
                  let chat = model.selectedChat, request.chatID == chat.id, request.sessionID == chat.sessionID,
                  request.resolvedProvider.rawValue == chat.agentID,
                  let actionText = message["action"] as? String,
                  let action = ReaderRequestResponse.Action(rawValue: actionText) else { return true }
            let response = ReaderRequestResponse(id: request.id, chatID: chat.id, sessionID: request.sessionID,
                                                 action: action, answers: message["answers"] as? [String: String] ?? [:], provider: request.resolvedProvider)
            let accepted = ReaderRequestBridge.respond(response)
            page.call("readerRequestResult", ["requestID": text, "accepted": accepted,
                                               "message": accepted ? "Response requested" : "This request is no longer available. Use the terminal."] as [String: Any])
            if accepted {
                let label = action == .allow ? "Approval sent" : action == .deny ? "Denial sent" : action == .answer ? "Answer sent" : "Continue in terminal"
                let entry = ReaderEntry(id: "request-response:\(id.uuidString)", kind: .notice, text: "\(label): \(request.tool)", time: ISO8601DateFormatter().string(from: Date()))
                chat.liveEntries.append(entry)
                model.readerAppend.send((chat.id, [entry]))
                if action == .terminal { release(); ReaderModeController.main?.showTerminal() }
            }
            refresh()
            return true
        case "showTerminal":
            release()
            if ownsMainChat { ReaderModeController.main?.showTerminal() }
            else {
                if model?.subagentBrowser.selection != nil { _ = model?.backFromSubagent() }
                ReaderModeController.main?.showTerminal()
            }
            return true
        default: return false
        }
    }
}
