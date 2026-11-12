import AppKit
import Combine
import WebKit

/// Owns the live project browsers independently of the panel's SwiftUI lifetime. Future
/// tools can target these same sessions without creating a second, invisible browser.
final class BrowserCoordinator: ObservableObject {
    @Published private(set) var active: BrowserSession?
    @Published private(set) var ports: [ListeningPort] = []
    private(set) var sessions: [UUID: BrowserSession] = [:]
    private var lru = BrowserLRU(capacity: 3)
    private weak var model: AppModel?
    private let review: ReviewCenter
    private var bag = Set<AnyCancellable>()
    private var timer: Timer?
    private var visible = false
    private var chatID: UUID?
    /// Tests supply nonpersistent stores and never touch the real browser profiles.
    var storeFactory: (() -> WKWebsiteDataStore)?

    init(model: AppModel, review: ReviewCenter) {
        self.model = model
        self.review = review
        review.$ports.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.ports = self.review.ports
            if self.visible { self.active?.openIfNeeded(ports: self.ports) }
        }.store(in: &bag)
    }

    func sync(visible: Bool) {
        guard let model else { return }
        objectWillChange.send()
        if chatID != model.selectedChatID || model.subagentBrowser.selection != nil { active?.setPicking(false); chatID = model.selectedChatID }
        self.visible = visible
        let existing = Set(model.projects.map(\.id))
        for id in Array(sessions.keys) where !existing.contains(id) {
            sessions.removeValue(forKey: id)?.dispose()
            lru.remove(id)
        }
        guard visible, let project = model.currentProject else {
            active?.setPicking(false)
            if active != nil { active = nil }
            timer?.invalidate(); timer = nil
            return
        }
        if active?.projectID != project.id {
            active?.setPicking(false)
            if let session = sessions[project.id] { active = session }
            else {
                let session = BrowserSession(projectID: project.id, saved: model.browserPanelState(project: project.id), store: storeFactory?())
                session.save = { [weak model] state in model?.setBrowserPanelState(state, project: project.id) }
                session.onPick = { [weak self, weak session] payload in
                    guard let self, let session, self.active === session else { return }
                    self.sendElement(payload, from: session)
                }
                sessions[project.id] = session
                model.setBrowserPanelState(session.state, project: project.id)
                active = session
            }
            for id in lru.touch(project.id) { sessions.removeValue(forKey: id)?.dispose() }
        }
        ports = review.ports
        active?.openIfNeeded(ports: ports)
        if timer == nil {
            review.refreshPorts()
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.review.refreshPorts() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    var canCompose: Bool {
        guard let model, let chat = model.selectedChat else { return false }
        return model.subagentBrowser.selection == nil && chat.projectID == active?.projectID
    }

    private func target(_ session: BrowserSession) -> UUID? {
        guard active === session, canCompose, let id = model?.selectedChatID else {
            session.notice = "Select a chat to add browser context to its message."
            return nil
        }
        return id
    }
    private func deliver(_ feedback: BrowserFeedback, to chat: UUID, from session: BrowserSession) {
        guard active === session, model?.selectedChatID == chat,
              model?.subagentBrowser.selection == nil,
              ReaderModeController.main?.insertBrowserFeedback(feedback, chatID: chat) == true else {
            session.notice = "The chat changed or its input is unavailable. Try again when the message box is ready."
            return
        }
        session.notice = "Added to the chat's message. Review it before sending."
    }

    func sendScreenshot(_ session: BrowserSession) {
        guard let chat = target(session) else { return }
        let url = session.address, viewport = session.viewport
        session.setPicking(false)
        session.snapshot { [weak self, weak session] image in
            guard let self, let session else { return }
            guard let image else { session.notice = "Couldn't capture the page. Wait for it to load and try again."; return }
            self.deliver(.screenshot(url: url, width: viewport.width, height: viewport.height, image: image), to: chat, from: session)
        }
    }

    private func sendElement(_ payload: [String: Any], from session: BrowserSession) {
        guard let chat = target(session), let bounds = payload["bounds"] as? [String: Double],
              let x = bounds["x"], let y = bounds["y"], let width = bounds["width"], let height = bounds["height"],
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        let url = session.address, viewport = session.viewport, generation = session.generation
        // The picker removes its outline before posting. Wait one rendering turn so it is
        // absent from the screenshot as well as from the DOM.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak session] in
            guard let self, let session, self.active === session, session.address == url, session.generation == generation else { return }
            session.snapshot(rect: CGRect(x: x, y: y, width: width, height: height)) { [weak self, weak session] image in
                guard let self, let session else { return }
                guard let image else { session.notice = "Couldn't capture that element. Select it again after the page loads."; return }
                self.deliver(.element(url: url, width: viewport.width, height: viewport.height, payload: text, image: image), to: chat, from: session)
            }
        }
    }

    func sendLogs(_ session: BrowserSession) {
        guard let chat = target(session) else { return }
        let entries = session.selectedLogs.isEmpty ? session.logs.entries : session.logs.entries.filter { session.selectedLogs.contains($0.id) }
        guard !entries.isEmpty else { return }
        let viewport = session.viewport
        deliver(.logs(url: session.address, width: viewport.width, height: viewport.height, entries: entries), to: chat, from: session)
    }

    func dispose() {
        timer?.invalidate(); timer = nil
        sessions.values.forEach { $0.dispose() }
        sessions.removeAll()
        active = nil
    }
    deinit { timer?.invalidate() }
}
