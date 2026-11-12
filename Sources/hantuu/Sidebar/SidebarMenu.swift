import AppKit

final class SidebarMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = SidebarMenuTarget()
    private var model: AppModel { AppModel.shared }
    private var keyMonitor: Any?

    static func install(chat: NSMenu, view: NSMenu) {
        if shared.keyMonitor == nil {
            shared.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
                guard event.keyCode == 48, flags == .control || flags == [.control, .shift],
                      let window = AppDelegate.shared?.windowController?.window,
                      event.window === window, window.attachedSheet == nil else { return event }
                shared.model.previousNextChat(flags.contains(.shift) ? -1 : 1)
                return nil
            }
        }
        func item(_ name: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
            let item = NSMenuItem(title: name, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = shared
            return item
        }
        chat.addItem(.separator())
        chat.addItem(item("Switch Chat...", #selector(switchChat), "k", [.command]))
        chat.addItem(item("Search All History...", #selector(history), "k", [.command, .shift]))
        chat.addItem(item("Previous Chat", #selector(previous), "\t", [.control, .shift]))
        chat.addItem(item("Next Chat", #selector(next), "\t", [.control]))
        chat.addItem(item("Back", #selector(back), "[", [.command]))
        chat.addItem(item("Forward", #selector(forward), "]", [.command]))
        chat.addItem(.separator())
        chat.addItem(item("Rename Chat...", #selector(rename), "r", [.command, .option]))
        chat.addItem(item("Mark Unread", #selector(unread), "u", [.command, .shift]))
        chat.addItem(item("Mark Read", #selector(read), "", []))
        chat.addItem(item("Archive Chat", #selector(archive), "a", [.command, .shift]))
        chat.addItem(item("Reopen Last Closed Chat", #selector(reopen), "t", [.command, .option, .shift]))
        chat.addItem(item("Archived Chats...", #selector(archives), "", []))
        view.addItem(item("Focus Sidebar", #selector(focusSidebar), "s", [.command, .control]))
    }

    @objc func switchChat() { show(.active) }
    @objc func history() { show(.all) }
    @objc func archives() { show(.archived) }
    private func show(_ scope: ChatHistoryScope) {
        model.sidebarVisible = true
        model.historyScope = scope
        model.historyPresented = true
    }
    @objc func previous() { model.previousNextChat(-1) }
    @objc func next() { model.previousNextChat(1) }
    @objc func back() { model.navigateHistory(-1) }
    @objc func forward() { model.navigateHistory(1) }
    @objc func rename() {
        guard let chat = model.selectedChat else { return }
        model.sidebarVisible = true
        model.revealChat(chat)
        model.renamingChatID = chat.id
    }
    @objc func unread() { if let chat = model.selectedChat { StatusCenter.shared.setRead(chat: chat, read: false) } }
    @objc func read() { if let chat = model.selectedChat { StatusCenter.shared.setRead(chat: chat, read: true) } }
    @objc func archive() { if let chat = model.selectedChat { model.archiveChat(chat) } }
    @objc func reopen() { model.reopenLastChat() }
    @objc func focusSidebar() { model.focusSidebar() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(rename), #selector(unread), #selector(read), #selector(archive):
            return model.selectedChat != nil && model.subagentBrowser.selection == nil && model.selectedChat?.launchPhase.isBusy == false
        case #selector(reopen): return !model.archivedChats.isEmpty
        case #selector(previous), #selector(next): return !model.sidebarOrder.isEmpty
        default: return true
        }
    }
}
