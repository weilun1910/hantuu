import AppKit
import Combine
import SwiftUI

/// The reader face of the main area: the selected chat's reader page, full width, with the
/// working line or the needs-you banner and the message box below it. MainAreaController
/// installs it over the terminals and asks it what to show.
///
/// Sending types the message into the chat's real terminal as one bracketed paste and then
/// presses Return (`TerminalView.submit`), exactly what pasting into the agent's own box does.
/// Nothing is ever sent while a menu waits in the terminal, because Return would answer it.
final class ReaderModeController: NSObject {
    let model: AppModel
    let mode: ReaderMode
    /// The reduced status of a chat. The self test passes its own.
    var statusProvider: (Chat) -> StatusState? = { StatusCenter.shared.state(of: $0.id) }
    /// MainAreaController re-runs its layout when the face or the peek changes.
    var onLayoutChange: (() -> Void)?

    let root = FillView(color: Theme.background)
    let bottom = NSView()
    let composer = ComposerBox()
    let status = ReaderModeStatusModel()
    private(set) var statusHost: NSView!
    private(set) var peekBar: NSView!
    private(set) var reader: ReaderController?

    private(set) var composerMode: ComposerMode = .none
    private var readyChats = Set<UUID>()
    private var shownChatID: UUID?
    private var drafts: [UUID: String] = [:]
    private var calmChecks = 0
    /// When Stop was pressed, per chat. Claude Code doesn't always report a stopped turn (an
    /// Esc before any output leaves no transcript line and fires no hook), so its status can
    /// stay Working. Once the screen shows the turn has stopped, reader mode believes the
    /// screen.
    private var stoppedAt: [UUID: Date] = [:]
    /// What reader mode typed into each chat during its current turn. A stopped Claude Code
    /// turn puts these back in its own input box, where the next message would join them.
    private var sentThisTurn: [UUID: [String]] = [:]
    private var timer: Timer?
    private var chatSubs = Set<AnyCancellable>()
    private var bag = Set<AnyCancellable>()

    private var bottomHeight: NSLayoutConstraint!
    private var statusHeight: NSLayoutConstraint!
    private var composerHeight: NSLayoutConstraint!
    private var statusGap: NSLayoutConstraint!

    /// The one in the main window, for Files' Option-click.
    static weak var main: ReaderModeController?

    /// The width of the text column, the same as the reader page's (body.main in style.css).
    static let columnWidth: CGFloat = 720
    static let sideMargin: CGFloat = 32

