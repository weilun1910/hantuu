import AppKit
import Combine
import SwiftUI

final class ThinSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 1 }
    override var dividerColor: NSColor { Theme.divider }
}

/// NSSplitViewController must stay its split view's delegate (assigning another one throws),
/// so resize notifications come through this override.
final class RootSplitController: NSSplitViewController {
    var onResize: (() -> Void)?
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        onResize?()
    }
}

/// One window: sidebar | chat terminal | right panel. Solid neutral fills throughout (no
/// translucent sidebar material), the titlebar hidden and the traffic lights over the sidebar.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let model: AppModel
    let split = RootSplitController()
    private(set) var sidebarItem: NSSplitViewItem!
    private(set) var mainItem: NSSplitViewItem!
    private(set) var panelItem: NSSplitViewItem!
    let mainArea: MainAreaController
    let panel: PanelController
    private var bag = Set<AnyCancellable>()
    private var syncingCollapse = false
    /// Setting up the content resizes the window before the saved frame is restored. Saving
    /// during that would overwrite the saved frame, so saving waits until it's restored.
    private var frameRestored = false

    init(model: AppModel) {
        self.model = model
        mainArea = MainAreaController(model: model)
        panel = PanelController(model: model)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "hantuu"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
        w.isMovableByWindowBackground = false
        w.backgroundColor = Theme.background
        w.isRestorable = false
        w.minSize = NSSize(width: 760, height: 460)
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.tabbingMode = .disallowed
        super.init(window: w)
        w.delegate = self

        let sidebarVC = NSHostingController(rootView: AnyView(SidebarView().environmentObject(model).ignoresSafeArea()))
        sidebarVC.sizingOptions = []
        split.splitView = ThinSplitView()
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin

        sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 380
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)

        mainItem = NSSplitViewItem(viewController: mainArea)
        mainItem.minimumThickness = 380
        mainItem.holdingPriority = NSLayoutConstraint.Priority(240)

        panelItem = NSSplitViewItem(viewController: panel)
        panelItem.canCollapse = true
        panelItem.minimumThickness = 360
        panelItem.holdingPriority = NSLayoutConstraint.Priority(255)

        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(mainItem)
        split.addSplitViewItem(panelItem)
        w.contentViewController = split
        split.onResize = { [weak self] in self?.splitDidResize() }

        // Collapsing a pane resizes its neighbours, never the window.
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        panelItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebarItem.isCollapsed = !model.sidebarVisible
        panelItem.isCollapsed = !model.panelVisible
        restoreFrame()

        model.$sidebarVisible.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] v in
            guard let self, self.sidebarItem.isCollapsed == v else { return }
            self.syncingCollapse = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                self.sidebarItem.animator().isCollapsed = !v
            }, completionHandler: { self.syncingCollapse = false })
        }.store(in: &bag)
        model.$panelVisible.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] v in
            guard let self, self.panelItem.isCollapsed == v else { return }
            self.syncingCollapse = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                self.panelItem.animator().isCollapsed = !v
            }, completionHandler: {
                self.syncingCollapse = false
                // A panel that started out hidden can come back at its minimum width.
                if v, self.panelItem.viewController.view.frame.width < Self.minPreferredPanelWidth {
                    self.setPanelWidth(self.preferredPanelWidth())
                }
            })
        }.store(in: &bag)
        model.focusRequest.receive(on: DispatchQueue.main).sink { [weak self] v in
            guard let self, let w = self.window else { return }
            // In reader mode the chat's terminal is hidden and the message box takes its keys.
            DispatchQueue.main.async { w.makeFirstResponder(self.mainArea.readerMode.focusTarget(for: v)) }
        }.store(in: &bag)
    }

    required init?(coder: NSCoder) { fatalError() }

    func restoreFrame() {
        guard let w = window else { return }
        // The descriptor is "x y w h screenX screenY screenW screenH".
        let parts = (model.windowFrame ?? "").split(separator: " ").compactMap { Double($0) }
        if let f = model.windowFrame, parts.count >= 4, parts[2] >= 900, parts[3] >= 500 {
            w.setFrame(from: f)
        } else {
            let screen = w.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let size = NSSize(width: min(1560, screen.width - 80), height: min(900, screen.height - 60))
            w.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: false)
        }
    }

    /// Wide enough for an 80-column terminal and a comfortable reading line.
    static let defaultPanelWidth: CGFloat = 560
    /// Saved widths narrower than this came from the old 300 pt default, so they're replaced.
    static let minPreferredPanelWidth: CGFloat = 420

    func preferredPanelWidth() -> CGFloat {
        var w = CGFloat(model.panelWidth ?? 0)
        if w < Self.minPreferredPanelWidth { w = Self.defaultPanelWidth }
        // Leave the chat its minimum width.
        let sidebar = sidebarItem.isCollapsed ? 0 : sidebarItem.viewController.view.frame.width
        let room = split.splitView.bounds.width - sidebar - mainItem.minimumThickness - 2
        return max(panelItem.minimumThickness, min(w, room))
    }

    private func setPanelWidth(_ width: CGFloat) {
        let sv = split.splitView
        sv.layoutSubtreeIfNeeded()
        sv.setPosition(sv.bounds.width - width - 1, ofDividerAt: 1)
    }

    func applyInitialWidths() {
        restoreFrame()
        let sv = split.splitView
        sv.layoutSubtreeIfNeeded()
        let sidebar = CGFloat(model.sidebarWidth ?? 248)
        if !sidebarItem.isCollapsed { sv.setPosition(sidebar, ofDividerAt: 0) }
        if !panelItem.isCollapsed {
            setPanelWidth(preferredPanelWidth())
        } else {
            // Size the hidden panel now, so showing it later opens at this width.
            syncingCollapse = true
            panelItem.isCollapsed = false
            setPanelWidth(preferredPanelWidth())
            panelItem.isCollapsed = true
            syncingCollapse = false
        }
        frameRestored = true
    }

    // MARK: Split resizing

    private func splitDidResize() {
        guard !syncingCollapse, frameRestored else { return }
        if model.sidebarVisible == sidebarItem.isCollapsed { model.sidebarVisible = !sidebarItem.isCollapsed }
        if model.panelVisible == panelItem.isCollapsed { model.panelVisible = !panelItem.isCollapsed }
        if !sidebarItem.isCollapsed { model.sidebarWidth = Double(sidebarItem.viewController.view.frame.width) }
        if !panelItem.isCollapsed { model.panelWidth = Double(panelItem.viewController.view.frame.width) }
        model.scheduleSave()
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        if let c = model.selectedChat, c.status == .needsYou, let t = c.terminal, t.focused {
            c.status = .running
            model.objectWillChange.send()
        }
    }

    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard frameRestored, let w = window, !w.styleMask.contains(.fullScreen) else { return }
        model.windowFrame = w.frameDescriptor
        model.scheduleSave()
    }
}
