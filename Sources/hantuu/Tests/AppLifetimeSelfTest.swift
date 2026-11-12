import AppKit
import WebKit

extension SelfTest {
    /// Construct owners inside a pool so deferred AppKit releases cannot disguise cycles.
    /// No load(), real provider directories, terminal processes or network pages are used.
    static func appLifetimes(_ dir: URL) {
        let root = dir.appendingPathComponent("app-lifetimes", isDirectory: true)
        Paths.ensure(root)
        let previousDataDir = Paths.dataDir
        Paths.dataDir = root.appendingPathComponent("data", isDirectory: true)
        defer { Paths.dataDir = previousDataDir }

        weak var page: WebPage?
        autoreleasepool {
            let owner = WebPage(page: "reader.html", identifier: "hantuu.lifetime.page")
            page = owner
            withExtendedLifetime(owner) {}
        }
        check("lifetime: WebKit's script handler does not retain its page", waitUntil(3) { page == nil })

        func released(_ name: String, make: (AppModel) -> AnyObject) {
            weak var model: AppModel?
            weak var controller: AnyObject?
            autoreleasepool {
                let app = AppModel()
                app.transcriptLocations = TranscriptLocations(claude: root.appendingPathComponent("claude"),
                                                               codex: root.appendingPathComponent("codex"))
                app.codexProcessID = { _ in nil }
                app.codexOpenRollouts = { _, _ in [] }
                model = app
                let owner = make(app)
                controller = owner
                withExtendedLifetime(owner) {}
            }
            let gone = waitUntil(3) { model == nil && controller == nil }
            check("lifetime: \(name) releases its model", gone,
                  "model released=\(model == nil), controller released=\(controller == nil)")
        }

        released("reader subscriptions") { ReaderController(model: $0) }
        released("file viewer and its banner") { FileViewerController(model: $0) }
        released("side panel") { app in
            SidePanelController(model: app, store: SideChatStore(directory: root.appendingPathComponent("side"), logger: { _ in }),
                                codexRoot: root.appendingPathComponent("codex"))
        }
        released("subagent reader") { SubagentReaderController(model: $0) }
        released("browser coordinator") { BrowserCoordinator(model: $0, review: ReviewCenter(loadSavedState: false)) }
        released("status subscriptions") { app in
            let center = StatusCenter()
            center.notifier = NoticeRecorder()
            center.start(model: app, live: false)
            return center
        }
        released("background watcher with an active timer") { app in
            let watcher = BackgroundWatch()
            watcher.codexRoot = root.appendingPathComponent("codex")
            watcher.start(model: app)
            return watcher
        }
        released("reader mode with an active refresh timer") { app in
            let project = Project(path: root.path)
            let chat = Chat(projectID: project.id, agentID: "claude")
            chat.status = .ended
            app.projects = [project]
            app.chats = [chat]
            app.selectedChatID = chat.id
            let settings = ChatSettings(file: root.appendingPathComponent("chat-settings.json"))
            settings.showChatsAsReader = true
            let owner = ReaderModeController(model: app, mode: ReaderMode(settings: settings))
            owner.statusProvider = { _ in nil }
            owner.sync(selected: chat)
            return owner
        }

        for agent in LiveCheckRules.agents {
            weak var model: AppModel?
            weak var chat: Chat?
            var timer: Timer?
            autoreleasepool {
                let app = AppModel()
                app.transcriptLocations = TranscriptLocations(claude: root.appendingPathComponent("claude"),
                                                               codex: root.appendingPathComponent("codex"))
                app.codexProcessID = { _ in nil }
                app.codexOpenRollouts = { _, _ in [] }
                let item = Chat(projectID: UUID(), agentID: agent)
                item.sessionID = "fixture-session"
                app.chats = [item]
                app.beginTranscriptDiscovery(item, cwd: root.path)
                model = app
                chat = item
                timer = item.discoveryTimer
            }
            check("lifetime: \(agent) recovery releases model and chat and invalidates its timer",
                  waitUntil(3) { model == nil && chat == nil && timer?.isValid == false })
        }
    }
}
