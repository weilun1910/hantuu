import AppKit
import Combine
import SwiftUI

/// The reader face of the main area: the selected chat's reader page, full width, with the
/// working line or the needs-you banner and the message box below it. MainAreaController
/// installs it over the terminals and asks it what to show.
///
/// Sending types the message into the chat's real terminal as one bracketed paste and then
/// presses Return, exactly what pasting into the agent's own box does. Each image is pasted
/// as its own path, which Claude Code and Codex turn into "[Image #N]". A slash command
/// precedes image chips so the provider can recognize it at the start of the input.
/// Nothing is ever sent while a menu waits in the terminal, because Return would answer it.
final class ReaderModeController: NSObject {
    let model: AppModel
    let mode: ReaderMode
    /// The reduced status of a chat. The self test passes its own.
    var statusProvider: (Chat) -> StatusState? = { StatusCenter.shared.state(of: $0.id) }
    /// MainAreaController re-runs its layout when the face or the peek changes.
    var onLayoutChange: (() -> Void)?
    /// Opt-in live probes veto Return if a safety menu appeared after the paste began.
    var permitsSubmit: (TerminalView) -> Bool = { _ in true }
    /// Optional live-test observation. No clipboard access or image data is involved.
    var observeImageTransport: ((String, Bool, String) -> Void)?

    let root = ReaderLayoutRoot(color: Theme.background)
    let bottom = NSView()
    let composer = ComposerBox()
    let commandMenu = CommandMenu()
    let menuCard = ReaderMenuCard()
    private(set) var mirroredMenu: ReaderMenu?
    private var menuOperation: UUID?
    private var menuNotice: String?
    private var menuMonitor: Any?
    private let commandCatalog: ReaderCommandCatalog
    private var commandContext: ReaderCommandCatalog.Context?
    private var commandLoadAt = Date.distantPast
    private var commandLoading = false
    /// Fixture tests and the independent live-menu probe turn off background discovery.
    var commandDiscoveryEnabled = true
    private var menuProbe: CommandMenuProbe?
    private var menuProbeChatID: UUID?
    private var menuProbeGeneration = UUID()
    private var menuProbeRetryAt = Date.distantPast
    private var waitingToSendAfterProbe = false
    private struct ObservedMenu {
        var context: ReaderCommandCatalog.Context
        var terminal: ObjectIdentifier
        var rows: [ReaderCommand]
    }
    // A running terminal fixes the agent version and account. Never share observations
    // between processes, even if their executable path and working folder are identical.
    private var observedMenus: [UUID: ObservedMenu] = [:]
    private var commandSentAt: [UUID: Date] = [:]
    private var commandPeekAt: [UUID: Date] = [:]
    private var commandMenuHeight: NSLayoutConstraint!
    let status = ReaderModeStatusModel()
    private(set) var statusHost: NSView!
    private(set) var peekBar: NSView!
    private(set) var reader: ReaderController?

    private(set) var composerMode: ComposerMode = .none
    private var readyChats = Set<UUID>()
    private var shownChatID: UUID?
    private var drafts: [UUID: String] = [:]
    private var draftFiles: [UUID: [ComposerAttachment]] = [:]
    /// Messages waiting to be typed, one at a time, so two sends never interleave.
    private struct Outgoing {
        var id: String
        var chatID: UUID
        var tracksPending: Bool
        var terminal: TerminalView
        var steps: [SendStep]
        var files: [URL]
        var command: String?
        var sessionID: String?
        var typedAny = false
        var promote = false
    }
    private var outbox: [Outgoing] = []
    private var typing = false
    private var preparing = Set<String>()
    private var preparationTargets: [String: (UUID, String?, TerminalView)] = [:]
    private var queueReadySince: [UUID: Date] = [:]
    private var submittedAt: [UUID: Date] = [:]
    private var inputRestoration: [UUID: ReaderInputRestoration] = [:]
    private var editingQueueIDs: [UUID: String] = [:]
    private var editingQueueID: String? {
        get { shownChatID.flatMap { editingQueueIDs[$0] } }
        set { if let id = shownChatID { editingQueueIDs[id] = newValue } }
    }
    private var restoringDraft = false
    private let draftStore = ComposerDraftStore()
    let deliveryBar = ComposerControlFlow()
    private var settledScreens: [UUID: (terminal: ObjectIdentifier, session: String?, raw: String, state: TerminalScreen.State)] = [:]
    private var deliveryWidth: NSLayoutConstraint!
    private var recoveryHeight: NSLayoutConstraint!
    private var composerBottom: NSLayoutConstraint!
    private let queueButton = NSButton(title: "Queue", target: nil, action: nil)
    private let steerButton = NSButton(title: "Steer", target: nil, action: nil)
    private let resumeQueueButton = NSButton(title: "Resume queue", target: nil, action: nil)
    private let previousDraftButton = NSButton(title: "Previous draft", target: nil, action: nil)
    private let reviewedInputButton = NSButton(title: "Input reviewed", target: nil, action: nil)
    private let keymapButton = NSButton(title: "Shortcuts", target: nil, action: nil)
    private let cancelQueueEdit = NSButton(title: "Cancel edit", target: nil, action: nil)
    private let deliveryChoice = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recoveryLabel = NSTextField(labelWithString: "")
    private let agentControls = ComposerAgentControlsView()
    private let mentionMenu = ComposerMentionMenu()
    private var mentionMenuHeight: NSLayoutConstraint!
    private var controlsState: ComposerAgentControlsState?
    private var controlsReadAt = Date.distantPast
    private var controlsRecords: [Data] = []
    private var controlsSession: String?
    private var pendingControl: ComposerAgentControlAction?
    enum DeliveryIntent { case steer, queue }

    /// How long to wait for the agent to acknowledge an image before retaining the failed send.
    var imageWait: TimeInterval = 3
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
    static let sideMargin: CGFloat = 16

