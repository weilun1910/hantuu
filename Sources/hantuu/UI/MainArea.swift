import AppKit
import Combine
import SwiftUI

/// A solid-colour NSView.
class FillView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    private var themeObserver: NSObjectProtocol?
    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        // Theme's colours are dynamic, so AppKit redraws this when the appearance changes.
        // A reloaded Ghostty config can change them without that, hence the notification.
        themeObserver = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = color.cgColor }
}

/// Holds terminal views. All of them stay alive (and their agents keep running); only the
/// selected one is visible. A bottom inset leaves room for the "ended" bar.
final class TerminalContainer: FillView {
    var bottomInset: CGFloat = 0 { didSet { needsLayout = true } }
    override func layout() {
        super.layout()
        for v in subviews where v is TerminalView {
            v.frame = NSRect(x: 0, y: bottomInset, width: bounds.width, height: max(0, bounds.height - bottomInset))
        }
    }
    func show(_ terminals: [TerminalView], visible: TerminalView?) {
        for t in terminals where t.superview !== self {
            addSubview(t, positioned: .below, relativeTo: nil)
        }
        for v in subviews.compactMap({ $0 as? TerminalView }) where !terminals.contains(where: { $0 === v }) {
            v.removeFromSuperview()
        }
        for t in terminals { t.setVisible(t === visible) }
        needsLayout = true
    }
}

final class MainAreaController: NSViewController {
    private let model: AppModel
    private let container = TerminalContainer(color: Theme.background)
    private var header: NSView!
    private var endedBar: NSView!
    private var emptyView: NSView!
    /// Reader mode: the chat as the reader with a message box, over its terminal (ReaderMode/).
    private(set) lazy var readerMode = ReaderModeController(model: model)
    private var subagentReader: SubagentReaderController?
    private var bag = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = FillView(color: Theme.background)
        header = ChromeHostingView(rootView: ChatHeader().environmentObject(model))
        endedBar = ChromeHostingView(rootView: EndedBar().environmentObject(model))
        emptyView = ChromeHostingView(rootView: EmptyStateView().environmentObject(model))
        for v in [header!, container, endedBar!, emptyView!] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
            container.topAnchor.constraint(equalTo: header.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            endedBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            endedBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            endedBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            endedBar.heightAnchor.constraint(equalToConstant: 38),
            emptyView.topAnchor.constraint(equalTo: header.bottomAnchor),
            emptyView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        readerMode.install(in: root, top: header.bottomAnchor, above: container)
        readerMode.onLayoutChange = { [weak self] in self?.sync() }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.terminalsChanged.sink { [weak self] in self?.sync() }.store(in: &bag)
        model.$selectedChatID.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.sync() }.store(in: &bag)
        model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.sync() }.store(in: &bag)
        sync()
    }

    /// Requests aimed at a hidden parent terminal go to the subagent reader instead.
    func focusTarget(for requested: NSView) -> NSView? {
        if model.subagentBrowser.selection != nil, model.chats.contains(where: { $0.terminal === requested }) {
            return subagentReader?.reader.view
        }
        return readerMode.focusTarget(for: requested)
    }

    func sync() {
        let terminals = model.chats.compactMap { $0.terminal }
        let selected = model.selectedChat
        let browsingSubagent = model.subagentBrowser.selection != nil && selected != nil
        let face = readerMode.sync(selected: browsingSubagent ? nil : selected)
        if browsingSubagent, subagentReader == nil {
            let reader = SubagentReaderController(model: model)
            reader.install(in: view, top: header.bottomAnchor)
            subagentReader = reader
        }
        subagentReader?.sync()
        container.show(terminals, visible: face.showsReader || browsingSubagent ? nil : selected?.terminal)
        let ended = selected?.status == .ended
        endedBar.isHidden = !ended
        container.bottomInset = ended || face.peeking ? 38 : 0
        emptyView.isHidden = selected != nil && selected?.terminal != nil
        if browsingSubagent {
            endedBar.isHidden = true
            emptyView.isHidden = true
        } else if let s = selected, s.terminal == nil {
            // An earlier chat restored from disk: nothing running yet.
            emptyView.isHidden = true
            endedBar.isHidden = false
        }
    }
}

