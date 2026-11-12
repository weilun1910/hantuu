import AppKit
import Combine
import SwiftUI

final class ThinSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 1 }
    override var dividerColor: NSColor { Theme.divider }
    var onDividerDrag: ((Bool) -> Void)?
    var onPanelDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let panelEdge = subviews.count == 3 ? subviews[2].frame.minX : -100
        if event.clickCount == 2, abs(point.x - panelEdge) <= 6 {
            onPanelDoubleClick?()
            return
        }
        onDividerDrag?(true)
        super.mouseDown(with: event)
        onDividerDrag?(false)
    }
}

/// NSSplitViewController must stay its split view's delegate (assigning another one throws),
/// so resize notifications come through this override.
final class RootSplitController: NSSplitViewController {
    var onResize: (() -> Void)?
    var constrainPosition: ((CGFloat, Int) -> CGFloat)?
    override func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
                            ofSubviewAt dividerIndex: Int) -> CGFloat {
        constrainPosition?(proposedPosition, dividerIndex) ?? proposedPosition
    }
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
    private var dragging = false
    private var dragStartWidths: [CGFloat] = []
    private var navigationPopover: NSPopover?
    private var focusPanel = false
    private var panelVisibleBeforeFocus = true
    private var showPanelWhenSingle = true
    private var autoHidden = false
    private var lastPanelVisible = false
    private var lastDocumentID: UUID?
    private weak var splitResponder: NSResponder?
    private(set) var effectiveLayout = WindowLayout.Result(sidebar: 0, chat: 0, panel: 0)
    /// Setting up the content resizes the window before the saved frame is restored. Saving
    /// during that would overwrite the saved frame, so saving waits until it's restored.
    private var frameRestored = false
    private var paneFloors: [NSLayoutConstraint] = []
    private var windowMinimumWidth: NSLayoutConstraint!

    init(model: AppModel, readerMode: ReaderMode = .shared, review: ReviewCenter = .shared, window suppliedWindow: NSWindow? = nil) {
        self.model = model
        mainArea = MainAreaController(model: model, mode: readerMode)
        panel = PanelController(model: model, review: review)
        let w = suppliedWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
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
        sidebarItem.minimumThickness = 0
        sidebarItem.maximumThickness = 380
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)

        mainItem = NSSplitViewItem(viewController: mainArea)
        mainItem.canCollapse = true
        mainItem.minimumThickness = 0
        mainItem.holdingPriority = NSLayoutConstraint.Priority(240)

        panelItem = NSSplitViewItem(viewController: panel)
        panelItem.canCollapse = true
        panelItem.minimumThickness = 0
        panelItem.holdingPriority = NSLayoutConstraint.Priority(255)

        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(mainItem)
        split.addSplitViewItem(panelItem)
        w.contentViewController = split
        // Pane floors yield to the window's 500-priority size stay, but outrank native
        // divider dragging at 490. Required expanded minima would clamp the window before
        // the policy could collapse a pane.
        for (view, floor) in [(sidebarVC.view, CGFloat(200)), (mainArea.view, WindowLayout.readerMinimum), (panel.view, CGFloat(360))] {
            let constraint = view.widthAnchor.constraint(greaterThanOrEqualToConstant: floor)
            constraint.priority = NSLayoutConstraint.Priority(499)
            paneFloors.append(constraint)
        }
        windowMinimumWidth = split.view.widthAnchor.constraint(greaterThanOrEqualToConstant: WindowLayout.readerMinimum)
        NSLayoutConstraint.activate([windowMinimumWidth!, split.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 460)])
        split.onResize = { [weak self] in self?.splitDidResize() }
        mainItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        (split.splitView as? ThinSplitView)?.onDividerDrag = { [weak self] active in
            guard let self else { return }
            if active {
                self.dragStartWidths = self.split.splitView.subviews.map { $0.frame.width }
            }
            self.dragging = active
            if !active {
                let widths = self.split.splitView.subviews.map { $0.frame.width }
                let changed = zip(widths, self.dragStartWidths).contains { abs($0.0 - $0.1) > 0.5 }
                if changed { self.rememberDraggedWidths() }
                self.applyLayout()
            }
        }
        (split.splitView as? ThinSplitView)?.onPanelDoubleClick = { [weak self] in self?.togglePanelFocus() }
        split.constrainPosition = { [weak self] proposed, index in
            guard let self, self.dragging, index == 1, !self.focusPanel else { return proposed }
            let start = self.mainArea.view.frame.minX
            let width = WindowLayout.detent(proposed - start, targets: self.chatTargets,
                                           bypass: NSEvent.modifierFlags.contains(.option))
            let floor = self.readerIsVisible ? WindowLayout.readerMinimum : self.terminalMinimum
            return min(max(start + floor, start + width), self.split.splitView.bounds.width - WindowLayout.panelMinimum(for: self.model.panelTab) - 1)
        }
        mainArea.onFaceLayoutChange = { [weak self] in self?.applyLayout() }

        // Collapsing a pane resizes its neighbours, never the window.
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        panelItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebarItem.isCollapsed = !model.sidebarVisible
        panelItem.isCollapsed = !model.panelVisible
        restoreFrame()

        model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.applyLayout()
        }.store(in: &bag)
        model.layoutState.requests.sink { [weak self] request in
            self?.handleLayoutRequest(request)
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: TerminalView.geometryDidChange)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.applyLayout() }.store(in: &bag)
        model.focusRequest.receive(on: DispatchQueue.main).sink { [weak self] v in
            guard let self, let w = self.window else { return }
            if self.effectiveLayout.single { self.showPanelWhenSingle = false; self.applyLayout() }
            // The visible reader takes keys intended for a hidden chat terminal.
            DispatchQueue.main.async { w.makeFirstResponder(self.mainArea.focusTarget(for: v)) }
        }.store(in: &bag)
    }

    required init?(coder: NSCoder) { fatalError() }

    func restoreFrame() {
        guard let w = window else { return }
        // The descriptor is "x y w h screenX screenY screenW screenH".
        let parts = (model.windowFrame ?? "").split(separator: " ").compactMap { Double($0) }
        if let f = model.windowFrame, parts.count >= 4, parts.prefix(4).allSatisfy(\.isFinite), parts[2] >= Double(WindowLayout.readerMinimum), parts[3] >= 460 {
            w.setFrame(from: f)
            if let screen = w.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                var frame = w.frame
                frame.size.width = min(frame.width, screen.width)
                frame.size.height = min(frame.height, screen.height)
                frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
                w.setFrame(frame, display: false)
            }
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

    var readerIsVisible: Bool {
        model.subagentBrowser.selection != nil || model.selectedChat.map { mainArea.readerMode.mode.showsReader($0) } == true
    }

    var terminalMinimum: CGFloat {
        model.selectedChat?.terminal?.minimumWidth(columns: 80) ?? WindowLayout.readerMinimum
    }

    var minimumWindowSize: NSSize {
        NSSize(width: WindowLayout.minimumWidth(reader: readerIsVisible, terminalMinimum: terminalMinimum,
            panelWanted: model.panelVisible, panelMinimum: WindowLayout.panelMinimum(for: model.panelTab)), height: 460)
    }

    private var chatTargets: [CGFloat] {
        if readerIsVisible { return WindowLayout.readerTargets }
        return WindowLayout.terminalTargets.map { model.selectedChat?.terminal?.minimumWidth(columns: $0) ?? WindowLayout.readerMinimum }
    }

    func preferredPanelWidth() -> CGFloat {
        let width = CGFloat(model.panelWidth ?? 0)
        return width >= Self.minPreferredPanelWidth ? width : Self.defaultPanelWidth
    }

    func applyInitialWidths() {
        restoreFrame()
        frameRestored = true
        applyLayout()
    }

    /// Recomputing a constrained split never overwrites a user's larger preferred widths.
    func applyLayout(availableWidth: CGFloat? = nil) {
        guard frameRestored, !syncingCollapse, !dragging else { return }
        syncingCollapse = true
        defer { syncingCollapse = false }
        if model.panelVisible && (!lastPanelVisible || model.selectedCodeTabID != lastDocumentID) {
            showPanelWhenSingle = true
        }
        lastPanelVisible = model.panelVisible
        lastDocumentID = model.selectedCodeTabID
        if !model.panelVisible { focusPanel = false }
        let sv = split.splitView
        let floor = readerIsVisible ? WindowLayout.readerMinimum : terminalMinimum
        let input = WindowLayout.Input(width: availableWidth ?? sv.bounds.width, reader: readerIsVisible,
                                       terminalMinimum: terminalMinimum,
                                       sidebarWanted: model.sidebarVisible, panelWanted: model.panelVisible,
                                       sidebarPreference: CGFloat(model.sidebarWidth ?? 248),
                                       panelPreference: preferredPanelWidth(),
                                       chatPreference: (readerIsVisible ? model.readerWidth : model.terminalWidth).map { CGFloat($0) },
                                       panelMinimum: WindowLayout.panelMinimum(for: model.panelTab),
                                       sidebarWasAutoHidden: autoHidden, focus: focusPanel,
                                       showPanelWhenSingle: showPanelWhenSingle)
        let result = WindowLayout.resolve(input)
        effectiveLayout = result
        autoHidden = result.sidebarAutoHidden && !focusPanel
        // Collapse before raising the visible face's floor, avoiding an intermediate
        // impossible three-column layout when switching from Reader to Terminal.
        NSLayoutConstraint.deactivate(paneFloors)
        sidebarItem.isCollapsed = result.sidebar == 0
        panelItem.isCollapsed = result.panel == 0
        mainItem.isCollapsed = result.chat == 0
        paneFloors[1].constant = floor
        paneFloors[2].constant = input.panelMinimum
        for (constraint, visible) in zip(paneFloors, [result.sidebar > 0, result.chat > 0, result.panel > 0]) {
            constraint.isActive = visible
        }
        windowMinimumWidth.constant = minimumWindowSize.width
        window?.minSize = minimumWindowSize
        sv.adjustSubviews()
        sv.layoutSubtreeIfNeeded()
        if result.sidebar > 0 { sv.setPosition(result.sidebar, ofDividerAt: 0) }
        if result.panel > 0 && result.chat > 0 {
            sv.setPosition(sv.bounds.width - result.panel - 1, ofDividerAt: 1)
        }
        sv.layoutSubtreeIfNeeded()
        mainArea.layoutTerminals()
        let state = model.layoutState
        if state.sidebarAutoHidden != result.sidebarAutoHidden { state.sidebarAutoHidden = result.sidebarAutoHidden }
        if state.focused != focusPanel { state.focused = focusPanel }
        if state.single != result.single { state.single = result.single }
        if state.showingPanel != (result.panel > 0) { state.showingPanel = result.panel > 0 }
    }

    func togglePanelFocus() {
        if !focusPanel {
            splitResponder = window?.firstResponder
            panelVisibleBeforeFocus = model.panelVisible
            model.panelVisible = true
            showPanelWhenSingle = true
        }
        focusPanel.toggle()
        if !focusPanel {
            autoHidden = false
            model.panelVisible = panelVisibleBeforeFocus
        }
        applyLayout()
        if !focusPanel, let responder = splitResponder { window?.makeFirstResponder(responder) }
    }

    func handleLayoutRequest(_ request: WindowLayoutState.Request) {
        switch request {
        case .focus: togglePanelFocus(); return
        case .chat:
            showPanelWhenSingle = false
            focusPanel = false
            autoHidden = false
        case .panel:
            showPanelWhenSingle = true
            model.panelVisible = true
            lastPanelVisible = true
        case .navigation:
            let popover = NSPopover()
            popover.behavior = .transient
            let host = NSHostingController(rootView: SidebarView().environmentObject(model))
            host.sizingOptions = []
            popover.contentViewController = host
            popover.contentSize = NSSize(width: 280, height: min(640, max(300, split.view.bounds.height - 60)))
            navigationPopover = popover
            let anchor = effectiveLayout.chat > 0 ? mainArea.view : panel.view
            popover.show(relativeTo: NSRect(x: 72, y: anchor.bounds.height - 40, width: 24, height: 24), of: anchor, preferredEdge: .minY)
            return
        case .preset(let index):
            guard chatTargets.indices.contains(index) else { return }
            if readerIsVisible { model.readerWidth = Double(chatTargets[index]) }
            else { model.terminalWidth = Double(chatTargets[index]) }
            focusPanel = false
            model.scheduleSave()
        case .reset:
            model.readerWidth = nil
            model.terminalWidth = nil
            model.panelWidth = Double(Self.defaultPanelWidth)
            model.sidebarWidth = 248
            focusPanel = false
            model.scheduleSave()
        }
        applyLayout()
        if case .chat = request { mainArea.focusVisibleConversation() }
    }

    private func rememberDraggedWidths() {
        guard frameRestored, !syncingCollapse, !focusPanel, !effectiveLayout.single else { return }
        if !sidebarItem.isCollapsed { model.sidebarWidth = Double(sidebarItem.viewController.view.frame.width) }
        if !panelItem.isCollapsed {
            model.panelWidth = Double(panel.view.frame.width)
            if readerIsVisible { model.readerWidth = Double(mainArea.view.frame.width) }
            else { model.terminalWidth = Double(mainArea.view.frame.width) }
        }
        model.scheduleSave()
    }

    private func splitDidResize() {
        guard !syncingCollapse, frameRestored, !dragging else { return }
        applyLayout()
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        if let c = model.selectedChat, c.status == .needsYou, let t = c.terminal, t.focused {
            c.status = .running
            model.objectWillChange.send()
        }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        applyLayout(availableWidth: frameSize.width)
        return frameSize
    }

    func windowDidResize(_ notification: Notification) { applyLayout(); saveFrame() }
    func windowDidMove(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard frameRestored, let w = window, !w.styleMask.contains(.fullScreen) else { return }
        model.windowFrame = w.frameDescriptor
        model.scheduleSave()
    }
}