    init(model: AppModel, mode: ReaderMode = .shared) {
        self.model = model
        self.mode = mode
        super.init()
        status.stop = { [weak self] in _ = self?.stop() }
        status.showTerminal = { [weak self] in self?.showTerminal() }
        statusHost = ChromeHostingView(rootView: ReaderModeStatus(state: status))
        peekBar = ChromeHostingView(rootView: PeekBar { [weak self] in self?.backToReader() }.environmentObject(model))
        buildBottom()
        let tv = composer.textView
        tv.onSend = { [weak self] in self?.send() }
        tv.onEscape = { [weak self] in self?.stop() ?? false }
        tv.onCopyWithoutSelection = { [weak self] in self?.copyReaderSelection() }
        tv.onPage = { [weak self] down in self?.page(down: down) }
        composer.onHeightChange = { [weak self] in self?.textChanged() }
        composer.action.target = self
        composer.action.action = #selector(actionPressed)
        mode.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.onLayoutChange?() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSWindow.didUpdateNotification)
            .sink { [weak self] _ in self?.composer.updateColors() }
            .store(in: &bag)
        model.$chats
            .sink { [weak self] chats in self?.mode.settings.forget(except: Set(chats.map(\.id))) }
            .store(in: &bag)
    }

    private func buildBottom() {
        root.translatesAutoresizingMaskIntoConstraints = false
        for v in [bottom, statusHost!, composer] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        root.addSubview(bottom)
        bottom.addSubview(statusHost)
        bottom.addSubview(composer)
        bottomHeight = bottom.heightAnchor.constraint(equalToConstant: 0)
        statusHeight = statusHost.heightAnchor.constraint(equalToConstant: 0)
        composerHeight = composer.heightAnchor.constraint(equalToConstant: composer.preferredHeight)
        var cs = [
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomHeight!, statusHeight!, composerHeight!,
            composer.bottomAnchor.constraint(equalTo: bottom.bottomAnchor, constant: -16),
        ]
        // The working line sits just above the box; the banner is tucked onto its top edge.
        statusGap = statusHost.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -6)
        cs.append(statusGap)
        for v in [statusHost!, composer] as [NSView] {
            let wide = v.widthAnchor.constraint(equalToConstant: Self.columnWidth)
            wide.priority = .defaultHigh
            cs += [
                v.centerXAnchor.constraint(equalTo: bottom.centerXAnchor),
                v.widthAnchor.constraint(lessThanOrEqualToConstant: Self.columnWidth),
                v.leadingAnchor.constraint(greaterThanOrEqualTo: bottom.leadingAnchor, constant: Self.sideMargin),
                wide,
            ]
        }
        NSLayoutConstraint.activate(cs)
    }

    /// Puts the reader face over `sibling` (the terminals) below `top`, and the peek bar at
    /// the bottom of `parent`.
    func install(in parent: NSView, top: NSLayoutYAxisAnchor, above sibling: NSView) {
        Self.main = self
        parent.addSubview(root, positioned: .above, relativeTo: sibling)
        peekBar.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(peekBar, positioned: .above, relativeTo: root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: top),
            root.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            peekBar.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            peekBar.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            peekBar.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            peekBar.heightAnchor.constraint(equalToConstant: 38),
        ])
        root.isHidden = true
        peekBar.isHidden = true
    }

    /// The reader page is made the first time a chat shows it, so the app doesn't start a
    /// second web view for people who never turn reader mode on.
    private func ensureReader() {
        guard reader == nil else { return }
        let r = ReaderController(model: model, page: "reader.html?layout=main", identifier: "hantuu.reader.main", focusless: true)
        (r.page.webView as? FocuslessWebView)?.onMouseDown = { [weak self] in self?.focusComposer() }
        let v = r.view
        v.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(v, positioned: .below, relativeTo: bottom)
        // Text scrolling down to the message box fades out instead of stopping at a hard edge.
        let fade = FadeEdge()
        fade.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(fade, positioned: .above, relativeTo: v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: root.topAnchor),
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            fade.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            fade.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            fade.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            fade.heightAnchor.constraint(equalToConstant: 22),
        ])
        reader = r
    }

    // MARK: Layout

    struct Layout: Equatable {
        var showsReader = false
        var peeking = false
    }

    /// Called by MainAreaController whenever it lays out the selected chat.
    @discardableResult
    func sync(selected: Chat?) -> Layout {
        guard let chat = selected else {
            root.isHidden = true
            peekBar.isHidden = true
            stopTimer()
            return Layout()
        }
        let shows = mode.showsReader(chat)
        let live = isLive(chat)
        let peeking = mode.isPeeking(chat) && live
        if mode.isPeeking(chat) && !live { mode.endPeek(chat) }
        if shows { ensureReader() }
        root.isHidden = !shows
        peekBar.isHidden = !peeking
        if chat.id != shownChatID { switchChat(to: chat) }
        refresh()
        if shows || peeking { startTimer() } else { stopTimer() }
        if shows {
            // A chat terminal that had the keyboard is hidden now, so the message box takes it.
            if let w = root.window, let tv = w.firstResponder as? TerminalView, model.chats.contains(where: { $0.terminal === tv }) {
                w.makeFirstResponder(composerMode == .none ? nil : composer.textView)
            }
        }
        return Layout(showsReader: shows, peeking: peeking)
    }

    private func switchChat(to chat: Chat) {
        if let old = shownChatID { drafts[old] = composer.textView.string.isEmpty ? nil : composer.textView.string }
        shownChatID = chat.id
        composer.textView.text = drafts[chat.id] ?? ""
        composer.textView.placeholder = "Message \(chat.agent.name)"
        composer.action.agentName = chat.agent.name
        calmChecks = 0
        chatSubs.removeAll()
        chat.$activity.combineLatest(chat.$activityDetail, chat.$status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.refresh() }
            .store(in: &chatSubs)
    }

    private func isLive(_ chat: Chat) -> Bool {
        guard let t = chat.terminal else { return false }
        return chat.status != .ended && !t.processExited
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: State

    /// Works out the message box's state for the selected chat and applies it.
    func refresh() {
        guard let chat = model.selectedChat, chat.id == shownChatID else { return }
        let live = isLive(chat)
        var screen = TerminalScreen.State()
        if live, let t = chat.terminal, mode.face(of: chat) == .reader {
            screen = TerminalScreen.analyze(t.activeScreenText())
            if screen.ready { readyChats.insert(chat.id) }
        }
        var activity = chat.activity
        if let at = stoppedAt[chat.id] {
            if activity != .working || (screen.busy && Date().timeIntervalSince(at) > 3) {
                // The status caught up, or the agent carried on after all.
                stoppedAt[chat.id] = nil
            } else if !screen.busy && screen.ready {
                activity = .idle
                // So the sidebar and the header stop reading Working too.
                StatusCenter.shared.stoppedFromReader(chat)
                clearRestoredInput(chat)
            }
        }
        let st = statusProvider(chat)
        if st?.structured == true { readyChats.insert(chat.id) }
        // Agents hantuu has no signals for are taken as ready.
        let ready = readyChats.contains(chat.id) || chat.agent.transcript == nil
        let input = ComposerMode.Input(
            agentName: chat.agent.name, ended: chat.status == .ended, live: live,
            activity: activity, detail: chat.activityDetail,
            waiting: st.map { !$0.waits.isEmpty } ?? chat.activity.isNeeds,
            ready: ready, screenMenu: screen.menu)
        apply(ComposerMode.resolve(input), chat: chat)

        // A peek ends once nothing has waited in the terminal for two checks in a row.
        if mode.isPeeking(chat) {
            if composerMode.isBlocked || !live {
                calmChecks = 0
            } else {
                calmChecks += 1
                if calmChecks >= 2 {
                    calmChecks = 0
                    mode.endPeek(chat)
                    if let t = chat.terminal { model.focusRequest.send(t) }
                }
            }
        }
    }

    private func apply(_ m: ComposerMode, chat: Chat) {
        let changed = m != composerMode || status.chat !== chat
        composerMode = m
        if changed {
            status.chat = chat
            status.mode = m
        }
        composer.isHidden = m == .none
        statusHost.isHidden = ReaderModeStatusModel.height(for: m) == 0
        composer.enabled = !m.isBlocked
        composer.textView.isEditable = m != .none
        composer.textView.placeholder = m.isBlocked ? "Answer in the terminal to carry on" : "Message \(chat.agent.name)"
        updateAction()
        updateHeights()
    }

    /// Send, or Stop while the agent works and the box is empty.
    private func updateAction() {
        let hasText = ComposerMessage.prepare(composer.textView.string) != nil
        composer.action.kind = composerMode.isWorking && !hasText ? .stop : .send
        composer.action.active = composerMode.canSend && hasText
    }

    private func updateHeights() {
        let s = ReaderModeStatusModel.height(for: composerMode)
        let c = composer.preferredHeight
        let gap: CGFloat = composerMode.isBlocked ? -1 : (s > 0 ? 6 : 0)
        statusHeight.constant = s
        statusGap.constant = -gap
        composerHeight.constant = c
        // An ended chat leaves room for the Resume bar MainAreaController draws there.
        bottomHeight.constant = composerMode == .none ? 38 : 14 + s + gap + c + 16
    }

    private func textChanged() {
        updateAction()
        updateHeights()
    }

    // MARK: Actions

    @objc private func actionPressed() {
        if composer.action.kind == .stop { _ = stop() } else { send() }
    }

    /// Types the message into the chat's terminal and presses Return. Returns false, and keeps
    /// the text, when it can't send right now.
    @discardableResult
    func send() -> Bool {
        guard let chat = model.selectedChat, chat.id == shownChatID, let t = chat.terminal else { return false }
        refresh()
        guard let text = ComposerMessage.prepare(composer.textView.string) else { return false }
        guard composerMode.canSend else {
            NSSound.beep()
            return false
        }
        // A message sent while the agent works joins its turn; otherwise it starts a new one.
        if !composerMode.isWorking { sentThisTurn[chat.id] = [] }
        sentThisTurn[chat.id, default: []].append(text)
        t.submit(text)
        composer.textView.text = ""
        drafts[chat.id] = nil
        stoppedAt[chat.id] = nil
        Log.write("reader mode: sent \(text.count) characters to chat=\(chat.id)")
        // Follow the conversation from here, even if you'd scrolled up to read.
        reader?.page.webView.evaluateJavaScript("window.scrollTo(0, document.scrollingElement.scrollHeight); 0", completionHandler: nil)
        return true
    }

    /// Esc in the agent's terminal, which stops the running turn. Only while it's working, so
    /// it can never decline a prompt on your behalf.
    @discardableResult
    func stop() -> Bool {
        guard composerMode.isWorking, let chat = model.selectedChat, let t = chat.terminal else { return false }
        t.pressEscape()
        stoppedAt[chat.id] = Date()
        Log.write("reader mode: stop (Esc) chat=\(chat.id)")
        return true
    }

    /// After a stop, Claude Code puts the stopped message back in its input box, hidden behind
    /// the reader, and the next message would be typed onto the end of it. Deletes it, but only
    /// when the bottom of the screen shows text reader mode sent this turn.
    private func clearRestoredInput(_ chat: Chat) {
        guard let sent = sentThisTurn.removeValue(forKey: chat.id), let t = chat.terminal else { return }
        let n = ComposerMessage.restoredLength(screen: t.activeScreenText(), sent: sent)
        guard n > 0 else { return }
        t.pressBackspace(times: n)
        Log.write("reader mode: cleared \(n) restored characters after stop chat=\(chat.id)")
    }

    /// Shows the live terminal so a menu can be answered there.
    func showTerminal() {
        guard let chat = model.selectedChat, isLive(chat) else { return }
        calmChecks = 0
        mode.peek(chat)
        if let t = chat.terminal { model.focusRequest.send(t) }
    }

    func backToReader() {
        guard let chat = model.selectedChat else { return }
        mode.endPeek(chat)
        if let t = chat.terminal { model.focusRequest.send(t) }
    }

    /// Where the keyboard goes when something asks for the selected chat's terminal: the
    /// message box while the reader is up, so keys never reach the hidden terminal. Nil means
    /// nothing in the main area should have it (an ended chat in the reader).
    func focusTarget(for view: NSView) -> NSView? {
        guard let chat = model.selectedChat, view === chat.terminal, mode.showsReader(chat) else { return view }
        return composerMode == .none ? nil : composer.textView
    }

    func focusComposer() {
        guard !root.isHidden, !composer.isHidden, let w = root.window else { return }
        if w.firstResponder !== composer.textView { w.makeFirstResponder(composer.textView) }
    }

    private func copyReaderSelection() {
        reader?.page.webView.evaluateJavaScript("window.getSelection().toString()") { result, _ in
            guard let s = result as? String, !s.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
    }

    private func page(down: Bool) {
        let js = "window.scrollBy({top: \(down ? "" : "-")(window.innerHeight - 64), behavior: 'smooth'}); 0"
        reader?.page.webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Option-click in Files types a path into the chat. In the reader it goes to the box.
    func insertIntoComposer(_ text: String) -> Bool {
        guard let chat = model.selectedChat, mode.showsReader(chat), composerMode != .none else { return false }
        composer.textView.insertTyped(text)
        focusComposer()
        return true
    }
}

/// A short gradient from clear to the window's background, over the bottom of the reader.
final class FadeEdge: NSView {
    private let gradient = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(gradient)
        updateColors()
        // Layer coordinates: y grows upward, so the opaque end is at the bottom.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        themeObserver = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.updateColors()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) } }
    private var themeObserver: NSObjectProtocol?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bg = Theme.background.usingColorSpace(.sRGB) ?? Theme.background
            gradient.colors = [bg.withAlphaComponent(0).cgColor, bg.cgColor]
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Reader mode's page. It never becomes the first responder, so the keyboard stays in the
/// message box, and a click on it hands the keyboard back to the box. Text can still be
/// selected; Copy with nothing selected in the box copies it. The shared HantuuWebView stays
/// as it was, so the panel's pages behave exactly as before.
final class FocuslessWebView: HantuuWebView {
    var onMouseDown: (() -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onMouseDown?()
    }
}