struct ChatHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: 10) {
                if !model.sidebarVisible {
                    Spacer().frame(width: 66)
                    IconButton(symbol: "sidebar.left", help: "Show Sidebar  ⌘0") { model.sidebarVisible = true }
                }
                if let selected = model.subagentBrowser.selection, let chat = model.selectedChat {
                    IconButton(symbol: "chevron.left", help: "Back to parent chat  ⌘[") { _ = model.backFromSubagent() }
                    Text(selected.agent.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.hText).lineLimit(1)
                    Button { _ = model.backFromSubagent() } label: {
                        Text("Subagent of \(chat.displayTitle)").font(.system(size: 12)).foregroundStyle(Color.hSecondary).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                } else if let chat = model.selectedChat {
                    ChatTitle(chat: chat)
                } else {
                    Text("hantuu").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.hSecondary)
                }
                Spacer()
                // Switches the chat between its terminal and the reader (Shift-Cmd-R).
                if model.subagentBrowser.selection == nil { ChatFaceButtons() }
                IconButton(symbol: "sidebar.right", help: model.panelVisible ? "Hide Panel  ⌥⌘0" : "Show Panel  ⌥⌘0", active: model.panelVisible) {
                    model.panelVisible.toggle()
                }
            }
            .padding(.horizontal, 12)
        }
        .background(Color.hBackground)
    }
}

struct ChatTitle: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var chat: Chat

    var body: some View {
        HStack(spacing: 8) {
            ActivityDot(activity: chat.activity)
            Text(chat.displayTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.hText)
                .lineLimit(1)
            if let p = model.project(chat.projectID) {
                Text(p.name).font(.system(size: 12)).foregroundStyle(Color.hTertiary).lineLimit(1)
            }
            WorktreeBranchLabel(chat: chat).font(.system(size: 12)).foregroundStyle(Color.hTertiary)
            Text(chat.agent.name).font(.system(size: 12)).foregroundStyle(Color.hTertiary).lineLimit(1)
        }
        .allowsHitTesting(false)
    }
}

struct EndedBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let chat = model.selectedChat {
            HStack(spacing: 14) {
                Text(message(chat))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.hSecondary)
                Spacer()
                Button(chat.sessionID != nil && chat.agent.resumeArguments(sessionID: "x") != nil ? "Resume" : "Start Again") { model.resume(chat) }
                    .buttonStyle(BarButtonStyle(prominent: true))
                Button(chat.terminal == nil ? "Remove" : "Close") { model.closeChat(chat) }
                    .buttonStyle(BarButtonStyle(prominent: false))
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.hChrome)
            .overlay(Rectangle().fill(Color.hDivider).frame(height: 1), alignment: .top)
        }
    }

    func message(_ chat: Chat) -> String {
        if chat.terminal == nil { return "\(chat.agent.name) chat from an earlier session" }
        if let code = chat.exitCode, code != 0 { return "\(chat.agent.name) exited with code \(code)" }
        return "\(chat.agent.name) exited"
    }
}

struct BarButtonStyle: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .medium : .regular))
            .foregroundStyle(prominent ? Color.hText : Color.hSecondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.hInk(configuration.isPressed ? 0.12 : (prominent ? 0.08 : 0.0))))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.hDivider, lineWidth: prominent ? 0 : 1))
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Text("hantuu")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.hSecondary)
            if model.projects.isEmpty {
                Text("Create a project from a folder, then start a chat in it.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.hTertiary)
                Button("New Project…") { model.addProjectWithPanel() }
                    .buttonStyle(BarButtonStyle(prominent: true))
            } else {
                VStack(spacing: 8) {
                    shortcut("New chat", "⌘N") { model.newChat(agentID: nil, projectID: nil) }
                    shortcut("New terminal", "⌘T") { model.newTerminalTab() }
                    shortcut("New project", "⇧⌘O") { model.addProjectWithPanel() }
                }
                if let p = model.currentProject {
                    Text("in \(p.name), with \(model.agents.first(where: { $0.id == model.defaultAgentID })?.name ?? model.defaultAgentID)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.hTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.hBackground)
    }

    func shortcut(_ title: String, _ keys: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(Color.hText)
                Spacer()
                Text(keys).foregroundStyle(Color.hTertiary)
            }
            .font(.system(size: 13))
            .frame(width: 200)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
