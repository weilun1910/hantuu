import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `HANTUU_LIVE_PASTE_TEST=<folder> scripts/selftest.sh` runs real Claude Code and Codex chats in
/// that folder (one both agents already trust), offscreen, and never answers a menu.
/// - HANTUU_LIVE_PASTE_CASES=1 pastes files into each agent's own input box, one way at a time,
///   prints what the box shows, and clears it, to see which pastes become an attachment. Nothing
///   is sent.
/// - HANTUU_LIVE_PASTE_SEND=1 sends one tiny message with a picture through reader mode's message
///   box, and checks the agent got the picture and the reader shows it in your message.
/// HANTUU_LIVE_PASTE_AGENTS=claude or =codex runs one agent only.
extension SelfTest {
    static func attachmentLiveProbe(_ dir: URL) {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["HANTUU_LIVE_PASTE_TEST"], !folder.isEmpty else { return }
        guard let g = GhosttyApp.shared ?? GhosttyApp.start() else { check("live paste: libghostty", false); return }
        setvbuf(stdout, nil, _IOLBF, 0)
        let fixtures = URL(fileURLWithPath: folder).appendingPathComponent("fixtures", isDirectory: true)
        Paths.ensure(fixtures)
        let red = fixtures.appendingPathComponent("red square.png")
        let blue = fixtures.appendingPathComponent("blue (2).png")
        let tiff = fixtures.appendingPathComponent("green.tiff")
        let pdf = fixtures.appendingPathComponent("notes.pdf")
        _ = writeSolidImage(to: red, color: NSColor.systemRed, type: .png)
        _ = writeSolidImage(to: blue, color: NSColor.systemBlue, type: .png)
        _ = writeSolidImage(to: tiff, color: NSColor.systemGreen, type: .tiff)
        writeTinyPDF(to: pdf, text: "Probe notes")
        let agents = (env["HANTUU_LIVE_PASTE_AGENTS"] ?? "claude,codex").split(separator: ",").map(String.init)
        for id in agents {
            probeAgent(id, folder: folder, dir: dir, g: g, red: red, blue: blue, tiff: tiff, pdf: pdf,
                       cases: env["HANTUU_LIVE_PASTE_CASES"] == "1", send: env["HANTUU_LIVE_PASTE_SEND"] == "1")
        }
    }

