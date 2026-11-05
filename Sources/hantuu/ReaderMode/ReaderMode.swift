import AppKit
import Combine
import SwiftUI

/// Reader mode: the main area shows the chat as the reader with a message box, while the
/// agent keeps running in its real terminal underneath. This decides which face each chat
/// shows, and keeps the short "peeks" at the terminal when the agent waits on a menu there.
final class ReaderMode: ObservableObject {
    static let shared = ReaderMode(settings: .shared)

    let settings: ChatSettings
    /// Chats showing their terminal for a moment, to answer a menu. They go back to the reader
    /// once nothing waits there any more.
    @Published private(set) var peeking: Set<UUID> = []
    private var bag = Set<AnyCancellable>()

    init(settings: ChatSettings) {
        self.settings = settings
        settings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
    }

    func face(of chat: Chat) -> ChatFace { settings.face(for: chat) }
    func isPeeking(_ chat: Chat) -> Bool { peeking.contains(chat.id) }
    /// The reader is what the main area shows for this chat right now.
    func showsReader(_ chat: Chat) -> Bool { face(of: chat) == .reader && !isPeeking(chat) }

    func toggle(_ chat: Chat) {
        peeking.remove(chat.id)
        settings.toggle(chat)
    }

    func peek(_ chat: Chat) { peeking.insert(chat.id) }
    func endPeek(_ chat: Chat) { peeking.remove(chat.id) }

    /// The panel's Reader tab repeats the main area when the selected chat's face is the
    /// reader, so it's hidden then.
    func hidesPanelReader(selected: Chat?) -> Bool {
        guard let selected else { return false }
        return face(of: selected) == .reader
    }
}

// MARK: Header button and menu item

/// The icon in the chat header that flips the selected chat between the reader and its
/// terminal. In terminal mode it also keeps the button for the panel's Reader tab.
struct ChatFaceButtons: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var mode = ReaderMode.shared

    var body: some View {
        if let chat = model.selectedChat {
            let reader = mode.face(of: chat) == .reader
            if !reader {
                IconButton(symbol: "text.book.closed", help: "Reader in the Panel  ⌥⌘6", active: model.panelVisible && model.panelTab == .reader) {
                    if model.panelVisible && model.panelTab == .reader { model.panelVisible = false } else {
                        model.panelTab = .reader
                        model.panelVisible = true
                    }
                }
            }
            IconButton(symbol: reader ? "terminal" : "text.alignleft",
                       help: reader ? "Show Terminal  ⌥⌘R" : "Show as Reader  ⌥⌘R") {
                ReaderModeMenuTarget.shared.toggle(model: model)
            }
        }
    }
}

/// View > Show Terminal / Show as Reader (Option-Cmd-R) and the Reader tab item's state.
final class ReaderModeMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = ReaderModeMenuTarget()

    static func toggleItem() -> NSMenuItem {
        let it = NSMenuItem(title: "Show as Reader", action: #selector(toggleFace(_:)), keyEquivalent: "r")
        it.keyEquivalentModifierMask = [.command, .option]
        it.target = shared
        return it
    }

    @objc func toggleFace(_ sender: Any?) { toggle(model: AppModel.shared) }

    func toggle(model: AppModel, mode: ReaderMode = .shared) {
        guard let chat = model.selectedChat else { return }
        mode.toggle(chat)
        // Whichever face is up now gets the keyboard (the redirect in MainArea picks the
        // message box for the reader).
        if let t = chat.terminal { model.focusRequest.send(t) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let chat = AppModel.shared.selectedChat else {
            item.title = "Show as Reader"
            return false
        }
        item.title = ReaderMode.shared.face(of: chat) == .reader ? "Show Terminal" : "Show as Reader"
        return true
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Only the panel's Reader tab item is ever disabled: while the reader is the main area.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(showPanelTab(_:)), item.representedObject as? String == PanelTab.reader.rawValue {
            return !ReaderMode.shared.hidesPanelReader(selected: model.selectedChat)
        }
        return true
    }
}

// MARK: The working line, the asked line and the banner

final class ReaderModeStatusModel: ObservableObject {
    @Published var mode: ComposerMode = .none
    @Published var chat: Chat?
    var stop: () -> Void = {}
    var showTerminal: () -> Void = {}
    var agentName: String { chat?.agent.name ?? "The agent" }

    /// Height the status area needs above the message box.
    static func height(for mode: ComposerMode) -> CGFloat {
        switch mode {
        case .none, .ready: return 0
        case .starting, .working, .asked: return 26
        case .blocked: return 74
        }
    }
}

struct ReaderModeStatus: View {
    @ObservedObject var state: ReaderModeStatusModel

    var body: some View {
        Group {
            switch state.mode {
            case .none, .ready:
                Color.clear
            case .starting:
                line {
                    ActivityDot(activity: .idle)
                    Text("Waiting for \(state.agentName) to start").foregroundStyle(Color.hTertiary)
                    Spacer(minLength: 8)
                }
            case .working(let detail):
                line {
                    ActivityDot(activity: .working)
                    Text(detail).foregroundStyle(Color.hSecondary).lineLimit(1).truncationMode(.tail).help(detail)
                    if let chat = state.chat { Elapsed(since: chat.activitySince) }
                    Spacer(minLength: 8)
                    Button("Stop") { state.stop() }
                        .buttonStyle(BarButtonStyle(prominent: false))
                        .help("Stop \(state.agentName) (sends Esc)  esc")
                }
            case .asked(let question):
                line {
                    ActivityDot(activity: .needsAnswer)
                    Text("Asks: \(question)").foregroundStyle(Color.hSecondary).lineLimit(1).truncationMode(.tail).help(question)
                    Spacer(minLength: 8)
                    Text("Reply below").foregroundStyle(Color.hTertiary)
                }
            case .blocked(let title, let detail):
                NeedsBanner(title: title, detail: detail, agentName: state.agentName, showTerminal: state.showTerminal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func line<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) { content() }
            .font(.system(size: 12))
            .padding(.horizontal, 4)
            .frame(height: 26)
    }
}

/// "for 12s" next to the working detail.
struct Elapsed: View {
    let since: Date
    var now: Date? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(Self.text(since: since, now: now ?? ctx.date))
                .monospacedDigit()
                .foregroundStyle(Color.hTertiary)
        }
    }

    static func text(since: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

/// Above the message box when a menu waits in the terminal.
struct NeedsBanner: View {
    let title: String
    let detail: String
    let agentName: String
    let showTerminal: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Rectangle().fill(Color(nsColor: Theme.needsYou)).frame(width: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.needsYou))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.hText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(detail)
                Text("Answer it in the terminal. The reader comes back once \(agentName) carries on.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.hTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Show Terminal") { showTerminal() }
                .buttonStyle(BarButtonStyle(prominent: true))
        }
        .padding(.vertical, 10)
        .padding(.trailing, 12)
        .frame(height: 66)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// At the bottom of the main area while a chat shows its terminal to answer a menu.
struct PeekBar: View {
    @EnvironmentObject var model: AppModel
    let back: () -> Void

    var body: some View {
        if let chat = model.selectedChat {
            HStack(spacing: 14) {
                Circle().fill(Color(nsColor: Theme.needsYou)).frame(width: 6, height: 6)
                Text("Answer \(chat.agent.name) here. The reader comes back once it carries on.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.hSecondary)
                    .lineLimit(1)
                Spacer()
                Button("Back to Reader") { back() }
                    .buttonStyle(BarButtonStyle(prominent: true))
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.hChrome)
            .overlay(Rectangle().fill(Color.hDivider).frame(height: 1), alignment: .top)
        }
    }
}
