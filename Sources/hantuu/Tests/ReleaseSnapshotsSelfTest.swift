import AppKit
import SwiftUI

extension SelfTest {
    /// Release images use the real reader and composer with fixture transcripts and a shell
    /// that only records input. Command discovery stays inside a scratch home and project.
    static func releaseSnapshots(_ dir: URL) {
        guard Paths.dataDir.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path + "/") else {
            check("release snapshots: settings stay in the self test folder", false)
            return
        }
        guard let ghostty = GhosttyApp.shared ?? GhosttyApp.start() else {
            check("release snapshots: libghostty starts", false)
            return
        }
        let root = dir.appendingPathComponent("release-snapshots", isDirectory: true)
        Paths.ensure(root)
        let out = snapshotsFolder(root)
        Paths.ensure(out)
        let previousPhase = ActivityDot.fixedPhase
        let previousReaderDefault = ChatSettings.shared.showChatsAsReader
        ActivityDot.fixedPhase = 0.45
        // The header uses the shared setting, which the self test stores in its data folder.
        ChatSettings.shared.showChatsAsReader = true
        defer {
            ActivityDot.fixedPhase = previousPhase
            ChatSettings.shared.showChatsAsReader = previousReaderDefault
        }
        for agent in ["claude", "codex"] {
            releaseReaderSnapshots(root.appendingPathComponent(agent), out: out, agent: agent, ghostty: ghostty)
        }
    }

    private static func releaseReaderSnapshots(_ dir: URL, out: URL, agent: String, ghostty: GhosttyApp) {
        let home = dir.appendingPathComponent("home", isDirectory: true)
        let folder = dir.appendingPathComponent("Demo", isDirectory: true)
        Paths.ensure(home)
        Paths.ensure(folder)
        let skill = folder.appendingPathComponent(agent == "claude"
            ? ".claude/skills/check-layout/SKILL.md" : ".agents/skills/check-layout/SKILL.md")
        Paths.ensure(skill.deletingLastPathComponent())
        try? "---\nname: check-layout\ndescription: Check spacing and alignment\n---\nReview the layout.\n"
            .write(to: skill, atomically: true, encoding: .utf8)

        let model = AppModel()
        let project = Project(path: folder.path)
        model.projects = [project]
        let chat = Chat(projectID: project.id, agentID: agent)
        chat.terminalTitle = "Review the layout"
        let transcript = dir.appendingPathComponent("conversation.jsonl")
        let question = "Can you check the settings layout?"
        let answer = "The controls line up well. I'll check the spacing between sections and how the labels fit in a narrower window."
        let lines: [[String: Any]]
        if agent == "claude" {
            lines = [
                ["type": "user", "uuid": "question", "message": ["role": "user", "content": question]],
                ["type": "assistant", "uuid": "answer", "message": ["role": "assistant", "content": [["type": "text", "text": answer]]]],
            ]
        } else {
            lines = [
                ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": question]]]],
                ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": answer]]]],
            ]
        }
        let json = lines.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
            .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
        try? json.write(to: transcript, atomically: true, encoding: .utf8)
        let follower = TranscriptFollower(url: transcript, kind: agent == "claude" ? .claude : .codex, baseDir: folder.path)
        follower.poll()
        chat.follower = follower
        chat.transcriptPath = transcript.path
        let sent = dir.appendingPathComponent("sent.bin")
        let terminal = recordingTerminal(ghostty, dir: folder, file: sent)
        chat.terminal = terminal
        model.chats = [chat]
        model.selectedChatID = chat.id
        let settings = ChatSettings(file: dir.appendingPathComponent("chat-settings.json"))
        settings.showChatsAsReader = true
        let mode = ReaderMode(settings: settings)
        let controller = ReaderModeController(model: model, mode: mode, commandCatalog: ReaderCommandCatalog(home: home))
        controller.commandDiscoveryEnabled = false
        controller.statusProvider = { _ in nil }

        let view = FillView(color: Theme.background)
        let header = ChromeHostingView(rootView: ChatHeader().environmentObject(model))
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminal)
        view.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
        ])
        let previousMain = ReaderModeController.main
        controller.install(in: view, top: header.bottomAnchor, above: terminal)
        let window = NSWindow(contentRect: NSRect(x: -7000, y: -4000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        terminal.frame = NSRect(x: 0, y: 0, width: 800, height: 560)
        window.orderFrontRegardless()
        defer {
            controller.sync(selected: nil)
            ReaderModeController.main = previousMain
            follower.stop()
            terminal.destroy()
            window.orderOut(nil)
        }
        controller.sync(selected: chat)
        guard let page = controller.reader?.page,
              waitUntil(10, { page.ready && controller.composerMode == .ready }) else {
            check("release snapshots: \(agent) reader becomes ready", false)
            return
        }
        check("release snapshots: \(agent) fixture transcript renders", waitUntil(5) {
            (js(page, "document.querySelectorAll('section.entry').length") as? Int) == 2
        })
        window.makeFirstResponder(controller.composer.textView)

        func snapshot(_ name: String) {
            for dark in [false, true] {
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let color = dark ? "rgb(227, 227, 227)" : "rgb(43, 43, 43)"
                check("release snapshots: \(name) uses \(dark ? "dark" : "light") colours", waitUntil(5) {
                    (js(page, "getComputedStyle(document.body).color") as? String) == color
                })
                // Rebuild the attributed menu rows under the new drawing appearance.
                window.appearance?.performAsCurrentDrawingAppearance {
                    controller.commandMenu.show([], selection: 0)
                    controller.composer.textView.updateCommands()
                    controller.composer.updateColors()
                }
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                let filename = name + (dark ? "-dark" : "") + ".png"
                check("release snapshots: \(filename)", render(view, to: out.appendingPathComponent(filename), overlays: [controller.commandMenu]))
            }
        }

        let text = controller.composer.textView
        text.insertTyped(agent == "claude" ? "/ch" : "/")
        check("release snapshots: \(agent) command menu includes fixture skills", waitUntil(5) {
            text.commandCatalog.contains { $0.name == "check-layout" }
                && text.commandMenuVisible && !controller.commandMenu.isHidden
        })
        if agent == "claude" {
            check("release snapshots: Claude shows built-ins beside a project skill",
                  text.commandSuggestions.prefix(6).contains { $0.name == "check-layout" && $0.source == "project skill" }
                  && text.commandSuggestions.prefix(6).contains { $0.name == "chrome" && $0.source == "CLI fallback" })
        } else {
            check("release snapshots: Codex slash menu keeps dollar skills separate",
                  text.commandSuggestions.allSatisfy { $0.sigil == "/" }
                  && text.commandCatalog.contains { $0.token == "$check-layout" })
        }
        snapshot("slash-menu-\(agent)")
        text.text = ""
        text.setSelectedRange(NSRange(location: 0, length: 0))

        // The app retains queued input while the fixture chat is working. Once it becomes
        // idle, the real composer transport sends the message to the recording shell.
        if agent == "claude" {
            chat.activity = .working
            chat.activityDetail = "Checking the settings layout"
            chat.activitySince = Date()
            controller.refresh()
            let followUp = "Please check the narrow window too."
            text.text = followUp
            check("release snapshots: a working chat accepts a queued send", controller.send(intent: .queue))
            check("release snapshots: Queued is visible under a working agent", waitUntil(5) {
                controller.composerMode.isWorking
                    && (js(page, "(() => { const label = document.querySelector('.queued-label'); return label?.textContent === 'Queued' && getComputedStyle(label).display !== 'none' && document.querySelectorAll('.entry.pending').length === 1; })()") as? Bool) == true
            })
            snapshot("reader-queued")
            check("release snapshots: a queued message leaves the recording shell untouched while busy",
                  (try? Data(contentsOf: sent)) == Data())
            chat.activity = .idle
            controller.refresh()
            let expected = Data("\u{1b}[200~\(followUp)\u{1b}[201~\r".utf8)
            check("release snapshots: the queued message reaches the recording shell after the chat goes idle", waitUntil(6) {
                (try? Data(contentsOf: sent)) == expected && !controller.isTyping
            })
        }
    }
}