    @discardableResult
    static func writeSolidImage(to url: URL, color: NSColor, size: Int = 64, type: UTType) -> Bool {
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setFillColor((color.usingColorSpace(.sRGB) ?? color).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }

    static func writeTinyPDF(to url: URL, text: String) {
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(at: NSPoint(x: 20, y: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// The agent's input box as text: the last lines of the screen.
    static func inputBox(_ tv: TerminalView, lines: Int = 8) -> String {
        tv.activeScreenText().split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(lines).joined(separator: "\n")
    }

    private static func probeAgent(_ id: String, folder: String, dir: URL, g: GhosttyApp, red: URL, blue: URL, tiff: URL, pdf: URL, cases: Bool, send: Bool) {
        let model = AppModel()
        let project = Project(path: folder)
        model.projects = [project]
        let center = StatusCenter()
        center.notifier = NoticeRecorder()
        center.appIsActive = { true }
        center.start(model: model, live: false)
        let chat = Chat(projectID: project.id, agentID: id)
        if id == "claude" { chat.sessionID = UUID().uuidString.lowercased() }
        var argv = chat.agent.launchArguments(sessionID: chat.sessionID)
        if id == "codex" { argv += LiveCheckRules.codexProcessConfiguration }
        let envv = ["HANTUU_CHAT_ID": chat.id.uuidString].merging(AgentHooks.environment(for: chat.id)) { a, _ in a }
        let tv = TerminalView(app: g.app, launch: .init(workingDirectory: folder, command: LoginShell.surfaceCommand(argv), environment: envv), handlesChildExit: true)
        let events = LiveEvents(chat: chat, center: center)
        tv.events = events
        chat.terminal = tv
        chat.startedAt = Date()
        model.chats = [chat]
        model.selectedChatID = chat.id
        let w = NSWindow(contentRect: NSRect(x: -8000, y: -4000, width: 1100, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let host = FillView(color: Theme.background)
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
        w.contentView = host
        tv.frame = host.bounds
        host.addSubview(tv)
        w.orderFrontRegardless()
        defer {
            withExtendedLifetime(events) {}
            print("      live paste \(id): screen at the end:\n" + inputBox(tv, lines: 14).split(separator: "\n").map { "        | " + $0 }.joined(separator: "\n"))
            tv.destroy()   // ends only the agent this test started
            w.orderOut(nil)
        }
        print("      live paste: \(id) in \(folder)")
        let up = waitUntil(90) {
            let s = TerminalScreen.analyze(tv.activeScreenText())
            return (s.ready && !s.busy) || s.menu != nil || chat.status == .ended
        }
        let first = TerminalScreen.analyze(tv.activeScreenText())
        guard up, first.menu == nil, chat.status != .ended else {
            check("live paste \(id): the agent opened without a menu (left unanswered)", false, inputBox(tv, lines: 20))
            return
        }
        _ = waitUntil(3) { false }

        func clear() {
            tv.pressBackspace(times: 220)
            _ = waitUntil(1.5) { false }
        }
        func probe(_ label: String, _ pastes: [String], wait: TimeInterval = 3) -> String {
            print("      live paste \(id) [\(label)] pasted: \(pastes.map(\.debugDescription))")
            for p in pastes {
                tv.pasteText(p)
                _ = waitUntil(wait) { false }
            }
            let box = inputBox(tv)
            print("      live paste \(id) [\(label)]:\n" + box.split(separator: "\n").map { "        | " + $0 }.joined(separator: "\n"))
            clear()
            return box
        }
        let r = ShellEscape.escape(red.path), b = ShellEscape.escape(blue.path)
        let t = ShellEscape.escape(tiff.path), p = ShellEscape.escape(pdf.path)
        if cases {
            _ = probe("one image path", [r])
            _ = probe("text with a path inside", ["look at \(r) please"])
            _ = probe("two image paths in one paste", ["\(r) \(b)"])
            _ = probe("two image pastes, then text", [r, b, "what colours?"])
            _ = probe("a TIFF path", [t])
            _ = probe("a PDF path", [p])
            _ = probe("a quoted path", ["'\(red.path)'"])
            _ = probe("a file URL", [red.absoluteString])
        }
        guard send else { return }

        // One tiny message with a picture, sent the way reader mode sends it.
        let settings = ChatSettings(file: dir.appendingPathComponent("paste-live-\(id)-settings.json"))
        settings.showChatsAsReader = true
        let rm = ReaderModeController(model: model, mode: ReaderMode(settings: settings))
        rm.statusProvider = { center.state(of: $0.id) }
        rm.install(in: host, top: host.topAnchor, above: tv)
        rm.sync(selected: chat)
        let kind: TranscriptKind = id == "codex" ? .codex : .claude
        let discovery = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            center.poll()
            guard chat.follower == nil else { return }
            var u: URL?
            if kind == .claude, let sid = chat.sessionID { u = ClaudeTranscriptParser.locate(sessionID: sid, cwd: folder) }
            if kind == .codex { u = CodexTranscriptParser.locate(cwd: folder, after: chat.startedAt, excluding: [])?.0 }
            guard let u else { return }
            chat.transcriptPath = u.path
            let f = TranscriptFollower(url: u, kind: kind, baseDir: folder)
            f.onAppend = { fresh in model.readerAppend.send((chat.id, fresh)) }
            chat.follower = f
            f.start()
            model.readerReload.send(chat.id)
        }
        defer {
            discovery.invalidate()
            chat.follower?.stop()
        }
        let ready = waitUntil(30) { rm.refresh(); return rm.composerMode == .ready }
        check("live paste \(id): the message box is ready", ready, "\(rm.composerMode)")
        guard ready else { return }
        // Exercise the same image-data import as Cmd-V without any pasteboard access.
        let content = ComposerPasteboard.Content.images([.init(data: (try? Data(contentsOf: red)) ?? Data(), type: .png)])
        _ = rm.composer.textView.onAttach?(content)
        let pasted = rm.composer.attachments.first
        check("live paste \(id): the picture is a chip in the message box", rm.composer.attachments.count == 1 && pasted?.pasted == true)
        var nativeImageSeen = false
        rm.observeImageTransport = { path, acknowledged, screen in
            nativeImageSeen = nativeImageSeen || acknowledged
            print("      live paste \(id): pasted=\(path.debugDescription), acknowledged=\(acknowledged), TUI=\(String(screen.suffix(1600)).debugDescription)")
        }
        rm.composer.textView.text = "What colour is this square? Answer with one word."
        let sent = rm.send()
        _ = waitUntil(4) { !rm.isTyping }
        print("      live paste \(id) [just after sending]:\n" + inputBox(tv, lines: 10).split(separator: "\n").map { "        | " + $0 }.joined(separator: "\n"))
        let gotImage = waitUntil(90) {
            rm.refresh()
            guard let p = chat.transcriptPath, let data = try? Data(contentsOf: URL(fileURLWithPath: p)) else { return false }
            return LiveCheckRules.imageReceipt(data, agent: id, token: "What colour is this square?").count > 0
        }
        let receipt = chat.transcriptPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            .map { LiveCheckRules.imageReceipt($0, agent: id, token: "What colour is this square?").summaries } ?? []
        print("      live paste \(id): native user transcript=\(receipt)")
        check("live paste \(id): the agent acknowledged a native image before submission", nativeImageSeen)
        check("live paste \(id): the agent got the picture as an image, not a path", sent && gotImage, String(tv.activeScreenText().suffix(600)))
        let replied = waitUntil(120) {
            rm.refresh()
            return (js(rm.reader!.page, "Array.from(document.querySelectorAll('section.entry.assistant')).some(e => /red/i.test(e.innerText))") as? Bool) == true
        }
        check("live paste \(id): it answered about the picture", replied, String(tv.activeScreenText().suffix(400)))
        let shown = waitUntil(10) {
            (js(rm.reader!.page, "Array.from(document.querySelectorAll('section.entry.user')).some(e => e.querySelector('img') && /colour is this square/.test(e.innerText))") as? Bool) == true
        }
        let userText = js(rm.reader!.page, "Array.from(document.querySelectorAll('section.entry.user')).map(e => e.innerText).join(' | ')") as? String ?? ""
        print("      live paste \(id): your message in the reader: \(userText.debugDescription)")
        check("live paste \(id): the reader shows the picture in your message", shown, userText)
        _ = waitUntil(20) { rm.refresh(); return rm.composerMode == .ready }
        _ = render(host, to: snapshotsFolder(dir).appendingPathComponent("reader-mode-live-attachment-\(id).png"))
        if let u = chat.transcriptPath, let s = try? String(contentsOfFile: u, encoding: .utf8) {
            // The user lines' shape, with the picture data cut short.
            for line in s.split(separator: "\n") where line.contains("colour is this square") {
                let short = line.replacingOccurrences(of: #"base64,[A-Za-z0-9+/=]{40,}"#, with: "base64,<data>", options: .regularExpression)
                    .replacingOccurrences(of: #""data":"[A-Za-z0-9+/=]{40,}""#, with: "\"data\":\"<data>\"", options: .regularExpression)
                print("      live paste \(id) transcript line: \(short.prefix(1600))")
            }
        }
    }
}
