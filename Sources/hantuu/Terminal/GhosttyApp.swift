// The libghostty runtime: one ghostty_app_t for the whole process, its config, and the
// callbacks libghostty uses to talk to the host (wakeups, actions, clipboard, close).
//
// Adapted from Ghostty's macOS app, macos/Sources/Ghostty/Ghostty.App.swift and
// Ghostty.Config.swift (Ghostty v1.4.0). MIT License, Copyright (c) 2024 Mitchell Hashimoto,
// Ghostty contributors. https://github.com/ghostty-org/ghostty
import AppKit
import GhosttyKit

final class GhosttyApp {
    static private(set) var shared: GhosttyApp?

    private(set) var config: ghostty_config_t
    private(set) var app: ghostty_app_t!
    private(set) var diagnostics: [String] = []

    /// Terminal background from the user's Ghostty config, used for the window chrome.
    var backgroundColor: NSColor { Self.color(config, key: "background") ?? NSColor(hex: 0x161616) }
    var foregroundColor: NSColor { Self.color(config, key: "foreground") ?? NSColor(hex: 0xE6E6E6) }

    /// Call once, before any surface exists. Loads the user's normal Ghostty config files
    /// (read-only) so the terminals get the same font, colours and padding as Ghostty.
    @discardableResult
    static func start() -> GhosttyApp? {
        if let shared { return shared }

        // libghostty reads its environment at init. Point it at the resources we bundle so
        // shell integration and the xterm-ghostty terminfo work inside our surfaces.
        if let res = Bundle.main.resourceURL?.appendingPathComponent("ghostty"),
           FileManager.default.fileExists(atPath: res.path) {
            setenv("GHOSTTY_RESOURCES_DIR", res.path, 1)
        } else if let dev = Paths.devGhosttyResources {
            setenv("GHOSTTY_RESOURCES_DIR", dev.path, 1)
        }

        // Only argv[0]: our own flags (--self-test, --data-dir) aren't Ghostty CLI actions.
        var argv0 = strdup(CommandLine.arguments.first ?? "hantuu")
        let rc = withUnsafeMutablePointer(to: &argv0) { ptr in
            ghostty_init(1, ptr)
        }
        guard rc == GHOSTTY_SUCCESS else {
            Log.write("ghostty_init failed rc=\(rc)")
            return nil
        }
        guard let cfg = loadConfig() else { return nil }
        let instance = GhosttyApp(config: cfg)
        guard instance.app != nil else { return nil }
        shared = instance
        return instance
    }

