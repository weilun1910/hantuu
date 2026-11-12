// An NSView hosting one libghostty surface: a real terminal running a command (an agent)
// or the user's shell. libghostty attaches its own Metal layer to this view and renders on
// its own thread; this class feeds it size, focus, keyboard, IME, mouse and drops.
//
// Keyboard, IME and mouse handling are adapted from Ghostty's macOS app,
// macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift (Ghostty v1.4.0).
// MIT License, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors.
import AppKit
import GhosttyKit

protocol TerminalEvents: AnyObject {
    func terminalTitleDidChange(_ view: TerminalView, title: String)
    func terminalNeedsAttention(_ view: TerminalView, reason: String)
    func terminalChildDidExit(_ view: TerminalView, code: Int)
    func terminalRequestedClose(_ view: TerminalView, processAlive: Bool)
    func terminalFocusDidChange(_ view: TerminalView, focused: Bool)
}

final class TerminalView: NSView, NSTextInputClient {
    struct Launch {
        var workingDirectory: String?
        /// Run through the login shell by libghostty. Nil means the user's default shell.
        var command: String?
        var environment: [String: String] = [:]
        var initialInput: String?
    }

    weak var events: TerminalEvents?
    private(set) var surface: ghostty_surface_t?
    let launch: Launch
    /// Chats keep their terminal after the agent exits and show their own bar, so they
    /// suppress Ghostty's "Process exited" message. Panel shells just close.
    let handlesChildExit: Bool

    private(set) var title: String = ""
    var pwd: String?
    static let geometryDidChange = Notification.Name("hantuu.terminal.geometryDidChange")
    var cellSize: NSSize = .zero {
        didSet { if oldValue != cellSize { refreshGeometry() } }
    }
    private var measuredCellPixels: CGFloat = 0
    private var measuredScale: CGFloat = 0
    private var measuredPaddingPixels: CGFloat = 0
    private var settledGrid: (columns: Int, rows: Int)?
    private(set) var geometryChangedAt = Date.distantPast
    var geometryIsStable: Bool { Date().timeIntervalSince(geometryChangedAt) >= 0.2 }

    var measuredColumns: Int {
        surface.map { Int(ghostty_surface_size($0).columns) } ?? 0
    }

    /// The residual includes configured padding and less than one spare cell. Cache it
    /// for this font and scale so the minimum does not oscillate while dragging.
    func refreshGeometry() {
        guard let surface else { return }
        let size = ghostty_surface_size(surface)
        let cell = CGFloat(size.cell_width_px)
        let scale = convertToBacking(NSSize(width: 1, height: 1)).width
        guard cell > 0, size.columns > 1, scale > 0 else { return }
        let changed = cell != measuredCellPixels || scale != measuredScale
        if let previous = settledGrid,
           previous.columns != Int(size.columns) || previous.rows != Int(size.rows) || changed {
            geometryChangedAt = Date()
        }
        settledGrid = (Int(size.columns), Int(size.rows))
        if changed {
            measuredCellPixels = cell
            measuredScale = scale
            measuredPaddingPixels = max(0, CGFloat(size.width_px) - CGFloat(size.columns) * cell)
            NotificationCenter.default.post(name: Self.geometryDidChange, object: self)
        }
    }

    func minimumWidth(columns: Int) -> CGFloat {
        refreshGeometry()
        guard measuredCellPixels > 0, measuredScale > 0 else { return max(800, frame.width) }
        return ceil((CGFloat(columns) * measuredCellPixels + measuredPaddingPixels) / measuredScale)
    }
    private(set) var exitCode: Int?
    private(set) var focused = false

