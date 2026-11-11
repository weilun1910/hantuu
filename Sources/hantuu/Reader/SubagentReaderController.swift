import AppKit
import SwiftUI

/// A read-only reader over the parent's terminal. Only the selected child is followed.
final class SubagentReaderController {
    let root = FillView(color: Theme.background)
    let reader: ReaderController
    private let model: AppModel
    private var follower: TranscriptFollower?
    private var identity: String?
    private var path: String?
    private var monitor: Any?

    init(model: AppModel) {
        self.model = model
        reader = ReaderController(model: model, page: "reader.html?layout=main", identifier: "hantuu.subagent-reader", observesSelection: false)
        let status = ChromeHostingView(rootView: SubagentReaderStatus().environmentObject(model))
        for view in [reader.view, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            reader.view.topAnchor.constraint(equalTo: root.topAnchor),
            reader.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            reader.view.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 34),
        ])
        root.isHidden = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    deinit {
        follower?.stop()
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func install(in parent: NSView, top: NSLayoutYAxisAnchor) {
        root.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: top),
            root.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    func sync() {
        guard let selected = model.subagentBrowser.selection, let chat = model.selectedChat,
              selected.chatID == chat.id else {
            root.isHidden = true
            follower?.stop()
            follower = nil
            if identity != nil {
                reader.showTranscript(id: "", entries: [], base: nil, emptyText: "")
            }
            identity = nil
            path = nil
            reader.mediaKeys.update(expanded: 0)
            return
        }
        let nextID = chat.id.uuidString + ":" + selected.agent.id
        let changed = identity != nextID || path != selected.agent.transcript
        root.isHidden = false
        if changed {
            follower?.stop()
            follower = nil
            identity = nextID
            path = selected.agent.transcript
            reader.mediaKeys.update(expanded: 0)
            let base = model.workingDirectory(of: chat)
            reader.showTranscript(id: nextID, entries: [], base: base, emptyText: "Waiting for this subagent's transcript.")
            if let path, let kind = chat.agent.transcript {
                let tail = TranscriptFollower(url: URL(fileURLWithPath: path), kind: kind, baseDir: base, scope: .subagent)
                tail.onAppend = { [weak self, weak tail] entries in
                    guard let self, let tail, self.follower === tail else { return }
                    self.reader.appendTranscript(entries)
                }
                tail.onReset = { [weak self, weak tail] in
                    guard let self, let tail, self.follower === tail else { return }
                    self.reader.showTranscript(id: nextID, entries: [], base: base, emptyText: "Nothing to show yet.")
                }
                follower = tail
                tail.start()
            }
            // The hidden parent terminal must never retain the keyboard.
            root.window?.makeFirstResponder(reader.page.webView)
        }
        if let terminal = root.window?.firstResponder as? TerminalView,
           model.chats.contains(where: { $0.terminal === terminal }) {
            root.window?.makeFirstResponder(reader.page.webView)
        }
        // Keep following a finished selection until navigation, so its final writes arrive.
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard !root.isHiddenOrHasHiddenAncestor, model.subagentBrowser.selection != nil,
              let window = root.window, event.window === window else { return event }
        if let view = window.firstResponder as? NSView, view is TerminalView || view.hantuuIsInCodeViewer { return event }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let back = flags == .command && event.charactersIgnoringModifiers == "["
        let escape = flags.isEmpty && event.keyCode == 53
        guard back || escape else { return event }
        if escape, reader.mediaKeys.handle(event) == nil { return nil }
        _ = model.backFromSubagent()
        return nil
    }
}

private struct SubagentReaderStatus: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if let selected = model.subagentBrowser.selection {
                ActivityDot(activity: selected.agent.activity)
                Text(selected.agent.detail).font(.system(size: 12)).foregroundStyle(Color.hSecondary).lineLimit(1)
                Spacer()
                Text("Read-only").font(.system(size: 11)).foregroundStyle(Color.hTertiary)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.hBackground)
        .overlay(Rectangle().fill(Color.hDivider).frame(height: 1), alignment: .top)
    }
}
