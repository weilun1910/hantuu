import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?
    let model = AppModel.shared
    var windowController: MainWindowController!
    private var settingsWindow: NSWindow?
    private var agentsMenu: NSMenu?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensure(Paths.dataDir)
        Log.write("launch data=\(Paths.dataDir.path)")
        guard let ghostty = GhosttyApp.start() else {
            let a = NSAlert()
            a.messageText = "hantuu couldn't start the Ghostty terminal engine"
            a.informativeText = "libghostty failed to initialise. See \(Paths.logFile.path)."
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        Theme.configure(from: ghostty)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // An ad hoc app that's rebuilt in place can keep a stale generic icon in the Dock,
        // because macOS cached the bundle before it had one. Setting it here always wins.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        model.load()
        buildMenu()
        windowController = MainWindowController(model: model)
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { self.windowController.applyInitialWidths() }
        if ProcessInfo.processInfo.environment["HANTUU_DEBUG_LAYOUT"] == "1", let w = windowController.window {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Log.write("layout frame=\(w.frame) fitting=\(w.contentView?.fittingSize ?? .zero)")
                for c in w.contentView?.constraintsAffectingLayout(for: .horizontal) ?? [] { Log.write("  h \(c.priority.rawValue) \(c)") }
                for c in w.contentView?.constraintsAffectingLayout(for: .vertical) ?? [] { Log.write("  v \(c.priority.rawValue) \(c)") }
            }
        }
        NSApp.activate()

        // Test launches can open a project and start a chat straight away.
        let args = CommandLine.arguments
        Log.write("args \(args.dropFirst())")
        if let i = args.firstIndex(of: "--open-project"), i + 1 < args.count {
            model.addProject(path: args[i + 1])
        }
        if let i = args.firstIndex(of: "--new-chat"), i + 1 < args.count {
            let agent = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.model.newChat(agentID: agent, projectID: nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Agents run in hantuu-session, so by default quitting leaves them running and they
        // reattach next launch. Asking first only matters when quitting is set to stop them.
        let keepRunning = SessionSettings.shared.keepAgentsRunning
        let running = model.chats.filter { $0.status != .ended && $0.terminal != nil && !($0.terminal?.processExited ?? true) }
        if !keepRunning && !running.isEmpty {
            let a = NSAlert()
            a.messageText = "Quit hantuu?"
            a.informativeText = "\(running.count) agent\(running.count == 1 ? " is" : "s are") still running. Quitting stops \(running.count == 1 ? "it" : "them"). You can resume Claude Code and Codex chats next time."
            a.addButton(withTitle: "Quit")
            a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        if !keepRunning { model.stopAllSessions() }
        model.save()
        return .terminateNow
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let c = model.selectedChat, c.status == .needsYou, c.terminal?.focused == true {
            c.status = .running
            model.objectWillChange.send()
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "hantuu")
        appMenu.addItem(withTitle: "About hantuu", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(showSettings), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide hantuu", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit hantuu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(item("New Chat", #selector(newChat), "n"))
        let withItem = NSMenuItem(title: "New Chat With", action: nil, keyEquivalent: "")
        let agents = NSMenu(title: "New Chat With")
        agents.delegate = self
        agentsMenu = agents
        withItem.submenu = agents
        file.addItem(withItem)
        file.addItem(SessionMenuTarget.newChatInWorktreeItem())
        file.addItem(item("New Terminal Tab", #selector(newTerminal), "t"))
        file.addItem(.separator())
        file.addItem(item("Open File…", #selector(openFile), "o"))
        file.addItem(item("Add Project…", #selector(addProject), "o", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Close", #selector(closeFocused), "w"))
        fileItem.submenu = file
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(item("Toggle Sidebar", #selector(toggleSidebar), "0"))
        view.addItem(item("Toggle Panel", #selector(togglePanel), "0", [.command, .option]))
        view.addItem(.separator())
        view.addItem(item("Terminal", #selector(showTerminalTab), "1", [.command, .option]))
        view.addItem(item("Code", #selector(showCodeTab), "2", [.command, .option]))
        view.addItem(item("Reader", #selector(showReaderTab), "3", [.command, .option]))
        view.addItem(.separator())
        let fs = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = view
        main.addItem(viewItem)

        let chatItem = NSMenuItem()
        let chat = NSMenu(title: "Chat")
        for i in 1...9 {
            let it = item("Chat \(i)", #selector(goToChat(_:)), "\(i)")
            it.tag = i - 1
            chat.addItem(it)
        }
        chat.addItem(.separator())
        chat.addItem(item("Resume Chat", #selector(resumeChat), "r", [.command, .shift]))
        chatItem.submenu = chat
        main.addItem(chatItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = self
        return it
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === agentsMenu else { return }
        menu.removeAllItems()
        for a in model.agents {
            let it = NSMenuItem(title: a.name + (a.id == model.defaultAgentID ? "  (default)" : ""), action: #selector(newChatWith(_:)), keyEquivalent: "")
            it.representedObject = a.id
            it.target = self
            menu.addItem(it)
        }
        if model.agents.isEmpty { menu.addItem(withTitle: model.agentsLoaded ? "No agents found" : "Looking for agents…", action: nil, keyEquivalent: "") }
    }

    @objc func newChat() { model.newChat(agentID: nil, projectID: nil) }
    @objc func newChatWith(_ sender: NSMenuItem) { model.newChat(agentID: sender.representedObject as? String, projectID: nil) }
    @objc func newTerminal() { model.newTerminalTab() }
    @objc func addProject() { model.addProjectWithPanel() }
    @objc func openFile() { model.openFileWithPanel() }
    @objc func closeFocused() {
        if let w = NSApp.keyWindow, w !== windowController.window {
            w.performClose(nil)
            return
        }
        model.closeFocused(responder: windowController.window?.firstResponder)
    }
    @objc func toggleSidebar() { model.sidebarVisible.toggle() }
    @objc func togglePanel() { model.panelVisible.toggle() }
    @objc func showTerminalTab() { showPanel(.terminal) }
    @objc func showCodeTab() { showPanel(.code) }
    @objc func showReaderTab() { showPanel(.reader) }
    @objc func goToChat(_ sender: NSMenuItem) { model.selectChat(index: sender.tag) }
    @objc func resumeChat() { if let c = model.selectedChat, c.status == .ended { model.resume(c) } }

    private func showPanel(_ tab: PanelTab) {
        if model.panelVisible && model.panelTab == tab {
            model.panelVisible = false
        } else {
            model.panelTab = tab
            model.panelVisible = true
        }
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Settings"
            w.isReleasedWhenClosed = false
            w.isRestorable = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = NSHostingView(rootView: SettingsView().environmentObject(model))
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Default agent", selection: $model.defaultAgentID) {
                    ForEach(model.agents) { a in Text(a.name).tag(a.id) }
                    if model.agents.isEmpty { Text(model.defaultAgentID).tag(model.defaultAgentID) }
                }
                LabeledContent("Installed") {
                    VStack(alignment: .trailing, spacing: 3) {
                        if model.agents.isEmpty {
                            Text(model.agentsLoaded ? "None found in your login shell" : "Looking…").foregroundStyle(.secondary)
                        }
                        ForEach(model.agents) { a in
                            Text("\(a.name)  \(a.path ?? "")").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Button("Look Again") { model.detectAgents() }
            } header: { Text("Agents") } footer: {
                Text("hantuu finds agents through your login shell, so they run with the same PATH and environment as in Ghostty. It never adds permission-skipping flags.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            SessionSettingsSection()
            Section("Terminal") {
                LabeledContent("Config") {
                    Text("~/Library/Application Support/com.mitchellh.ghostty/config.ghostty").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Text("Fonts, colours and padding come from your Ghostty config. hantuu only reads it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Reload Ghostty Config") { GhosttyApp.shared?.reloadConfig() }
            }
            Section("Data") {
                LabeledContent("Folder") {
                    Text(Paths.dataDir.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 420)
    }
}