    var currentDirectory: String? { pwd ?? launch.workingDirectory }

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var contentSize: NSSize = .zero
    private var currentCursor: NSCursor = .iBeam
    private let linkLabel = NSTextField(labelWithString: "")

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    init(app: ghostty_app_t, launch: Launch, handlesChildExit: Bool) {
        self.launch = launch
        self.handlesChildExit = handlesChildExit
        // Non-zero so the renderer has something to draw into before layout.
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.font_size = 0
        cfg.wait_after_command = false
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        let keys = Array(launch.environment.keys)
        let values = keys.map { launch.environment[$0]! }
        let cKeys = keys.map { strdup($0) }
        let cValues = values.map { strdup($0) }
        defer { cKeys.forEach { free($0) }; cValues.forEach { free($0) } }
        var env: [ghostty_env_var_s] = []
        for i in 0..<keys.count { env.append(ghostty_env_var_s(key: cKeys[i], value: cValues[i])) }

        let wd = launch.workingDirectory.map { strdup($0) } ?? nil
        let cmd = launch.command.map { strdup($0) } ?? nil
        let input = launch.initialInput.map { strdup($0) } ?? nil
        defer { free(wd); free(cmd); free(input) }
        cfg.working_directory = UnsafePointer(wd)
        cfg.command = UnsafePointer(cmd)
        cfg.initial_input = UnsafePointer(input)

        surface = env.withUnsafeMutableBufferPointer { buf -> ghostty_surface_t? in
            cfg.env_vars = buf.baseAddress
            cfg.env_var_count = buf.count
            return ghostty_surface_new(app, &cfg)
        }
        if surface == nil { Log.write("ghostty_surface_new failed for command=\(launch.command ?? "<shell>")") }
        GhosttyApp.shared?.register(self)

        registerForDraggedTypes([.fileURL, .string])
        updateTrackingAreas()

        linkLabel.font = .systemFont(ofSize: 11)
        linkLabel.textColor = Theme.pair(dark: NSColor(white: 0.85, alpha: 1), light: NSColor(white: 0.2, alpha: 1))
        linkLabel.drawsBackground = true
        linkLabel.backgroundColor = Theme.pair(dark: NSColor(white: 0.12, alpha: 0.95), light: NSColor(white: 0.97, alpha: 0.95))
        linkLabel.isBordered = false
        linkLabel.lineBreakMode = .byTruncatingMiddle
        linkLabel.isHidden = true
        linkLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(linkLabel)
        NSLayoutConstraint.activate([
            linkLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            linkLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            linkLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    /// Light or dark terminal colours (GhosttyApp.setColorScheme calls this for every terminal).
    func applyColorScheme(_ scheme: ghostty_color_scheme_e) {
        if let surface { ghostty_surface_set_color_scheme(surface, scheme) }
    }

    /// Frees the surface now (kills the child process) instead of waiting for deinit.
    func destroy() {
        if let s = surface {
            surface = nil
            ghostty_surface_free(s)
        }
        removeFromSuperview()
    }

    // MARK: State

    var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    var needsConfirmQuit: Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    func terminalTitleDidChange(_ t: String) {
        title = t
        events?.terminalTitleDidChange(self, title: t)
    }

    func childDidExit(code: Int) {
        exitCode = code
        events?.terminalChildDidExit(self, code: code)
    }

    func surfaceRequestedClose(processAlive: Bool) {
        events?.terminalRequestedClose(self, processAlive: processAlive)
    }

    func hoverLinkDidChange(_ link: String?) {
        if let link, !link.isEmpty {
            linkLabel.stringValue = " " + link + " "
            linkLabel.isHidden = false
        } else {
            linkLabel.isHidden = true
        }
    }

    /// Visible text of the whole screen plus scrollback (used by the self test).
    func screenText() -> String {
        guard let surface else { return "" }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// Shows or hides the view and tells the renderer, so hidden chats stop drawing.
    func setVisible(_ visible: Bool) {
        isHidden = !visible
        if let surface { ghostty_surface_set_occlusion(surface, visible) }
    }

    /// Types text into the terminal as a paste (bracketed if the program asked for it).
    func pasteText(_ text: String) {
        guard let surface else { return }
        let len = text.utf8CString.count
        guard len > 1 else { return }
        text.withCString { ghostty_surface_paste_text(surface, $0, UInt(len - 1)) }
    }

    func perform(binding: String) {
        guard let surface else { return }
        let len = binding.utf8CString.count
        _ = binding.withCString { ghostty_surface_binding_action(surface, $0, UInt(len - 1)) }
    }

    // MARK: Layout and focus

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeDidChange(newSize)
    }

    private func sizeDidChange(_ size: NSSize) {
        contentSize = size
        guard let surface, size.width > 0, size.height > 0 else { return }
        let px = convertToBacking(size)
        let before = ghostty_surface_size(surface)
        let width = UInt32(max(1, px.width)), height = UInt32(max(1, px.height))
        guard before.width_px != width || before.height_px != height else { return }
        ghostty_surface_set_size(surface, width, height)
        let after = ghostty_surface_size(surface)
        // Only a changed text grid requires the provider to reflow its screen.
        if before.columns != after.columns || before.rows != after.rows { geometryChangedAt = Date() }
        refreshGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, let surface else { return }
        if let screen = window.screen, let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            ghostty_surface_set_display_id(surface, id.uint32Value)
        }
        viewDidChangeBackingProperties()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let fb = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, fb.width / frame.width, fb.height / frame.height)
        sizeDidChange(contentSize == .zero ? frame.size : contentSize)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { setFocused(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { setFocused(false) }
        return ok
    }

    private func setFocused(_ f: Bool) {
        guard focused != f else { return }
        focused = f
        if let surface { ghostty_surface_set_focus(surface, f) }
        events?.terminalFocusDidChange(self, focused: f)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: frame, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways], owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: currentCursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: currentCursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: currentCursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL: currentCursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: currentCursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: currentCursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: currentCursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_E_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE:
            currentCursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE:
            currentCursor = .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: currentCursor = .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_COPY: currentCursor = .dragCopy
        case GHOSTTY_MOUSE_SHAPE_ALIAS: currentCursor = .dragLink
        default: currentCursor = .iBeam
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GhosttyInput.mods(event.modifierFlags))
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GhosttyInput.mouseButton(event.buttonNumber), GhosttyInput.mods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GhosttyInput.mouseButton(event.buttonNumber), GhosttyInput.mods(event.modifierFlags))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return super.rightMouseDown(with: event) }
        if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, GhosttyInput.mods(event.modifierFlags)) { return }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, GhosttyInput.mods(event.modifierFlags)) { return }
        super.rightMouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        if NSEvent.pressedMouseButtons != 0 { return }
        ghostty_surface_mouse_pos(surface, -1, -1, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        ghostty_surface_mouse_scroll(surface, x, y, GhosttyInput.scrollMods(precision: precise, phase: event.momentumPhase))
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Clear", action: #selector(clearScreen(_:)), keyEquivalent: "")
        return menu
    }

    @objc func copy(_ sender: Any?) { perform(binding: "copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { perform(binding: "paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { perform(binding: "select_all") }
    @objc func clearScreen(_ sender: Any?) { perform(binding: "clear_screen") }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types,
              !Set(types).isDisjoint(with: [.fileURL, .string]) else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Files become shell-escaped absolute paths, the same thing Ghostty types. Claude Code
        // picks up an image path pasted this way as an attachment.
        guard let content = sender.draggingPasteboard.hantuuStringContents() else { return false }
        window?.makeFirstResponder(self)
        DispatchQueue.main.async { self.pasteText(content) }
        return true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }
        // Translate mods for configs like macos-option-as-alt.
        let translated = GhosttyInput.flags(ghostty_surface_key_translation_mods(surface, GhosttyInput.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translated.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        // Reuse the original event when nothing changed; Korean IMEs depend on identity.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        }
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedBefore = markedText.length > 0
        let layoutBefore: String? = markedBefore ? nil : GhosttyInput.keyboardLayoutID
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // An input-method switch swallowed this key.
        if !markedBefore && layoutBefore != GhosttyInput.keyboardLayoutID { return }

        syncPreedit(clearIfNeeded: markedBefore)
        let composing = markedText.length > 0 || markedBefore

        if markedBefore, let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.isComposingControl(text, composing: composing) {
                _ = committedText(action, text: text)
            }
            return
        }

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.isComposingControl(text, composing: composing) {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            if Self.isComposingControl(event.characters, composing: composing) { return }
            _ = keyAction(action, event: event, translationEvent: translationEvent,
                          text: translationEvent.ghosttyCharacters, composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused else { return false }

        // hantuu's own shortcuts (new chat, close, jump to chat, toggle panels, copy and
        // paste) win over Ghostty keybindings. Copy and paste come back to this view through
        // the Edit menu.
        if event.modifierFlags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }

        // Ghostty keybindings from the user's config (cmd+k clear, cmd+= font size, ...).
        if let surface {
            var ev = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
            var flags = ghostty_binding_flags_e(0)
            let isBinding = (event.characters ?? "").withCString { ptr -> Bool in
                ev.text = ptr
                return ghostty_surface_key_is_binding(surface, ev, &flags)
            }
            if isBinding {
                keyDown(with: event)
                return true
            }
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            if !event.modifierFlags.contains(.control) { return false }
            equivalent = "\r"
        case "/":
            if !event.modifierFlags.contains(.control) || !event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }
        if let final = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode) {
            keyDown(with: final)
        }
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let mods = GhosttyInput.mods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil,
                           text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var ev = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        ev.composing = composing
        if let text = text?.keyEventText {
            return text.withCString { ptr in
                ev.text = ptr
                return ghostty_surface_key(surface, ev)
            }
        }
        return ghostty_surface_key(surface, ev)
    }

    private func committedText(_ action: ghostty_input_action_e, text: String) -> Bool {
        guard let surface else { return false }
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = 0
        ev.mods = GHOSTTY_MODS_NONE
        ev.consumed_mods = GHOSTTY_MODS_NONE
        ev.unshifted_codepoint = 0
        ev.composing = false
        return text.withCString { ptr in
            ev.text = ptr
            return ghostty_surface_key(surface, ev)
        }
    }

    private static func isComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1, let s = text.unicodeScalars.first else { return false }
        return s.value < 0x20
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 { str.withCString { ghostty_surface_preedit(surface, $0, UInt(len - 1)) } }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: break
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
        var x: Double = 0, y: Double = 0
        var w: Double = cellSize.width, h: Double = cellSize.height
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        if range.length == 0, w > 0 { w = 0 }
        let viewRect = NSRect(x: x, y: frame.size.height - y, width: w, height: max(h, cellSize.height))
        let winRect = convert(viewRect, to: nil)
        return window?.convertToScreen(winRect) ?? winRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        unmarkText()
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }
        if !chars.isEmpty { _ = committedText(GHOSTTY_ACTION_PRESS, text: chars) }
    }

    override func doCommand(by selector: Selector) {
        // Re-dispatch command keys that performKeyEquivalent deferred, so they get encoded.
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }
}