    private static func loadConfig() -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else {
            Log.write("ghostty_config_new failed")
            return nil
        }
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        return cfg
    }

    private init(config: ghostty_config_t) {
        self.config = config
        let count = ghostty_config_diagnostics_count(config)
        for i in 0..<count {
            let d = ghostty_config_get_diagnostic(config, i)
            if let msg = d.message { diagnostics.append(String(cString: msg)) }
        }
        if !diagnostics.isEmpty { Log.write("ghostty config diagnostics: \(diagnostics)") }

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in GhosttyApp.wakeup(userdata) },
            action_cb: { app, target, action in GhosttyApp.action(app!, target: target, action: action) },
            read_clipboard_cb: { userdata, loc, state, mimes, mimesLen, list in
                GhosttyApp.readClipboard(userdata, location: loc, state: state, mimes: mimes, mimesLen: mimesLen, list: list)
            },
            confirm_read_clipboard_cb: { userdata, confirm, state, request in
                GhosttyApp.confirmReadClipboard(userdata, confirm: confirm, state: state, request: request)
            },
            write_clipboard_cb: { userdata, loc, content, len, confirm in
                GhosttyApp.writeClipboard(userdata, location: loc, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyApp.closeSurface(userdata, processAlive: processAlive)
            }
        )
        guard let app = ghostty_app_new(&runtime, config) else {
            Log.write("ghostty_app_new failed")
            return
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp?.isActive ?? false)
        ghostty_app_set_color_scheme(app, GHOSTTY_COLOR_SCHEME_DARK)

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_set_focus(app, true) }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_set_focus(app, false) }
        }
        nc.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_keyboard_changed(app) }
        }
    }

    /// Re-read the Ghostty config files (Ghostty's reload_config binding lands here).
    func reloadConfig() {
        guard let cfg = Self.loadConfig() else { return }
        ghostty_app_update_config(app, cfg)
        let old = config
        config = cfg
        ghostty_config_free(old)
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: Config helpers

    static func color(_ config: ghostty_config_t, key: String) -> NSColor? {
        var c = ghostty_config_color_s()
        guard ghostty_config_get(config, &c, key, UInt(key.lengthOfBytes(using: .utf8))) else { return nil }
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    // MARK: Callbacks

    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let state = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
        // Wakeups come from any thread; ticks must happen on the main thread.
        DispatchQueue.main.async { state.tick() }
    }

    private static func view(fromUserdata userdata: UnsafeMutableRawPointer?) -> TerminalView? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func view(fromSurface surface: ghostty_surface_t?) -> TerminalView? {
        guard let surface, let ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<TerminalView>.fromOpaque(ud).takeUnretainedValue()
    }

    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard let view = view(fromUserdata: userdata) else { return }
        DispatchQueue.main.async { view.surfaceRequestedClose(processAlive: processAlive) }
    }

    private static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let surfaceView: TerminalView? = target.tag == GHOSTTY_TARGET_SURFACE ? view(fromSurface: target.target.surface) : nil

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let v = surfaceView, let p = action.action.set_title.title else { return false }
            let title = String(cString: p)
            DispatchQueue.main.async { v.terminalTitleDidChange(title) }
            return true

        case GHOSTTY_ACTION_PWD:
            guard let v = surfaceView, let p = action.action.pwd.pwd else { return false }
            let pwd = String(cString: p)
            DispatchQueue.main.async { v.pwd = pwd }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            guard let v = surfaceView else { return false }
            DispatchQueue.main.async { v.events?.terminalNeedsAttention(v, reason: "bell") }
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard let v = surfaceView else { return false }
            let n = action.action.desktop_notification
            let title = n.title.map { String(cString: $0) } ?? ""
            let body = n.body.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                v.events?.terminalNeedsAttention(v, reason: "notification: \(title) \(body)".trimmingCharacters(in: .whitespaces))
            }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            guard let ptr = u.url else { return false }
            let data = Data(bytes: ptr, count: Int(u.len))
            let url = String(decoding: data, as: UTF8.self)
            let kind = u.kind
            DispatchQueue.main.async {
                let base = surfaceView?.currentDirectory
                Log.write("open_url kind=\(kind.rawValue) url=\(url)")
                FileRouter.shared.openFromTerminal(url, isOSC8: kind == GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, base: base)
            }
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            guard let v = surfaceView else { return false }
            let code = Int(action.action.child_exited.exit_code)
            DispatchQueue.main.async { v.childDidExit(code: code) }
            // Chats show their own "ended" bar, so suppress Ghostty's in-terminal message.
            return v.handlesChildExit

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let v = surfaceView else { return false }
            let shape = action.action.mouse_shape
            DispatchQueue.main.async { v.setCursorShape(shape) }
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            let visible = action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE
            DispatchQueue.main.async { if !visible { NSCursor.setHiddenUntilMouseMoves(true) } }
            return true

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            guard let v = surfaceView else { return false }
            let l = action.action.mouse_over_link
            let link: String? = (l.url != nil && l.len > 0)
                ? String(decoding: Data(bytes: l.url!, count: Int(l.len)), as: UTF8.self) : nil
            DispatchQueue.main.async { v.hoverLinkDidChange(link) }
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            guard let v = surfaceView else { return false }
            let s = action.action.cell_size
            // Reported in pixels; the view works in points (as Ghostty's own host converts it).
            DispatchQueue.main.async { v.cellSize = v.convertFromBacking(NSSize(width: CGFloat(s.width), height: CGFloat(s.height))) }
            return true

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            DispatchQueue.main.async { GhosttyApp.shared?.reloadConfig() }
            return true

        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
            DispatchQueue.main.async { surfaceView?.window?.toggleFullScreen(nil) }
            return true

        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true

        // Ghostty keybindings that mean "new terminal", "new window" and so on map onto
        // hantuu's own commands, so Felix's muscle memory from Ghostty still does something
        // sensible here.
        case GHOSTTY_ACTION_NEW_TAB:
            DispatchQueue.main.async { AppActions.shared.newTerminalTab() }
            return true
        case GHOSTTY_ACTION_NEW_WINDOW:
            DispatchQueue.main.async { AppActions.shared.newChat(agentID: nil, projectID: nil) }
            return true
        case GHOSTTY_ACTION_GOTO_TAB:
            let raw = action.action.goto_tab.rawValue
            if raw > 0 {
                DispatchQueue.main.async { AppActions.shared.selectChat(index: Int(raw) - 1) }
                return true
            }
            return false

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            let healthy = action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY
            if !healthy { Log.write("renderer unhealthy") }
            return true

        case GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_SCROLLBAR,
             GHOSTTY_ACTION_SELECTION_CHANGED, GHOSTTY_ACTION_PROGRESS_REPORT, GHOSTTY_ACTION_COMMAND_FINISHED,
             GHOSTTY_ACTION_KEY_SEQUENCE, GHOSTTY_ACTION_KEY_TABLE, GHOSTTY_ACTION_INITIAL_SIZE,
             GHOSTTY_ACTION_SIZE_LIMIT, GHOSTTY_ACTION_SECURE_INPUT:
            return true

        default:
            return false
        }
    }

    // MARK: Clipboard

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let view = view(fromUserdata: userdata), let surface = view.surface else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }
        guard location == GHOSTTY_CLIPBOARD_STANDARD else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        let pb = NSPasteboard.general

        var contents: [ClipboardContent] = []
        var seen = Set<String>()
        if let mimes {
            for i in 0..<mimesLen {
                guard let ptr = mimes[i] else { continue }
                let mime = String(cString: ptr)
                guard seen.insert(mime).inserted, let data = pb.hantuuData(forMime: mime) else { continue }
                contents.append(.init(mime: mime, data: data))
            }
        }
        let available = list ? pb.hantuuAvailableMimes() : []
        if contents.isEmpty && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        completeClipboardRequest(surface, contents: contents, available: available, state: state)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let view = view(fromUserdata: userdata), let surface = view.surface else { return }
        guard let confirm else { ghostty_surface_deny_clipboard_request(surface, state); return }
        let c = confirm.pointee
        var reps: [ClipboardContent] = []
        if let contents = c.contents {
            for i in 0..<c.contents_len {
                let item = contents[i]
                let data = item.len > 0 ? Data(bytes: item.data, count: item.len) : Data()
                reps.append(.init(mime: String(cString: item.mime), data: data))
            }
        }
        var avail: [String] = []
        if let available = c.available {
            for i in 0..<c.available_len { if let p = available[i] { avail.append(String(cString: p)) } }
        }
        let text = reps.first(where: { $0.mime == "text/plain" }).flatMap { String(data: $0.data, encoding: .utf8) } ?? ""

        DispatchQueue.main.async {
            let alert = NSAlert()
            switch request {
            case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
                alert.messageText = "Paste this text?"
                alert.informativeText = "It may run commands as soon as it's pasted.\n\n" + String(text.prefix(600))
                alert.addButton(withTitle: "Paste")
            default:
                alert.messageText = "Let the program read the clipboard?"
                alert.informativeText = String(text.prefix(600))
                alert.addButton(withTitle: "Allow")
            }
            alert.addButton(withTitle: "Cancel")
            let ok = alert.runModal() == .alertFirstButtonReturn
            guard let surface = view.surface else { return }
            if ok {
                completeClipboardRequest(surface, contents: reps, available: avail, state: state, confirmed: true)
            } else {
                ghostty_surface_deny_clipboard_request(surface, state)
            }
        }
    }

    private static func completeClipboardRequest(
        _ surface: ghostty_surface_t,
        contents: [ClipboardContent],
        available: [String],
        state: UnsafeMutableRawPointer?,
        confirmed: Bool = false
    ) {
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        var buffers: [UnsafeMutableRawPointer] = []
        defer {
            cStrings.forEach { free($0) }
            buffers.forEach { $0.deallocate() }
        }
        var cContents: [ghostty_clipboard_content_s] = []
        for entry in contents {
            guard let mime = strdup(entry.mime) else { continue }
            cStrings.append(mime)
            let buf = UnsafeMutableRawPointer.allocate(byteCount: max(entry.data.count, 1), alignment: 1)
            buffers.append(buf)
            entry.data.withUnsafeBytes { src in
                if let base = src.baseAddress { buf.copyMemory(from: base, byteCount: src.count) }
            }
            cContents.append(ghostty_clipboard_content_s(mime: mime, data: buf.assumingMemoryBound(to: CChar.self), len: entry.data.count))
        }
        var cAvailable: [UnsafePointer<CChar>?] = []
        for mime in available {
            guard let s = strdup(mime) else { continue }
            cStrings.append(s)
            cAvailable.append(UnsafePointer(s))
        }
        cContents.withUnsafeBufferPointer { cb in
            cAvailable.withUnsafeBufferPointer { ab in
                var complete = ghostty_clipboard_complete_s(
                    contents: cb.baseAddress, contents_len: cb.count,
                    available: ab.baseAddress, available_len: ab.count,
                    confirmed: confirmed, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &complete, state)
            }
        }
    }

    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content, len > 0 else { return }
        var items: [ClipboardContent] = []
        for i in 0..<len {
            let c = content[i]
            guard let mime = c.mime else { continue }
            let data = c.len > 0 && c.data != nil ? Data(bytes: c.data, count: c.len) : Data()
            items.append(.init(mime: String(cString: mime), data: data))
        }
        guard !items.isEmpty else { return }
        let write = {
            let pb = NSPasteboard.general
            let types = items.compactMap { NSPasteboard.PasteboardType(hantuuMime: $0.mime) }
            pb.declareTypes(types, owner: nil)
            for item in items {
                if let t = NSPasteboard.PasteboardType(hantuuMime: item.mime) { pb.setData(item.data, forType: t) }
            }
        }
        if !confirm {
            DispatchQueue.main.async(execute: write)
            return
        }
        let text = items.first(where: { $0.mime == "text/plain" }).flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Let the program copy this to the clipboard?"
            alert.informativeText = String(text.prefix(600))
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { write() }
        }
    }
}

struct ClipboardContent {
    let mime: String
    let data: Data
}
