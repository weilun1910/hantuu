import AppKit
import Combine
import SwiftUI

final class ThinSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 1 }
    override var dividerColor: NSColor { Theme.divider }
}

/// One window: sidebar | chat terminal | right panel. Solid neutral fills throughout (no
/// translucent sidebar material), the titlebar hidden and the traffic lights over the sidebar.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate {
    let model: AppModel
    let split = NSSplitViewController()
    private(set) var sidebarItem: NSSplitViewItem!
    private(set) var mainItem: NSSplitViewItem!
    private(set) var panelItem: NSSplitViewItem!
    let mainArea: MainAreaController
    let panel: PanelController
    private var bag = Set<AnyCancellable>()
    private var syncingCollapse = false

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
        w.appearance = NSAppearance(named: .darkAqua)
        w.isRestorable = false
        w.minSize = NSSize(width: 760, height: 460)
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.tabbingMode = .disallowed
        super.init(window: w)
        w.delegate = self

        let sidebarVC = NSHostingController(rootView: SidebarView().environmentObject(model))
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
        panelItem.minimumThickness = 300
        panelItem.holdingPriority = NSLayoutConstraint.Priority(255)

        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(mainItem)
        split.addSplitViewItem(panelItem)
        w.contentViewController = split
        split.splitView.delegate = self

        if let f = model.windowFrame { w.setFrame(from: f) } else { w.setContentSize(NSSize(width: 1320, height: 820)); w.center() }
        sidebarItem.isCollapsed = !model.sidebarVisible
        panelItem.isCollapsed = !model.panelVisible

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
            }, completionHandler: { self.syncingCollapse = false })
        }.store(in: &bag)
        model.focusRequest.receive(on: DispatchQueue.main).sink { [weak self] v in
            guard let w = self?.window else { return }
            DispatchQueue.main.async { w.makeFirstResponder(v) }
        }.store(in: &bag)
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyInitialWidths() {
        let sv = split.splitView
        sv.layoutSubtreeIfNeeded()
        let sidebar = CGFloat(model.sidebarWidth ?? 248)
        let panelW = CGFloat(model.panelWidth ?? 460)
        if !sidebarItem.isCollapsed { sv.setPosition(sidebar, ofDividerAt: 0) }
        if !panelItem.isCollapsed { sv.setPosition(sv.bounds.width - panelW - 1, ofDividerAt: 1) }
    }

    // MARK: NSSplitViewDelegate

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !syncingCollapse else { return }
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
        guard let w = window, !w.styleMask.contains(.fullScreen) else { return }
        model.windowFrame = w.frameDescriptor
        model.scheduleSave()
    }
}