    init(model: AppModel, mode: ReaderMode = .shared, commandCatalog: ReaderCommandCatalog = ReaderCommandCatalog()) {
        self.model = model
        self.mode = mode
        self.commandCatalog = commandCatalog
        super.init()
        status.stop = { [weak self] in _ = self?.stop() }
        status.showTerminal = { [weak self] in self?.showTerminal() }
        statusHost = ChromeHostingView(rootView: ReaderModeStatus(state: status))
        peekBar = ChromeHostingView(rootView: PeekBar { [weak self] in self?.backToReader() }.environmentObject(model))
        buildBottom()
        menuCard.onChoose = { [weak self] label in _ = self?.chooseMenuOption(label: label) }
        menuCard.onSubmitText = { [weak self] text in _ = self?.submitMenuText(text) }
        menuCard.onKey = { [weak self] key in _ = self?.sendMenuKey(key) }
        menuCard.onTerminal = { [weak self] in self?.showTerminal() }
        menuMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleMenuKey(event) ? nil : event
        }
        draftStore.onFailure = { [weak self] _ in self?.recoveryLabel.stringValue = "Draft could not be saved. Keep this window open and copy your input." }
        let tv = composer.textView
        tv.onSend = { [weak self] in self?.send() }
        tv.onAlternateSend = { [weak self] in
            guard let self else { return }
            _ = self.send(intent: self.deliveryChoice.indexOfSelectedItem == 0 ? .queue : .steer)
        }
        tv.onSelectionChange = { [weak self] in self?.saveDraft() }
        tv.onMentionMenuChange = { [weak self] in self?.updateMentionMenu() }
        tv.onRecallPrompt = { [weak self] in self?.recoveryLabel.stringValue = "Recalled text. Check attachments before sending." }
        mentionMenu.onChoose = { [weak self] index in self?.composer.textView.completeMention(at: index) }
        tv.onSendNow = { [weak self] in
            guard let self, self.model.selectedChat?.agent.id == "claude" else { return false }
            return self.sendFirstQueuedNow()
        }
        tv.onFocusQueue = { [weak self] in self?.focusQueue() ?? false }
        tv.onEscape = { [weak self] in
            guard let self else { return false }
            if self.model.selectedChat?.agent.id == "codex", self.sendFirstQueuedNow() { return true }
            return self.stop()
        }
        tv.onCopyWithoutSelection = { [weak self] in self?.copyReaderSelection() }
        tv.onPage = { [weak self] down in self?.page(down: down) }
        tv.onCommandQuery = { [weak self] in self?.loadCommands() }
        tv.onCommandMenuChange = { [weak self] in self?.updateCommandMenu() }
        commandMenu.choose = { [weak self] index in
            self?.composer.textView.completeCommand(at: index)
            self?.focusComposer()
        }
        composer.onHeightChange = { [weak self] in self?.textChanged() }
        composer.onAttachmentsChange = { [weak self] in self?.textChanged() }
        composer.onRetryAttachment = { [weak self] _ in
            guard let self, let chat = self.model.selectedChat else { return }
            let owner = chat.id
            let originalIDs = self.composer.attachments.map(\.id)
            ComposerAttachmentTransport.prepare(self.composer.attachments, agentID: chat.agentID, changed: { [weak self] attachments in
                guard let self, self.model.selectedChatID == owner, self.composer.attachments.map(\.id) == originalIDs else { return }
                self.composer.setAttachments(attachments)
                self.saveDraft()
            }) { [weak self] attachments, result in
                guard let self, self.model.selectedChatID == owner, self.composer.attachments.map(\.id) == originalIDs else { return }
                self.composer.setAttachments(attachments)
                if case .failure(let error) = result { self.recoveryLabel.stringValue = error.localizedDescription }
                self.saveDraft()
            }
        }
        PastedImages.protectedPathsProvider = { [weak self] in
            guard let self else { return [] }
            return self.draftStore.referencedAttachmentPaths.union(self.model.chats.reduce(into: Set<String>()) { $0.formUnion($1.pendingMessages.referencedAttachmentPaths) })
        }
        PastedImages.cleanUpOnce()
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.saveDraft(); try? self?.draftStore.flush(); self?.model.save() }
            .store(in: &bag)
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

    deinit { timer?.invalidate(); if let menuMonitor { NSEvent.removeMonitor(menuMonitor) } }

    private func buildBottom() {
        root.translatesAutoresizingMaskIntoConstraints = false
        for v in [bottom, statusHost!, composer] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        root.addSubview(bottom)
        bottom.addSubview(statusHost)
        bottom.addSubview(composer)
        menuCard.translatesAutoresizingMaskIntoConstraints = false
        bottom.addSubview(menuCard)
        NSLayoutConstraint.activate([
            menuCard.leadingAnchor.constraint(equalTo: statusHost.leadingAnchor),
            menuCard.trailingAnchor.constraint(equalTo: statusHost.trailingAnchor),
            menuCard.topAnchor.constraint(equalTo: statusHost.topAnchor),
            menuCard.bottomAnchor.constraint(equalTo: statusHost.bottomAnchor),
        ])
        bottomHeight = bottom.heightAnchor.constraint(equalToConstant: 0)
        statusHeight = statusHost.heightAnchor.constraint(equalToConstant: 0)
        composerHeight = composer.heightAnchor.constraint(equalToConstant: composer.preferredHeight)
        composerBottom = composer.bottomAnchor.constraint(equalTo: bottom.bottomAnchor, constant: -90)
        var cs = [
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomHeight!, statusHeight!, composerHeight!,
            composerBottom!,
        ]
        // The working line sits just above the box; the banner is tucked onto its top edge.
        statusGap = statusHost.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -6)
        cs.append(statusGap)
        var columnWidths: [NSLayoutConstraint] = []
        for v in [statusHost!, composer] as [NSView] {
            // Derive the column from the viewport without letting child content hugging
            // shrink the box or impose a preferred minimum on the split view.
            let width = v.widthAnchor.constraint(equalToConstant: Self.columnWidth)
            columnWidths.append(width)
            cs += [
                v.centerXAnchor.constraint(equalTo: bottom.centerXAnchor),
                width,
            ]
        }
        NSLayoutConstraint.activate(cs)
        root.onWidthChange = { width in
            guard width > 0 else { return }
            let inset: CGFloat = width < 480 ? 16 : 32
            columnWidths.forEach { $0.constant = min(Self.columnWidth, max(0, width - 2 * inset)) }
        }
        deliveryChoice.addItems(withTitles: ["Return: Steer", "Return: Queue"])
        deliveryChoice.selectItem(at: 1)
        deliveryChoice.controlSize = .small
        deliveryChoice.toolTip = "While working: Return uses this action; Command-Return uses the other. Queue stays in hantuu until the next turn."
        for button in [queueButton, steerButton, resumeQueueButton, cancelQueueEdit, previousDraftButton, reviewedInputButton, keymapButton] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 11)
            button.target = self
        }
        queueButton.action = #selector(queuePressed)
        steerButton.action = #selector(steerPressed)
        resumeQueueButton.action = #selector(resumeQueuePressed)
        cancelQueueEdit.action = #selector(cancelEditPressed)
        previousDraftButton.action = #selector(previousDraftPressed)
        reviewedInputButton.action = #selector(reviewedInputPressed)
        reviewedInputButton.toolTip = "Confirm you inspected and cleared any leftover input in the terminal. This does not send."
        keymapButton.action = #selector(keymapPressed)
        queueButton.toolTip = "Keep this message in hantuu for the next turn."
        steerButton.toolTip = "Send to the current turn. Claude reads it at a tool boundary; Codex uses Enter steering."
        let actions: [(NSButton, String)] = [(queueButton, "tray"), (steerButton, "arrow.turn.up.right"),
            (deliveryChoice, "return"), (resumeQueueButton, "play"), (cancelQueueEdit, "xmark"),
            (previousDraftButton, "clock.arrow.circlepath"), (reviewedInputButton, "checkmark"), (keymapButton, "keyboard")]
        actions.forEach { deliveryBar.addArrangedSubview($0.0, symbol: $0.1) }
        recoveryLabel.font = .systemFont(ofSize: 11)
        recoveryLabel.textColor = .secondaryLabelColor
        recoveryLabel.lineBreakMode = .byWordWrapping
        recoveryLabel.maximumNumberOfLines = 2
        recoveryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [deliveryBar, agentControls, recoveryLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            composer.addSubview(view)
        }
        mentionMenu.translatesAutoresizingMaskIntoConstraints = false
        bottom.addSubview(mentionMenu)
        agentControls.onAction = { [weak self] action in self?.requestControl(action) }
        mentionMenuHeight = mentionMenu.heightAnchor.constraint(equalToConstant: 0)
        deliveryWidth = deliveryBar.widthAnchor.constraint(equalToConstant: 0)
        recoveryHeight = recoveryLabel.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            deliveryBar.leadingAnchor.constraint(equalTo: composer.attach.trailingAnchor, constant: 4),
            deliveryBar.centerYAnchor.constraint(equalTo: composer.action.centerYAnchor),
            deliveryBar.heightAnchor.constraint(equalToConstant: 22), deliveryWidth!,
            agentControls.leadingAnchor.constraint(equalTo: deliveryBar.trailingAnchor, constant: 4),
            agentControls.trailingAnchor.constraint(equalTo: composer.action.leadingAnchor, constant: -4),
            agentControls.centerYAnchor.constraint(equalTo: composer.action.centerYAnchor),
            agentControls.heightAnchor.constraint(equalToConstant: 22),
            recoveryLabel.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 12),
            recoveryLabel.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -12),
            recoveryLabel.topAnchor.constraint(equalTo: composer.action.bottomAnchor, constant: 8),
            recoveryHeight!,
            mentionMenu.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            mentionMenu.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            mentionMenu.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -6), mentionMenuHeight,
        ])
        commandMenu.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(commandMenu)
        commandMenuHeight = commandMenu.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            commandMenu.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            commandMenu.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            commandMenu.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -6),
            commandMenuHeight,
        ])
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
        r.onSendNow = { [weak self] chatID, id in _ = self?.sendNow(chatID: chatID, id: id) }
        r.onQueueAction = { [weak self] chatID, id, action in self?.queueAction(chatID: chatID, id: id, action: action) }
        r.onEditAsNew = { [weak self] chatID, id in self?.editAsNew(chatID: chatID, id: id) }
        r.onFocusComposer = { [weak self] in self?.focusComposer() }
        // Restore ordinary typing synchronously. The page requests focus for the actual
        // clicked control; a previously focused DOM element is not evidence of this click.
        (r.page.webView as? FocuslessWebView)?.onMouseDown = { [weak self] in self?.focusComposer() }
        // Files and pictures dropped anywhere on the reader go into the message box.
        (r.page.webView as? FocuslessWebView)?.onDropAttachments = { [weak self] content in
            guard let self, !self.composer.isHidden, self.composerMode != .none else { return false }
            self.composer.attach(content)
            self.focusComposer()
            return true
        }
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
        if selected?.id != shownChatID || selected.map({ !mode.showsReader($0) }) != false { clearMirroredMenu() }
        if selected?.id != menuProbeChatID || selected.map({ !mode.showsReader($0) }) == true { cancelMenuProbe() }
        guard let chat = selected else {
            root.isHidden = true
            peekBar.isHidden = true
            refreshQueues()
            updateTimer()
            return Layout()
        }
        let shows = mode.showsReader(chat)
        if mode.face(of: chat) != .reader { observedMenus[chat.id] = nil }
        let live = isLive(chat)
        let peeking = mode.isPeeking(chat) && live
        if mode.isPeeking(chat) && !live { mode.endPeek(chat) }
        if shows { ensureReader() }
        root.isHidden = !shows
        peekBar.isHidden = !peeking
        if chat.id != shownChatID { switchChat(to: chat) }
        refresh()
        updateTimer()
        if shows {
            // A chat terminal that had the keyboard is hidden now, so the message box takes it.
            if let w = root.window, let tv = w.firstResponder as? TerminalView, model.chats.contains(where: { $0.terminal === tv }) {
                w.makeFirstResponder(composerMode == .none ? nil : composer.textView)
            }
        }
        return Layout(showsReader: shows, peeking: peeking)
    }

    private func switchChat(to chat: Chat) {
        clearMirroredMenu()
        if shownChatID != nil {
            saveDraft()
            try? draftStore.flush()
        }
        restoringDraft = true
        defer { restoringDraft = false }
        pendingControl = nil
        if (reader?.page.webView as? FocuslessWebView)?.allowsQueueFocus == true { focusComposer() }
        if let old = shownChatID {
            drafts[old] = composer.textView.string.isEmpty ? nil : composer.textView.string
            draftFiles[old] = composer.attachments.isEmpty ? nil : composer.attachments
        }
        shownChatID = chat.id
        commandContext = ReaderCommandCatalog.Context(agent: chat.agent.id, folder: model.workingDirectory(of: chat), transcript: chat.transcriptPath)
        commandLoadAt = .distantPast
        commandLoading = false
        composer.textView.dismissCommands()
        composer.textView.allowsSkillMentions = chat.agent.id == "codex"
        composer.textView.commandCatalog = commandsForChat(ReaderCommandCatalog.builtins(agent: chat.agent.id), chat: chat)
        let savedDraft = draftStore.draft(chatID: chat.id)
        composer.textView.mentionCheckout = URL(fileURLWithPath: model.workingDirectory(of: chat))
        composer.textView.mentionChatID = chat.id
        composer.textView.promptHistory = ComposerPromptHistory.prompts(from: chat.allEntries)
        composer.textView.resetPromptRecall()
        composer.textView.text = savedDraft?.text ?? drafts[chat.id] ?? ""
        composer.textView.setSelectedRange(NSRange(location: (composer.textView.string as NSString).length, length: 0))
        composer.setAttachments(savedDraft?.restoredAttachments() ?? draftFiles[chat.id] ?? [])
        if let savedDraft { composer.textView.setSelectedRange(savedDraft.clampedSelection) }
        controlsSession = nil
        controlsReadAt = .distantPast
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

    private func updateTimer() {
        let visible = model.selectedChat.map { mode.showsReader($0) || mode.isPeeking($0) } ?? false
        let pending = model.chats.contains { isLive($0) && !$0.pendingMessages.isEmpty }
        if visible || pending || isTyping { startTimer() } else { stopTimer() }
    }

    /// First identity discovery binds an existing send. A replacement session never does.
    private func matchesSession(_ chat: Chat, expected: String?, pendingID: String?) -> Bool {
        if expected == chat.sessionID { return true }
        guard expected == nil, let pendingID, let recovery = chat.pendingMessages.recovery(id: pendingID) else { return false }
        return recovery.sessionID == chat.sessionID
    }

    /// Delivery belongs to the owning chat, regardless of the currently displayed face.
    private func refreshQueues() {
        let pendingChats = Set(model.chats.filter { !$0.pendingMessages.isEmpty }.map(\.id))
        inputRestoration = inputRestoration.filter { pendingChats.contains($0.key) }
        for chat in model.chats where !chat.pendingMessages.isEmpty {
            if chat.pendingMessages.expire() { model.save() }
            guard isLive(chat), let terminal = chat.terminal, terminal.geometryIsStable else {
                queueReadySince[chat.id] = nil
                continue
            }
            let raw = terminal.activeScreenText()
            let screen = TerminalScreen.analyze(raw)
            observeRestoredInput(chat, terminal: terminal, raw: raw, screen: screen)
            let st = statusProvider(chat)
            let editing = editingQueueIDs[chat.id] != nil
            let controlWaiting = model.selectedChatID == chat.id && pendingControl != nil
            let ready = ReaderQueueDrain.canStart(screen: screen, activity: chat.activity,
                waiting: st?.waits.isEmpty == false, turnActive: st?.turnActive == true,
                identityWaiting: chat.codexIdentityWaiting, paused: chat.pendingMessages.queuePaused,
                inputNeedsReview: chat.pendingMessages.inputNeedsReview, editing: editing,
                transportBusy: isTyping || !outbox.isEmpty || menuProbeChatID == chat.id || controlWaiting || (model.selectedChatID == chat.id && (mirroredMenu != nil || menuOperation != nil || reader?.interaction.hasPendingRequest == true)))
            guard ready, let id = chat.pendingMessages.firstWaitingID else { queueReadySince[chat.id] = nil; continue }
            // Wait for a stable ready frame after the previous Return. Status and screen
            // updates can arrive separately, especially when the terminal is not selected.
            let now = Date()
            guard now.timeIntervalSince(submittedAt[chat.id] ?? .distantPast) >= 1 else { continue }
            guard let since = queueReadySince[chat.id], now.timeIntervalSince(since) >= 0.5 else {
                if queueReadySince[chat.id] == nil { queueReadySince[chat.id] = now }
                continue
            }
            queueReadySince[chat.id] = nil
            startPending(chat, id: id)
        }
    }

    /// A Return does not redraw the CLI synchronously. Its old input is not a restore.
    private func observeRestoredInput(_ chat: Chat, terminal: TerminalView, raw: String, screen: TerminalScreen.State) {
        guard !chat.pendingMessages.inputNeedsReview,
              !outbox.contains(where: { $0.chatID == chat.id }),
              var observation = inputRestoration[chat.id],
              observation.terminal == ObjectIdentifier(terminal) else { return }
        guard let recovery = chat.pendingMessages.recovery(id: observation.pendingID) else {
            inputRestoration[chat.id] = nil
            return
        }
        if observation.sessionID != chat.sessionID {
            guard observation.sessionID == nil, recovery.sessionID == chat.sessionID else {
                inputRestoration[chat.id] = nil
                return
            }
            observation.sessionID = chat.sessionID
        }
        let restored = observation.observe(empty: screen.ready && screen.menu == nil && CommandMenuScreen.emptyInput(raw, agent: chat.agentID),
            matches: chat.pendingMessages.isRestored(in: raw),
            eligible: screen.ready && !screen.busy && screen.menu == nil)
        inputRestoration[chat.id] = observation
        if restored {
            chat.pendingMessages.inputNeedsReview = true
            cancelTransport(chat, reason: "The terminal restored input. Check it before resending.")
        }
    }

    // MARK: State

    /// Works out the message box's state for the selected chat and applies it.
    func refresh() {
        reader?.interaction.refresh()
        refreshQueues()
        updateTimer()
        guard let chat = model.selectedChat, chat.id == shownChatID else { return }
        let live = isLive(chat)
        if live, chat.codexIdentityWaiting {
            clearMirroredMenu()
            apply(.blocked(title: "Waiting for session identity", detail: "The Codex session is being verified. You can inspect it in the terminal."), chat: chat)
            return
        }
        var screen = TerminalScreen.State()
        var rawScreen = ""
        if let t = chat.terminal, let previous = settledScreens[chat.id],
           previous.terminal == ObjectIdentifier(t), previous.session == chat.sessionID {
            rawScreen = previous.raw
            screen = previous.state
        }
        let screenIsStable = chat.terminal?.geometryIsStable == true
        if live, let t = chat.terminal, mode.face(of: chat) == .reader, screenIsStable {
            rawScreen = t.activeScreenText()
            screen = TerminalScreen.analyze(rawScreen)
            settledScreens[chat.id] = (ObjectIdentifier(t), chat.sessionID, rawScreen, screen)
            if screen.ready { readyChats.insert(chat.id) }
            if menuProbe != nil {
                if !mayProbe(chat, terminal: t) { cancelMenuProbe() }
                else { screen.menu = nil }
            }
        }
        reader?.interaction.refresh()
        let structured = reader?.interaction.hasPendingRequest == true
        let sameScreenOwner = chat.terminal.map { terminal in
            settledScreens[chat.id].map { $0.terminal == ObjectIdentifier(terminal) && $0.session == chat.sessionID } ?? false
        } ?? false
        let menuEligible = live && mode.showsReader(chat) && menuProbe == nil && !structured
        let parsed = menuEligible
            ? (screenIsStable ? ReaderMenuParser.parse(rawScreen, agent: chat.agent.id) : (sameScreenOwner ? mirroredMenu : nil))
            : nil
        if parsed == nil { if menuOperation == nil || structured { clearMirroredMenu() } }
        else {
            let enteringInput = mirroredMenu?.input == nil && parsed?.input != nil
            if mirroredMenu?.identity != parsed?.identity { menuNotice = nil }
            mirroredMenu = parsed
            menuCard.update(menu: parsed, busy: menuOperation != nil || !screenIsStable, notice: menuNotice)
            if enteringInput { menuCard.focusInput() }
            screen.menu = ScreenMenu(kind: .menu, line: parsed!.title)
            composer.textView.dismissCommands()
            commandMenu.isHidden = true
            mentionMenu.isHidden = true
        }
        var activity = chat.activity
        if screenIsStable, let at = stoppedAt[chat.id] {
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
        let sendNowAvailable = composerMode.isWorking && mode.showsReader(chat) &&
            !outbox.contains(where: { $0.chatID == chat.id }) &&
            screenIsStable && QueuedSendNow.available(agentID: chat.agent.id, screen: rawScreen)
        if chat.pendingMessages.sendNowEnabled != sendNowAvailable {
            chat.pendingMessages.sendNowEnabled = sendNowAvailable
        }

        if screenIsStable, !typing, menuProbe == nil, mirroredMenu == nil, !structured,
           ReaderCommandLogic.autoPeek(sentAt: commandSentAt[chat.id], now: Date(), menu: screen.menu),
           mode.showsReader(chat) {
            commandPeekAt[chat.id] = Date()
            showTerminal()
        }
        if hasSlashQuery { loadCommands() }
        if chat.pendingMessages.expire() { model.save() }
        refreshControls(chat)
        composer.textView.promptHistory = ComposerPromptHistory.prompts(from: chat.allEntries)
        if composerMode == .ready, !screen.busy, screen.ready, outbox.isEmpty, preparing.isEmpty {
            if let action = pendingControl { pendingControl = nil; requestControl(action); return }
        }

        // A peek ends once nothing has waited in the terminal for two checks in a row.
        if screenIsStable, mode.isPeeking(chat) {
            let commandWaiting = commandPeekAt[chat.id].map { Date().timeIntervalSince($0) < 2 || !screen.ready || screen.busy } ?? false
            if composerMode.isBlocked || !live || commandWaiting {
                calmChecks = 0
            } else {
                calmChecks += 1
                if calmChecks >= 2 {
                    calmChecks = 0
                    commandPeekAt[chat.id] = nil
                    commandSentAt[chat.id] = nil
                    finishPeek(chat)
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
        statusHost.isHidden = mirroredMenu != nil || ReaderModeStatusModel.height(for: m) == 0
        composer.enabled = !m.isBlocked
        composer.textView.isEditable = m != .none
        composer.textView.placeholder = m.isBlocked ? (mirroredMenu != nil ? "Answer the menu above to carry on" : "Answer the request above or show the terminal") : "Message \(chat.agent.name)"
        deliveryBar.isHidden = m == .none
        agentControls.isHidden = m == .none
        queueButton.isHidden = !m.isWorking
        steerButton.isHidden = !m.isWorking
        deliveryChoice.isHidden = !m.isWorking
        resumeQueueButton.isHidden = !chat.pendingMessages.queuePaused || chat.pendingMessages.firstWaitingID == nil
        cancelQueueEdit.isHidden = editingQueueID == nil
        previousDraftButton.isHidden = draftStore.draft(chatID: chat.id, scope: "before-recovery") == nil || editingQueueID != nil
        reviewedInputButton.isHidden = !chat.pendingMessages.inputNeedsReview
        deliveryBar.needsLayout = true
        updateAction()
        updateHeights()
    }

    /// Send, or Stop while the agent works and the box is empty.
    private func updateAction() {
        let hasContent = ComposerMessage.prepare(composer.textView.string) != nil || !composer.attachments.isEmpty
        composer.action.kind = composerMode.isWorking && !hasContent ? .stop : .send
        composer.action.active = composerMode.canSend && hasContent && model.selectedChat?.pendingMessages.inputNeedsReview != true && !composer.attachments.contains { $0.preparation == .preparing }
    }

    private func updateHeights() {
        let s = mirroredMenu == nil ? ReaderModeStatusModel.height(for: composerMode) : menuCard.preferredHeight
        let available = max(0, composer.bounds.width - 83)
        let showLabels = deliveryBar.preferredWidth + 4 + agentControls.preferredWidth <= available
        let modelWidth = showLabels ? agentControls.preferredWidth : 94
        deliveryWidth.constant = max(0, min(deliveryBar.preferredWidth, available - modelWidth - 4))
        deliveryBar.needsLayout = true
        agentControls.needsLayout = true
        let recovery: CGFloat = recoveryLabel.stringValue.isEmpty ? 0 : 28
        recoveryLabel.isHidden = recovery == 0
        recoveryHeight.constant = recovery
        composer.accessoryHeight = recovery > 0 ? recovery + 9 : 0
        let c = composer.preferredHeight
        composerBottom.constant = -7
        recoveryLabel.toolTip = recoveryLabel.stringValue
        let gap: CGFloat = composerMode.isBlocked ? -1 : (s > 0 ? 6 : 0)
        statusHeight.constant = s
        statusGap.constant = -gap
        composerHeight.constant = c
        // An ended chat leaves room for the Resume bar MainAreaController draws there.
        bottomHeight.constant = composerMode == .none ? 38 : 14 + s + gap + c + 7
    }

    private func textChanged() {
        saveDraft()
        updateAction()
        updateHeights()
    }

    private func updateCommandMenu() {
        let tv = composer.textView
        commandMenu.show(tv.commandSuggestions, selection: tv.commandSelection)
        commandMenuHeight?.constant = CGFloat(min(tv.commandSuggestions.count, 6)) * 42
    }

    private func loadCommands() {
        guard let chat = model.selectedChat, chat.id == shownChatID else { return }
        let context = ReaderCommandCatalog.Context(agent: chat.agent.id, folder: model.workingDirectory(of: chat), transcript: chat.transcriptPath)
        if context != commandContext { commandContext = context; commandLoadAt = .distantPast; commandLoading = false }
        guard !commandLoading, Date().timeIntervalSince(commandLoadAt) >= 5 else { return }
        commandLoading = true
        commandLoadAt = Date()
        commandCatalog.load(context) { [weak self] commands in
            guard let self, self.commandContext == context, self.model.selectedChat === chat else { return }
            self.commandLoading = false
            self.composer.textView.commandCatalog = self.commandsForChat(commands, chat: chat)
            self.discoverCommands(chat)
        }
    }

    private func commandsForChat(_ commands: [ReaderCommand], chat: Chat) -> [ReaderCommand] {
        guard let terminal = chat.terminal, let observed = observedMenus[chat.id],
              observed.context == commandContext, observed.terminal == ObjectIdentifier(terminal) else { return commands }
        return CommandMenuScreen.reconcile(commands, observed: observed.rows, complete: true)
    }

    private func mayProbe(_ chat: Chat, terminal: TerminalView) -> Bool {
        CommandMenuProbe.supportsAutomaticHarvest(agent: chat.agent.id) && commandDiscoveryEnabled && model.selectedChat === chat && chat.id == shownChatID &&
            chat.terminal === terminal && terminal.geometryIsStable && mode.showsReader(chat) && isLive(chat) &&
            model.subagentBrowser.selection == nil && composerMode == .ready && !typing && outbox.isEmpty &&
            chat.activity != .working && chat.activity != .background && !chat.activity.isNeeds &&
            (statusProvider(chat)?.waits.isEmpty ?? true) && !root.isHidden && root.window != nil &&
            root.window?.firstResponder !== terminal
    }

    private var hasSlashQuery: Bool {
        let text = composer.textView
        return !text.hasMarkedText() && ReaderCommandLogic.query(text.string, selection: text.selectedRange(), skills: false) != nil
    }

    private func discoverCommands(_ chat: Chat) {
        guard let terminal = chat.terminal, let context = commandContext,
              menuProbe == nil, Date() >= menuProbeRetryAt, mayProbe(chat, terminal: terminal),
              hasSlashQuery else { return }
        if let observed = observedMenus[chat.id], observed.context == context,
           observed.terminal == ObjectIdentifier(terminal) { return }
        let generation = UUID()
        menuProbeGeneration = generation
        menuProbeChatID = chat.id
        let probe = CommandMenuProbe(agent: chat.agent.id, io: .init(
            screen: { [weak terminal] in terminal.flatMap { $0.geometryIsStable ? $0.activeScreenText() : nil } ?? "" },
            allowed: { [weak self, weak chat, weak terminal] in
                guard let self, let chat, let terminal else { return false }
                return self.menuProbeGeneration == generation && self.mayProbe(chat, terminal: terminal)
            },
            slash: { [weak terminal] in terminal?.typeCommandText("/") },
            down: { [weak terminal] in terminal?.pressCommandMenuDown() },
            escape: { [weak terminal] in terminal?.pressEscape() },
            backspace: { [weak terminal] in terminal?.pressBackspace(times: 1) }
        )) { [weak self, weak chat, weak terminal] rows, complete in
            guard let self, let chat, let terminal, self.menuProbeGeneration == generation else { return }
            self.menuProbe = nil
            self.menuProbeChatID = nil
            self.menuProbeRetryAt = Date().addingTimeInterval(complete ? 0 : 30)
            guard self.commandContext == context, self.model.selectedChat === chat else { return }
            if complete {
                self.observedMenus[chat.id] = ObservedMenu(context: context, terminal: ObjectIdentifier(terminal), rows: rows)
            }
            self.composer.textView.commandCatalog = CommandMenuScreen.reconcile(
                self.composer.textView.commandCatalog, observed: rows, complete: complete)
            self.refresh()
        }
        menuProbe = probe
        if !probe.start() {
            menuProbe = nil
            menuProbeChatID = nil
            menuProbeRetryAt = Date().addingTimeInterval(5)
        }
    }

    private func cancelMenuProbe() {
        guard let probe = menuProbe else { return }
        menuProbeGeneration = UUID()
        probe.cancel()
        menuProbe = nil
        menuProbeChatID = nil
        menuProbeRetryAt = Date().addingTimeInterval(5)
    }

    var isDiscoveringCommands: Bool { menuProbe != nil }
    var hasObservedCommands: Bool {
        guard let chat = model.selectedChat, let terminal = chat.terminal, let observed = observedMenus[chat.id] else { return false }
        return observed.context == commandContext && observed.terminal == ObjectIdentifier(terminal)
    }

    // MARK: Actions

    @objc private func actionPressed() {
        if composer.action.kind == .stop { _ = stop() } else { send() }
    }

    /// Types the message and its attachments into the chat's terminal and presses Return.
    /// Returns false, and keeps everything in the box, when it can't send right now.
    @discardableResult
    func send(intent: DeliveryIntent? = nil) -> Bool {
        guard let chat = model.selectedChat, chat.id == shownChatID, let t = chat.terminal else { return false }
        // Side commands never use the parent terminal, even while it is resizing.
        let text = ComposerMessage.prepare(composer.textView.string)
        let attachments = composer.attachments
        guard text != nil || !attachments.isEmpty else { return false }
        if let text, let question = SideQuestionCommand.question(text, agent: chat.agentID, reader: mode.showsReader(chat)) {
            model.openSideQuestions(in: chat)
            // Side questions use the saved conversation context and their own input. Leave
            // attachments in this composer rather than silently sending them elsewhere.
            guard attachments.isEmpty else { NSSound.beep(); return false }
            if question.isEmpty {
                composer.textView.text = ""
                drafts[chat.id] = nil
                return true
            }
            guard model.askSideQuestion(question, in: chat) else { return false }
            composer.textView.text = ""
            drafts[chat.id] = nil
            return true
        }
        guard !chat.codexIdentityWaiting else { return false }
        if waitingToSendAfterProbe { return false }
        if menuProbe != nil {
            cancelMenuProbe()
            waitingToSendAfterProbe = true
            let draft = composer.textView.string
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak chat] in
                guard let self else { return }
                self.waitingToSendAfterProbe = false
                guard let chat, self.model.selectedChat === chat, self.composer.textView.string == draft else { return }
                // Never join a command to a probe that could not restore its empty input.
                guard CommandMenuScreen.emptyInput(t.activeScreenText(), agent: chat.agent.id) else { self.showTerminal(); return }
                _ = self.send(intent: intent)
            }
            return true
        }
        refresh()
        guard composerMode.canSend, !chat.pendingMessages.inputNeedsReview,
              !attachments.contains(where: { $0.preparation == .preparing }) else {
            recoveryLabel.stringValue = chat.pendingMessages.inputNeedsReview ? "Check terminal input, then choose Input reviewed." : "Wait for attachments to finish preparing."
            NSSound.beep()
            return false
        }
        if let editingQueueID, chat.pendingMessages.stage(id: editingQueueID) != .waiting {
            recoveryLabel.stringValue = "This queued message changed. Cancel editing to restore your previous draft."
            return false
        }
        let sendID = editingQueueID ?? "pending-" + UUID().uuidString
        let chosen = intent ?? (deliveryChoice.indexOfSelectedItem == 1 ? .queue : .steer)
        let working = composerMode.isWorking || chat.activity == .working || (t.geometryIsStable && TerminalScreen.analyze(t.activeScreenText()).busy) || statusProvider(chat)?.turnActive == true
        let wait = working && chosen == .queue || editingQueueID != nil
        chat.pendingMessages.enqueue(id: sendID, text: text, files: [], agentID: chat.agent.id,
                                     existing: chat.allEntries, stage: wait ? .waiting : .preparing,
                                     attachments: attachments, sessionID: chat.sessionID)
        model.save()
        if editingQueueID != nil { finishQueueEdit(chat) }
        else {
            composer.textView.text = ""
            composer.setAttachments([])
            drafts[chat.id] = nil
            draftFiles[chat.id] = nil
            saveDraft()
        }
        queueReadySince[chat.id] = nil
        startTimer()
        if !wait { startPending(chat, id: sendID) }
        stoppedAt[chat.id] = nil
        reader?.page.webView.evaluateJavaScript("window.scrollTo(0, document.scrollingElement.scrollHeight); 0", completionHandler: nil)
        return true
    }

    /// Shared panel transport preserves the composer and uses the normal pending receipt.
    @discardableResult
    func sendPanelFeedback(text: String, chatID: UUID, id: String) -> Bool {
        guard let chat = model.selectedChat, chat.id == chatID,
              let terminal = chat.terminal, isLive(chat), let text = ComposerMessage.prepare(text) else { return false }
        let screen = TerminalScreen.analyze(terminal.activeScreenText())
        let status = statusProvider(chat)
        let input = ComposerMode.Input(agentName: chat.agent.name, ended: chat.status == .ended,
            live: true, activity: chat.activity, detail: chat.activityDetail,
            waiting: status.map { !$0.waits.isEmpty } ?? chat.activity.isNeeds,
            ready: screen.ready || status?.structured == true || chat.agent.transcript == nil,
            screenMenu: screen.menu)
        guard ComposerMode.resolve(input).canSend, !chat.codexIdentityWaiting,
              !chat.pendingMessages.inputNeedsReview else { return false }
        chat.pendingMessages.enqueue(id: id, text: text, files: [], agentID: chat.agent.id,
                                     existing: chat.allEntries,
                                     stage: chat.activity == .working || screen.busy || status?.turnActive == true ? .waiting : .preparing,
                                     sessionID: chat.sessionID)
        model.save()
        startTimer()
        if chat.pendingMessages.stage(id: id) != .waiting { startPending(chat, id: id) }
        return true
    }

    /// Draft insertion is native and chat-owned, including when the terminal is visible.
    func addPanelFeedbackToDraft(_ text: String, chatID: UUID) -> Bool {
        guard model.selectedChat?.id == chatID else { return false }
        if shownChatID == chatID {
            let old = composer.textView.string
            composer.textView.text = old + (old.isEmpty ? "" : "\n\n") + text
            drafts[chatID] = composer.textView.string
            saveDraft()
            focusComposer()
        } else {
            var draft = draftStore.draft(chatID: chatID) ?? ComposerDraft(text: drafts[chatID] ?? "", selection: NSRange(location: 0, length: 0), attachments: [])
            draft.text += (draft.text.isEmpty ? "" : "\n\n") + text
            draft.selectionLocation = (draft.text as NSString).length
            draft.selectionLength = 0
            draftStore.save(draft, chatID: chatID)
            drafts[chatID] = draft.text
        }
        return true
    }

    @objc private func previousDraftPressed() { if let chat = model.selectedChat { finishQueueEdit(chat) } }
    @objc private func reviewedInputPressed() {
        guard let chat = model.selectedChat else { return }
        chat.pendingMessages.inputNeedsReview = false
        stoppedAt[chat.id] = nil
        sentThisTurn[chat.id] = nil
        model.save()
        recoveryLabel.stringValue = "Input review confirmed. Queued work stays held until Resume queue."
        refresh()
    }
    @objc private func keymapPressed() {
        let alert = NSAlert()
        alert.messageText = "Reader shortcuts"
        alert.informativeText = "Command-L: focus message box\nOption-Command-A: attach files\nReturn: send or the selected Queue/Steer action\nCommand-Return: alternate Queue/Steer action\nShift-Return or Option-Return: newline\nControl-Return: Claude Send queue now\nEscape: dismiss suggestions first; Codex may send its pending steers, otherwise native interrupt\nShift-Tab: focus pending message actions\nUp/Down: recall at a text boundary\n@: search this checkout\nShift-Command-R: reader/terminal"
        alert.addButton(withTitle: "Done")
        if let window = root.window { alert.beginSheetModal(for: window) }
    }
    @objc private func queuePressed() { _ = send(intent: .queue) }
    @objc private func steerPressed() { _ = send(intent: .steer) }
    @objc private func cancelEditPressed() { if let chat = model.selectedChat { finishQueueEdit(chat) } }
    @objc private func resumeQueuePressed() {
        guard let chat = model.selectedChat else { return }
        chat.pendingMessages.queuePaused = false
        model.save()
        refresh()
        if composerMode == .ready, !isTyping, editingQueueID == nil, let id = chat.pendingMessages.firstWaitingID { startPending(chat, id: id) }
    }

    private func saveDraft() {
        guard !restoringDraft, let id = shownChatID else { return }
        draftStore.save(ComposerDraft(text: composer.textView.string, selection: composer.textView.selectedRange(), attachments: composer.attachments), chatID: id)
    }

    private func installDraft(_ draft: ComposerDraft) {
        restoringDraft = true
        composer.textView.text = draft.text
        composer.setAttachments(draft.restoredAttachments())
        composer.textView.setSelectedRange(draft.clampedSelection)
        restoringDraft = false
        saveDraft()
        focusComposer()
    }

    private func preserveDraft(_ chat: Chat) {
        draftStore.save(ComposerDraft(text: composer.textView.string, selection: composer.textView.selectedRange(), attachments: composer.attachments), chatID: chat.id, scope: "before-recovery")
        try? draftStore.flush()
    }

    private func finishQueueEdit(_ chat: Chat) {
        editingQueueID = nil
        if let original = draftStore.draft(chatID: chat.id, scope: "before-recovery") { installDraft(original) }
        draftStore.save(nil, chatID: chat.id, scope: "before-recovery")
        cancelQueueEdit.isHidden = true
    }

    private func queueAction(chatID: UUID, id: String, action: String) {
        guard let chat = model.selectedChat, chat.id == chatID,
              let recovery = chat.pendingMessages.recovery(id: id) else { return }
        let owned = chat.pendingMessages.stage(id: id) == .waiting
        switch action {
        case "terminal": showTerminal()
        case "resume": resumeQueuePressed()
        case "remove" where owned: chat.pendingMessages.remove(id: id)
        case "up" where owned: chat.pendingMessages.move(id: id, offset: -1)
        case "down" where owned: chat.pendingMessages.move(id: id, offset: 1)
        case "send" where owned, "sendWithQueue" where owned:
            _ = sendNow(chatID: chatID, id: id)
        case "edit" where owned:
            preserveDraft(chat)
            editingQueueID = id
            installDraft(ComposerDraft(text: recovery.text ?? "", selection: NSRange(location: (recovery.text ?? "").utf16.count, length: 0), attachments: recovery.attachments))
            cancelQueueEdit.isHidden = false
            recoveryLabel.stringValue = "Editing a queued message. Send saves the edit; Cancel restores your draft."
        case "restore":
            if chat.pendingMessages.stage(id: id) == .preparing || chat.pendingMessages.stage(id: id) == .typing {
                cancelTransport(chat, reason: "Restored for review before submission finished.")
            }
            preserveDraft(chat)
            installDraft(ComposerDraft(text: recovery.text ?? "", selection: NSRange(location: 0, length: 0), attachments: recovery.attachments))
            recoveryLabel.stringValue = "Restored a copy. Check terminal delivery before sending again. Previous draft is saved."
        default: break
        }
        model.save()
    }

    private func editAsNew(chatID: UUID, id: String) {
        guard let chat = model.selectedChat, chat.id == chatID,
              let entry = chat.allEntries.first(where: { $0.id == id && $0.kind == .user }) else { return }
        preserveDraft(chat)
        let attachments = entry.images.filter { $0.hasPrefix("/") }.map { ComposerAttachment(url: URL(fileURLWithPath: $0)) }
        installDraft(ComposerDraft(text: entry.text, selection: NSRange(location: (entry.text as NSString).length, length: 0), attachments: attachments))
        recoveryLabel.stringValue = entry.images.count == attachments.count ? "Editing as a new message. History and files are unchanged." : "Editing as new. Some original images must be reattached."
    }

    private func startPending(_ chat: Chat, id: String, promote: Bool = false) {
        guard let recovery = chat.pendingMessages.recovery(id: id), let terminal = chat.terminal,
              model.chats.contains(where: { $0 === chat }), !chat.codexIdentityWaiting,
              chat.status != .ended, !terminal.processExited,
              !chat.pendingMessages.inputNeedsReview, !preparing.contains(id), !outbox.contains(where: { $0.id == id }) else { return }
        // A queue from a different conversation is recoverable, but never replayed into it.
        guard recovery.sessionID == chat.sessionID else {
            chat.pendingMessages.update(id: id, stage: .failed, detail: "The conversation changed. Restore this message for review before sending.")
            model.save()
            return
        }
        chat.pendingMessages.update(id: id, stage: .preparing)
        preparing.insert(id)
        preparationTargets[id] = (chat.id, chat.sessionID, terminal)
        model.save()
        ComposerAttachmentTransport.prepare(recovery.attachments, agentID: chat.agentID, changed: { [weak self, weak chat] attachments in
            guard let self, let chat, self.preparing.contains(id),
                  chat.pendingMessages.stage(id: id) == .preparing,
                  let target = self.preparationTargets[id], self.model.chats.contains(where: { $0 === chat && $0.id == target.0 }),
                  self.matchesSession(chat, expected: target.1, pendingID: id), chat.terminal === target.2, chat.status != .ended else { return }
            chat.pendingMessages.update(id: id, stage: .preparing, attachments: attachments)
            self.model.save()
        }) { [weak self, weak chat] attachments, result in
            guard let self, let chat, let target = self.preparationTargets[id], self.preparing.remove(id) != nil else { return }
            self.preparationTargets[id] = nil
            guard chat.pendingMessages.stage(id: id) == .preparing else { return }
            guard chat.status != .ended, !terminal.processExited, self.model.chats.contains(where: { $0 === chat && $0.id == target.0 }), self.matchesSession(chat, expected: target.1, pendingID: id), chat.terminal === target.2 else {
                chat.pendingMessages.update(id: id, stage: .failed, detail: "The chat changed during preparation. Restore the saved input to continue.", attachments: attachments)
                self.model.save()
                return
            }
            switch result {
            case .failure(let error):
                chat.pendingMessages.update(id: id, stage: .failed, detail: error.localizedDescription, attachments: attachments)
                if self.shownChatID == chat.id { self.recoveryLabel.stringValue = error.localizedDescription }
            case .success(let files):
                if let error = ComposerAttachmentTransport.failure(for: files) {
                    chat.pendingMessages.update(id: id, stage: .failed, detail: error.localizedDescription, attachments: attachments)
                } else {
                    chat.pendingMessages.prepareTransport(id: id, files: files, attachments: attachments)
                    let steps = ComposerMessage.steps(text: recovery.text, files: files, agentID: chat.agentID)
                    self.type(steps, into: terminal, chatID: chat.id, id: id, queued: true, after: files.map { URL(fileURLWithPath: $0.path) }, promote: promote)
                }
            }
            self.model.save()
        }
    }

    private func promoteSubmitted(chatID: UUID, id: String, until deadline: Date) {
        guard let chat = model.chats.first(where: { $0.id == chatID }), chat.pendingMessages.stage(id: id) == .sent else { return }
        if sendNativeQueue(chat, id: id) { return }
        guard Date() < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.promoteSubmitted(chatID: chatID, id: id, until: deadline) }
    }

    private func updateMentionMenu() {
        let text = composer.textView
        mentionMenu.show(items: text.mentionSuggestions, selection: text.mentionSelection, status: text.mentionStatus)
        mentionMenuHeight?.constant = text.mentionMenuVisible ? CGFloat(max(1, min(6, text.mentionSuggestions.count))) * 38 : 0
        if text.mentionMenuVisible { commandMenu.isHidden = true }
        else { commandMenu.isHidden = !text.commandMenuVisible }
    }

    private func refreshControls(_ chat: Chat) {
        guard let provider = chat.agent.transcript else { agentControls.isHidden = true; return }
        if controlsSession != chat.sessionID || Date().timeIntervalSince(controlsReadAt) > 2 {
            if controlsSession != chat.sessionID { composer.textView.resetPromptRecall(); pendingControl = nil }
            controlsSession = chat.sessionID
            controlsReadAt = Date()
            controlsRecords = []
            if let path = chat.transcriptPath, let file = FileHandle(forReadingAtPath: path) {
                defer { try? file.close() }
                // Keep session metadata and a bounded recent tail, never scan a whole chat on a timer.
                let size = (try? file.seekToEnd()) ?? 0
                try? file.seek(toOffset: 0)
                let header = (try? file.read(upToCount: 8192)) ?? Data()
                controlsRecords += header.split(separator: 10).dropLast().map { Data($0) }
                let offset = size > 262144 ? size - 262144 : 0
                try? file.seek(toOffset: offset)
                let tail = (try? file.read(upToCount: 262144)) ?? Data()
                let lines = tail.split(separator: 10)
                controlsRecords += (offset > 0 ? Array(lines.dropFirst()) : Array(lines)).map { Data($0) }
            }
        }
        let state = ComposerAgentControlsParser.snapshot(provider: provider, sessionID: chat.sessionID, records: controlsRecords, screen: chat.terminal.flatMap { $0.geometryIsStable ? $0.activeScreenText() : nil } ?? "")
        controlsState = state
        agentControls.update(state: state, enabled: composerMode.canSend && !isTyping && !chat.pendingMessages.inputNeedsReview,
                             disabledReason: composerMode.isBlocked ? "Answer the current terminal dialog first." : nil)
    }

    private func requestControl(_ action: ComposerAgentControlAction) {
        guard let chat = model.selectedChat, let provider = chat.agent.transcript else { return }
        refresh()
        if composerMode.isWorking {
            pendingControl = action
            recoveryLabel.stringValue = "\(action.label) will open after this turn."
            return
        }
        guard composerMode == .ready, !isTyping, !chat.pendingMessages.inputNeedsReview else { return }
        if action == .plan, controlsState?.planNeedsTerminal == true { showTerminal(); return }
        let command = action.command(for: provider)
        let id = "control-" + UUID().uuidString
        chat.pendingMessages.enqueue(id: id, text: command, files: [], agentID: chat.agentID, existing: chat.allEntries, stage: .typing, sessionID: chat.sessionID)
        model.save()
        type([.command(command), .pressReturn], into: chat.terminal!, chatID: chat.id, id: id, queued: true)
        // Observe the dialog after it opens. Recognized menus stay in the reader.
        commandSentAt[chat.id] = Date()
    }

    // MARK: Typing into the terminal

    /// Queues a message's steps for a terminal and starts typing if nothing else is. Typing
    /// waits for any of `files` still being converted (PastedImages).
    private func type(_ steps: [SendStep], into t: TerminalView, chatID: UUID, id: String, queued: Bool, after files: [URL] = [], promote: Bool = false) {
        guard !steps.isEmpty else { return }
        if model.chats.first(where: { $0.id == chatID })?.activity != .working { sentThisTurn[chatID] = [] }
        for step in steps {
            switch step {
            case .paste(let text), .command(let text): sentThisTurn[chatID, default: []].append(text)
            case .image: sentThisTurn[chatID, default: []].append("[Image #")
            case .pressReturn: break
            }
        }
        let command = steps.compactMap { step -> String? in
            if case .command(let text) = step { return text }; return nil
        }.first
        outbox.append(Outgoing(id: id, chatID: chatID, tracksPending: queued, terminal: t, steps: steps, files: files, command: command, sessionID: model.chats.first { $0.id == chatID }?.sessionID, promote: promote))
        if !typing { typeNext() }
    }

    private func currentTransport(_ id: String) -> Bool {
        guard let first = outbox.first, first.id == id, first.terminal.surface != nil, !first.terminal.processExited,
              let chat = model.chats.first(where: { $0.id == first.chatID }), chat.status != .ended,
              first.files.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }),
              !chat.pendingMessages.inputNeedsReview, chat.terminal === first.terminal,
              matchesSession(chat, expected: first.sessionID, pendingID: first.tracksPending ? id : nil),
              !first.tracksPending || chat.pendingMessages.stage(id: id) == .typing else { return false }
        if outbox[0].sessionID == nil { outbox[0].sessionID = chat.sessionID }
        return true
    }

    /// Resizing pauses delivery. Session changes and Stop still cancel it immediately.
    private func afterGeometrySettles(_ id: String, perform action: @escaping () -> Void) {
        guard outbox.first?.id == id else { return }
        guard currentTransport(id) else { return failTyping(id, "Session or terminal input state changed. Nothing else was typed.") }
        let first = outbox[0]
        if !first.terminal.geometryIsStable || model.chats.first(where: { $0.id == first.chatID })?.codexIdentityWaiting == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.afterGeometrySettles(id, perform: action)
            }
        } else { action() }
    }

    private func canType(_ id: String) -> Bool {
        guard currentTransport(id), let first = outbox.first, first.terminal.geometryIsStable,
              let chat = model.chats.first(where: { $0.id == first.chatID }), !chat.codexIdentityWaiting else { return false }
        let waits = chat.activity.isNeeds || (statusProvider(chat).map { !$0.waits.isEmpty } ?? false)
        return ReaderSubmissionGuard.refusal(screen: first.terminal.activeScreenText(), waiting: waits, command: first.command) == nil &&
            permitsSubmit(first.terminal) && (!first.tracksPending || chat.pendingMessages.stage(id: id) == .typing)
    }

    private func failTyping(_ id: String, _ reason: String) {
        guard let first = outbox.first, first.id == id else { return }
        if let chat = model.chats.first(where: { $0.id == first.chatID }), first.tracksPending {
            chat.pendingMessages.update(id: id, stage: .failed, detail: reason + (first.typedAny ? " Some input is already in the terminal; inspect it before restoring." : ""))
            model.save()
        }
        outbox.removeFirst()
        if first.typedAny, let chat = model.chats.first(where: { $0.id == first.chatID }) {
            chat.pendingMessages.inputNeedsReview = true
            cancelTransport(chat, reason: "Partial input remains in the terminal. Inspect it before another send.")
        }
        typeNext()
    }

    private func typeNext() {
        guard !outbox.isEmpty else { typing = false; return }
        typing = true
        let id = outbox[0].id
        let chat = model.chats.first { $0.id == outbox[0].chatID }
        if outbox[0].tracksPending, chat?.pendingMessages.stage(id: id) != .typing {
            return failTyping(id, "This input is no longer awaiting submission.")
        }
        guard currentTransport(id) else { return failTyping(id, "Session or terminal input state changed. Nothing else was typed.") }
        if chat?.codexIdentityWaiting == true || !outbox[0].terminal.geometryIsStable {
            afterGeometrySettles(id) { [weak self] in self?.typeNext() }
            return
        }
        guard canType(id) else { return failTyping(id, "Session or terminal input state changed. Nothing else was typed.") }
        guard !outbox[0].steps.isEmpty else { outbox.removeFirst(); return typeNext() }
        let terminal = outbox[0].terminal
        let step = outbox[0].steps.removeFirst()
        let next: (TimeInterval) -> Void = { [weak self] delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.outbox.first?.id == id else { return }
                self.typeNext()
            }
        }
        switch step {
        case .command(let text):
            let firstChatID = outbox[0].chatID
            guard let invocation = ComposerCommandTransport.invocation(text) else { return failTyping(id, "The command could not be prepared.") }
            outbox[0].typedAny = true
            terminal.typeCommandToken("/" + invocation.name + (invocation.arguments.isEmpty ? "" : " "), while: { [weak self] in
                guard let self, self.currentTransport(id) else { return false }
                let verifying = self.model.chats.first(where: { $0.id == firstChatID })?.codexIdentityWaiting == true
                return !terminal.geometryIsStable || verifying || self.canType(id)
            }, pausingWhile: { [weak self] in
                !terminal.geometryIsStable || self?.model.chats.first(where: { $0.id == firstChatID })?.codexIdentityWaiting == true
            }) { [weak self] completed in
                guard let self, self.outbox.first?.id == id else { return }
                guard completed else { return self.failTyping(id, "Command entry was interrupted. Nothing else was typed.") }
                self.afterGeometrySettles(id) { [weak self] in
                    guard let self else { return }
                    guard self.canType(id) else { return self.failTyping(id, "The terminal changed before command arguments were pasted.") }
                    if !invocation.arguments.isEmpty { terminal.pasteText(invocation.arguments) }
                    next(0.2)
                }
            }
        case .paste(let text):
            terminal.pasteText(text)
            outbox[0].typedAny = true
            next(0.15)
        case .image(let path):
            guard outbox[0].files.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) else { return failTyping(id, "An attachment is no longer readable.") }
            let before = ComposerMessage.imageMarks(terminal.activeScreenText())
            terminal.pasteText(path)
            observeImageTransport?(path, false, terminal.activeScreenText())
            outbox[0].typedAny = true
            let deadline = Date().addingTimeInterval(imageWait)
            func check() {
                guard self.outbox.first?.id == id else { return }
                guard self.currentTransport(id) else { return self.failTyping(id, "The terminal changed while attaching the image.") }
                if !terminal.geometryIsStable { self.afterGeometrySettles(id) { check() }; return }
                guard self.canType(id) else { return self.failTyping(id, "The terminal changed while attaching the image.") }
                if ComposerMessage.imageMarks(terminal.activeScreenText()) > before {
                    self.observeImageTransport?(path, true, terminal.activeScreenText())
                    return next(0.1)
                }
                if Date() >= deadline { return self.failTyping(id, "The agent did not confirm the image attachment. The message was not submitted.") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
            }
            check()
        case .pressReturn:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let first = self.outbox.first, first.id == id else { return }
                self.afterGeometrySettles(id) { [weak self] in
                    guard let self, let first = self.outbox.first, first.id == id else { return }
                    guard self.canType(id) else { return self.failTyping(id, "A menu or session change prevented submission.") }
                    if let chat = self.model.chats.first(where: { $0.id == first.chatID }), first.tracksPending {
                        // Persist before the irreversible Return so a crash never permits replay.
                        chat.pendingMessages.markSubmitted(id: id, existing: chat.allEntries)
                        self.model.save()
                    }
                    self.submittedAt[first.chatID] = Date()
                    self.inputRestoration[first.chatID] = ReaderInputRestoration(terminal: ObjectIdentifier(terminal), sessionID: self.model.chats.first(where: { $0.id == first.chatID })?.sessionID, pendingID: id)
                    self.queueReadySince[first.chatID] = nil
                    terminal.pressReturn()
                    if let command = first.command { self.didSendCommand(command, terminal: terminal) }
                    self.outbox.removeFirst()
                    self.typeNext()
                    if first.promote { self.promoteSubmitted(chatID: first.chatID, id: id, until: Date().addingTimeInterval(3)) }
                }
            }
        }
    }

    /// True while a message is still being typed into a terminal.
    var isTyping: Bool { typing || !preparing.isEmpty }

    func hasPanelFeedbackTransport(id: String) -> Bool { preparing.contains(id) || outbox.contains { $0.id == id } }

    private func didSendCommand(_ text: String, terminal: TerminalView) {
        guard let chat = model.chats.first(where: { $0.terminal === terminal }),
              let invocation = ComposerCommandTransport.invocation(text) else { return }
        if let name = ComposerCommandTransport.invocation(text)?.name,
           ["cd", "model", "login", "logout", "plugin", "plugins", "reload-plugins", "reload-skills", "config", "experimental", "restart", "resume", "clear"].contains(name) {
            observedMenus[chat.id] = nil
            commandLoadAt = .distantPast
        }
        commandSentAt[chat.id] = Date()
        let commands = ReaderCommandCatalog.builtins(agent: chat.agent.id)
        let opens = commands.first { $0.name == invocation.name }?.opensTerminal(arguments: invocation.arguments) ?? false
        if opens, model.selectedChat?.id == chat.id, mode.showsReader(chat) {
            // Give the CLI time to draw a complete menu before deciding on fallback.
            commandSentAt[chat.id] = Date()
        }
    }

    /// The page carries both identities so a delayed click cannot target another chat.
    @discardableResult
    func sendNow(chatID: UUID, id: String) -> Bool {
        guard let chat = model.selectedChat, chat.id == chatID, chat.id == shownChatID,
              mode.showsReader(chat) else { return false }
        refresh()
        if chat.pendingMessages.stage(id: id) == .waiting {
            guard composerMode.canSend, !isTyping, editingQueueID == nil,
                  !chat.pendingMessages.inputNeedsReview else { return false }
            let working = composerMode.isWorking || chat.terminal.map { TerminalScreen.analyze($0.activeScreenText()).busy } == true || statusProvider(chat)?.turnActive == true
            startPending(chat, id: id, promote: working)
            return true
        }
        return sendNativeQueue(chat, id: id)
    }

    /// A promotion already requested by the user finishes against its original terminal.
    private func sendNativeQueue(_ chat: Chat, id: String) -> Bool {
        guard let terminal = chat.terminal, terminal.surface != nil, terminal.geometryIsStable, isLive(chat),
              !chat.codexIdentityWaiting, !chat.pendingMessages.inputNeedsReview, !isTyping,
              !outbox.contains(where: { $0.chatID == chat.id }),
              let action = QueuedSendNow.action(agentID: chat.agent.id) else { return false }
        let screen = terminal.activeScreenText()
        let waiting = chat.activity.isNeeds || (statusProvider(chat).map { !$0.waits.isEmpty } ?? false)
        guard chat.activity == .working, QueuedSendNow.available(agentID: chat.agent.id, screen: screen),
              ReaderSubmissionGuard.refusal(screen: screen, waiting: waiting, command: nil) == nil,
              permitsSubmit(terminal) else { return false }
        chat.pendingMessages.sendNowEnabled = true
        guard chat.pendingMessages.entries.contains(where: { $0.id == id && $0.sendNowLabel != nil }),
              chat.pendingMessages.requestDelivery(id: id) else { return false }
        model.save()
        terminal.pressKeys(action.keys)
        return true
    }

    private func sendFirstQueuedNow() -> Bool {
        guard let chat = model.selectedChat,
              let entry = chat.pendingMessages.entries.first(where: {
                  $0.sendNowLabel != nil || (chat.agentID == "claude" && chat.pendingMessages.stage(id: $0.id) == .waiting)
              }) else { return false }
        return sendNow(chatID: chat.id, id: entry.id)
    }

    /// Shift-Tab from the composer reaches the queue actions without making ordinary clicks
    /// on the transcript steal the keyboard from the message box.
    private func focusQueue() -> Bool {
        guard let chat = model.selectedChat, mode.showsReader(chat),
              chat.pendingMessages.entries.contains(where: { $0.sendNowLabel != nil || !($0.pendingActions ?? []).isEmpty }),
              let web = reader?.page.webView as? FocuslessWebView, let window = web.window else { return false }
        web.allowsQueueFocus = true
        window.makeFirstResponder(web)
        web.evaluateJavaScript("window.hantuu.focusQueue()") { [weak self] result, _ in
            if result as? Bool != true { self?.focusComposer() }
        }
        return true
    }

    /// Esc in the agent's terminal, which stops the running turn. Only while it's working, so
    /// it can never decline a prompt on your behalf.
    @discardableResult
    func stop() -> Bool {
        guard composerMode.isWorking, let chat = model.selectedChat, let t = chat.terminal else { return false }
        cancelTransport(chat, reason: "Stopped. The CLI may retain or deliver submitted input; queued work is held.")
        t.pressEscape()
        stoppedAt[chat.id] = Date()
        Log.write("reader mode: stop (Esc) chat=\(chat.id)")
        return true
    }

    /// A stopped agent can restore input without a transcript entry. Preserve that text and
    /// require inspection when the screen contains input reader mode sent this turn.
    private func clearRestoredInput(_ chat: Chat) {
        guard let terminal = chat.terminal else { return }
        let screen = terminal.activeScreenText()
        guard chat.pendingMessages.isRestored(in: screen) ||
                ComposerMessage.restoredLength(screen: screen, sent: sentThisTurn[chat.id] ?? []) > 0 else { return }
        chat.pendingMessages.inputNeedsReview = true
        cancelTransport(chat, reason: "The terminal restored input after interruption. Review it before sending again.")
    }

    private func cancelTransport(_ chat: Chat, reason: String) {
        if outbox.contains(where: { $0.chatID == chat.id && $0.typedAny }) { chat.pendingMessages.inputNeedsReview = true }
        chat.pendingMessages.hold(reason: reason)
        let ids = preparationTargets.filter { $0.value.0 == chat.id }.map(\.key)
        for id in ids { preparing.remove(id); preparationTargets[id] = nil }
        let active = outbox.first?.chatID == chat.id
        outbox.removeAll { $0.chatID == chat.id }
        if active { typeNext() }
        model.save()
    }

    private func clearMirroredMenu() {
        menuOperation = nil
        mirroredMenu = nil
        menuNotice = nil
        menuCard.update(menu: nil)
    }

    private func menuOwner(_ chat: Chat, terminal: TerminalView, session: String?) -> Bool {
        model.selectedChatID == chat.id && shownChatID == chat.id && chat.sessionID == session &&
            chat.terminal === terminal && terminal.surface != nil && isLive(chat) &&
            mode.showsReader(chat) && root.window != nil && !root.isHiddenOrHasHiddenAncestor && model.subagentBrowser.selection == nil &&
            !chat.codexIdentityWaiting && !isTyping && menuProbe == nil &&
            reader?.interaction.hasPendingRequest != true
    }

    /// Test probes use the same entry point as the card. Only a fresh, exact label is acted on.
    @discardableResult
    func chooseMenuOption(label: String, confirm: Bool = true, sessionOnly: Bool = false) -> Bool {
        reader?.interaction.refresh()
        guard menuOperation == nil, menuNotice == nil, let chat = model.selectedChat,
              let terminal = chat.terminal, terminal.geometryIsStable, let menu = mirroredMenu, menu.actionable,
              menu.options.contains(where: { $0.label == label }),
              menuOwner(chat, terminal: terminal, session: chat.sessionID) else { return false }
        if sessionOnly && !menu.allowsSessionConfirm { return false }
        let actual = ReaderMenuParser.parse(terminal.activeScreenText(), agent: chat.agent.id)
        guard actual == menu else { failMenu("The menu changed before the click. Use Show Terminal."); return false }
        let token = UUID(), session = chat.sessionID
        menuOperation = token
        var selection = ReaderMenuSelection(menu: menu, label: label, confirm: confirm, sessionOnly: sessionOnly)
        let deadline = Date().addingTimeInterval(8)
        func step() {
            guard self.menuOperation == token else { return }
            self.reader?.interaction.refresh()
            guard self.menuOwner(chat, terminal: terminal, session: session) else {
                self.failMenu("The session or input owner changed. No further keys were sent."); return
            }
            guard Date() < deadline else {
                self.failMenu("The menu action expired. No further key was sent. Use Show Terminal."); return
            }
            if !terminal.geometryIsStable {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { step() }; return
            }
            let raw = terminal.activeScreenText()
            let next = ReaderMenuParser.parse(raw, agent: chat.agent.id)
            let state = TerminalScreen.analyze(raw)
            let closed = next == nil && state.menu == nil && (state.ready || state.busy)
            switch selection.observe(next, closed: closed) {
            case .done:
                self.menuOperation = nil
                self.menuNotice = nil
                self.refresh()
                return
            case .refuse(let reason): self.failMenu(reason); return
            case .key(let key): self.pressMenuKey(key, terminal: terminal)
            case .wait: break
            }
            guard Date() < deadline else {
                self.failMenu("The terminal did not confirm the change. No key was retried. Use Show Terminal."); return
            }
            self.menuCard.update(menu: next ?? menu, busy: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { step() }
        }
        step()
        return true
    }

    /// A free-text reply is pasted only into an observed input field. Its exact echo is
    /// required on two reads before Return. Existing terminal text is never erased blindly.
    @discardableResult
    func submitMenuText(_ text: String) -> Bool {
        reader?.interaction.refresh()
        guard menuOperation == nil, menuNotice == nil, let menu = mirroredMenu, menu.actionable,
              let chat = model.selectedChat, let terminal = chat.terminal, terminal.geometryIsStable,
              menuOwner(chat, terminal: terminal, session: chat.sessionID),
              ReaderMenuParser.parse(terminal.activeScreenText(), agent: chat.agent.id) == menu else { return false }
        guard let suffix = ReaderMenuTextSubmission.suffix(for: text, menu: menu) else {
            failMenu("This answer cannot be entered safely from the reader. Use Show Terminal to edit it.")
            return false
        }
        let token = UUID(), session = chat.sessionID
        menuOperation = token
        if !suffix.isEmpty { terminal.pasteText(suffix) }
        let deadline = Date().addingTimeInterval(8)
        var submission = ReaderMenuTextSubmission(menu: menu, text: text)
        func observe() {
            guard self.menuOperation == token else { return }
            self.reader?.interaction.refresh()
            guard self.menuOwner(chat, terminal: terminal, session: session), Date() < deadline else {
                self.failMenu("The answer could not be confirmed. Input may remain in the terminal. Use Show Terminal."); return
            }
            if !terminal.geometryIsStable {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { observe() }; return
            }
            let raw = terminal.activeScreenText()
            let current = ReaderMenuParser.parse(raw, agent: chat.agent.id)
            let state = TerminalScreen.analyze(raw)
            let closed = current == nil && state.menu == nil && (state.ready || state.busy)
            switch submission.observe(current, closed: closed) {
            case .done: self.menuOperation = nil; self.refresh(); return
            case .refuse(let reason): self.failMenu(reason); return
            case .key(let key): self.pressMenuKey(key, terminal: terminal)
            case .wait: break
            }
            self.menuCard.update(menu: current ?? menu, busy: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { observe() }
        }
        menuCard.update(menu: menu, busy: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { observe() }
        return true
    }

    /// Navigation forwards one known key and waits for a visible change. It never presses
    /// Enter on a later page or retries a key whose effect could not be established.
    @discardableResult
    func sendMenuKey(_ key: ReaderMenuKey) -> Bool {
        reader?.interaction.refresh()
        guard let menu = mirroredMenu, menu.actionable else { return false }
        if key == .enter || key == .space {
            guard let label = menu.selected else { return false }
            return chooseMenuOption(label: label)
        }
        if key == .up || key == .down {
            guard let label = menu.selected, let index = menu.options.firstIndex(where: { $0.label == label }) else { return false }
            let next = index + (key == .down ? 1 : -1)
            guard menu.options.indices.contains(next) else { return true }
            return chooseMenuOption(label: menu.options[next].label, confirm: false)
        }
        let noteKey = key == .notes && menu.agent == "codex" && menu.kind == .question && menu.footer.lowercased().contains("tab to add notes")
        guard key == .escape || ((key == .left || key == .right) && menu.allowsHorizontal) || (key == .tab && menu.allowsTab) || noteKey,
              menuOperation == nil, menuNotice == nil, let chat = model.selectedChat, let terminal = chat.terminal, terminal.geometryIsStable,
              menuOwner(chat, terminal: terminal, session: chat.sessionID),
              ReaderMenuParser.parse(terminal.activeScreenText(), agent: chat.agent.id) == menu else { return false }
        let token = UUID(), session = chat.sessionID
        let before = terminal.activeScreenText()
        guard ReaderMenuParser.parse(before, agent: chat.agent.id) == menu else { return false }
        menuOperation = token
        let nativeKey: ReaderMenuKey = key == .tab && menu.agent == "codex" && menu.kind == .question && menu.allowsHorizontal ? .right : key
        pressMenuKey(nativeKey, terminal: terminal)
        let deadline = Date().addingTimeInterval(3)
        func observe() {
            guard self.menuOperation == token else { return }
            guard self.menuOwner(chat, terminal: terminal, session: session) else { self.failMenu("The input owner changed. Use Show Terminal."); return }
            guard Date() < deadline else { self.failMenu("The menu action expired. Use Show Terminal."); return }
            if !terminal.geometryIsStable {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { observe() }; return
            }
            let raw = terminal.activeScreenText(), state = TerminalScreen.analyze(raw)
            let next = ReaderMenuParser.parse(raw, agent: chat.agent.id)
            if raw != before, next != nil || state.menu == nil && (state.ready || state.busy) {
                self.menuOperation = nil; self.refresh(); return
            }
            if Date() >= deadline { self.failMenu("The terminal did not confirm the change. Use Show Terminal."); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { observe() }
        }
        menuCard.update(menu: menu, busy: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { observe() }
        return true
    }

    private func failMenu(_ reason: String) {
        menuOperation = nil
        menuNotice = reason
        menuCard.update(menu: mirroredMenu, notice: reason)
    }

    private func pressMenuKey(_ key: ReaderMenuKey, terminal: TerminalView) {
        let stroke: TerminalKeyStroke
        switch key {
        case .up: stroke = TerminalKeyStroke(keyCode: 126, codepoint: 0)
        case .down: stroke = TerminalKeyStroke(keyCode: 125, codepoint: 0)
        case .left: stroke = TerminalKeyStroke(keyCode: 123, codepoint: 0)
        case .right: stroke = TerminalKeyStroke(keyCode: 124, codepoint: 0)
        case .tab, .notes: stroke = TerminalKeyStroke(keyCode: 48, codepoint: 9)
        case .escape: stroke = TerminalKeyStroke(keyCode: 53, codepoint: 27)
        case .enter: stroke = TerminalKeyStroke(keyCode: 36, codepoint: 13)
        case .space: stroke = TerminalKeyStroke(keyCode: 49, codepoint: 32)
        case .session: terminal.typeCommandText("s"); return
        }
        terminal.pressKeys([stroke])
    }

    private func handleMenuKey(_ event: NSEvent) -> Bool {
        guard mirroredMenu != nil, !root.isHidden, root.window === event.window,
              reader?.interaction.findOpen != true,
              let responder = event.window?.firstResponder as? NSView,
              responder === composer.textView || responder.isDescendant(of: menuCard),
              !composer.textView.hasMarkedText(),
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        if event.isARepeat && ([UInt16(36), 76, 49, 53].contains(event.keyCode) || Int(event.characters ?? "") != nil) { return true }
        if let button = responder as? NSButton, [UInt16(36), 76, 49].contains(event.keyCode) {
            if button.isEnabled { button.performClick(nil) }
            return true
        }
        let key: ReaderMenuKey?
        switch event.keyCode {
        case 126: key = .up
        case 125: key = .down
        case 123: key = .left
        case 124: key = .right
        case 48: key = .tab
        case 53: key = .escape
        case 36, 76: key = .enter
        case 49: key = .space
        default: key = nil
        }
        if let key { _ = sendMenuKey(key); return true }
        if let text = event.characters, let digit = Int(text),
           let option = mirroredMenu?.options.first(where: { $0.number == digit }) {
            _ = chooseMenuOption(label: option.label); return true
        }
        return false
    }

    /// Shows the live terminal so a menu can be answered there.
    func showTerminal() {
        clearMirroredMenu()
        cancelMenuProbe()
        guard let chat = model.selectedChat, isLive(chat) else { return }
        calmChecks = 0
        mode.peek(chat)
        if let t = chat.terminal { model.focusRequest.send(t) }
    }

    func backToReader() {
        guard let chat = model.selectedChat else { return }
        commandPeekAt[chat.id] = nil
        commandSentAt[chat.id] = nil
        finishPeek(chat)
    }

    private func finishPeek(_ chat: Chat) {
        mode.endPeek(chat)
        if let t = chat.terminal { model.focusRequest.send(t) }
        // The face change schedules layout through Combine. Focus again after that layout,
        // when the message box's ancestors are visible and AppKit can accept the responder.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.selectedChat?.id == chat.id, self.mode.showsReader(chat) else { return }
            self.focusComposer()
        }
    }

    /// Where the keyboard goes when something asks for the selected chat's terminal: the
    /// message box while the reader is up, so keys never reach the hidden terminal. Nil means
    /// nothing in the main area should have it (an ended chat in the reader).
    func focusTarget(for view: NSView) -> NSView? {
        guard let chat = model.selectedChat, view === chat.terminal, mode.showsReader(chat) else { return view }
        return composerMode == .none ? nil : composer.textView
    }

    func focusComposer() {
        (reader?.page.webView as? FocuslessWebView)?.allowsQueueFocus = false
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

    /// Browser feedback only prepares input. Reuse the image pacing queue without its
    /// Return step, and keep the selected chat fixed while the images are being pasted.
    @discardableResult
    func insertBrowserFeedback(_ feedback: BrowserFeedback, chatID: UUID) -> Bool {
        guard let chat = model.selectedChat, chat.id == chatID,
              model.subagentBrowser.selection == nil, !isTyping else { return false }
        cancelMenuProbe()
        let inReader = mode.showsReader(chat)
        if inReader {
            guard composerMode != .none else { return false }
        } else {
            guard let terminal = chat.terminal, terminal.surface != nil,
                  TerminalScreen.analyze(terminal.activeScreenText()).menu == nil else { return false }
        }
        feedback.compose(reader: inReader, agentID: chat.agent.id, addToReader: { attachments, text in
            self.composer.setAttachments(self.composer.attachments + attachments)
            let separator = self.composer.textView.string.isEmpty ? "" : "\n\n"
            self.composer.textView.setSelectedRange(NSRange(location: (self.composer.textView.string as NSString).length, length: 0))
            self.composer.textView.insertTyped(separator + text)
            self.textChanged()
            self.focusComposer()
        }, pasteToTerminal: { steps in
            guard let terminal = chat.terminal else { return }
            // Browser feedback is a draft in the agent's box, never a queued send.
            self.type(steps, into: terminal, chatID: chat.id, id: UUID().uuidString, queued: false, after: feedback.image.map { [$0] } ?? [])
            self.model.focusRequest.send(terminal)
        })
        return true
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

/// Reader mode keeps ordinary typing in the message box. Queued message actions, search,
/// disclosures and live request controls can take keyboard focus explicitly and hand it
/// back to the composer. Text can still be selected; Copy with nothing selected in the box
/// copies it. The shared HantuuWebView stays as it was, so the panel's pages behave as before.
final class FocuslessWebView: HantuuWebView {
    var onMouseDown: (() -> Void)?
    /// Files and pictures dropped on the page. Returns false to leave the drop to the page.
    var onDropAttachments: ((ComposerPasteboard.Content) -> Bool)?
    var allowsInteraction = false
    /// Send now's keyboard traversal uses the same switch.
    var allowsQueueFocus: Bool {
        get { allowsInteraction }
        set { allowsInteraction = newValue }
    }
    override var acceptsFirstResponder: Bool { allowsInteraction }
    override func becomeFirstResponder() -> Bool { allowsInteraction && super.becomeFirstResponder() }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onMouseDown?()
    }

    private func takesDrop(_ info: NSDraggingInfo) -> Bool {
        onDropAttachments != nil && ComposerPasteboard.dropHasAttachment(info.draggingPasteboard)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        takesDrop(sender) ? .copy : super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        takesDrop(sender) ? .copy : super.draggingUpdated(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard takesDrop(sender), let take = onDropAttachments else { return super.performDragOperation(sender) }
        return ComposerPasteboard.receiveDrop(sender) { content in _ = take(content) }
    }
}
