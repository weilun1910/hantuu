import AppKit
import PDFKit
import ScreenCaptureKit
import WebKit

/// Test sizes are logical window sizes, independent of the attached display.
private final class LayoutSnapshotWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class LayoutSnapshotLifetime {
    weak var controller: MainWindowController?
    weak var window: NSWindow?
    weak var reader: NSView?
    weak var code: NSView?

    init(_ owner: MainWindowController) {
        controller = owner
        window = owner.window
        reader = owner.mainArea.readerMode.reader?.view
        code = owner.panel.code.page.webView
    }

    var released: Bool { controller == nil && reader == nil && code == nil && window?.isVisible != true }
    var detail: String { "controller=\(controller != nil) reader=\(reader != nil) code=\(code != nil) visibleWindow=\(window?.isVisible == true)" }
}

private struct LayoutInkSamples {
    var rect: NSRect
    var ink = 0
    var background = 0
    var passes: Bool { ink >= 40 && background >= 100 }
    var state: [String: Any] { ["pixelRect": NSStringFromRect(rect), "ink": ink, "background": background, "passes": passes] }
}

private struct LayoutWebPaintEvidence {
    var name: String
    var ready: Bool
    var state: [String: Any]
    var png: Data?
}

extension SelfTest {
    static func flexibleLayout(_ dir: URL) {
        layoutPolicyChecks()
        layoutInkChecks()
        let root = dir.appendingPathComponent("flexible-layout", isDirectory: true)
        Paths.ensure(root)
        let previousData = Paths.dataDir
        Paths.dataDir = root.appendingPathComponent("data", isDirectory: true)
        Paths.ensure(Paths.dataDir)
        defer { Paths.dataDir = previousData }
        let documents = layoutDocuments(root)
        for provider in ["claude", "codex"] {
            compactReaderChecks(root, provider: provider)
            singlePaneTransitionChecks(root, provider: provider, documents: documents)
        }
        if ProcessInfo.processInfo.environment["HANTUU_LAYOUT_SNAPSHOTS"] == "1" {
            layoutWindowSnapshots(root, documents: documents)
        } else {
            print("SKIP  whole-window layout matrix: set HANTUU_LAYOUT_SNAPSHOTS=1 before layout acceptance")
        }
    }

    private static func layoutInkChecks() {
        func sample(background: CGFloat?, foreground: CGFloat?, dark: Bool) -> LayoutInkSamples? {
            guard let context = CGContext(data: nil, width: 128, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.clear(CGRect(x: 0, y: 0, width: 128, height: 64))
            if let background {
                context.setFillColor(CGColor(gray: background, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 128, height: 64))
            }
            if let foreground {
                context.setFillColor(CGColor(gray: foreground, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            }
            guard let image = context.makeImage() else { return nil }
            return layoutInkSamples(NSBitmapImageRep(cgImage: image), pixels: NSRect(x: 0, y: 0, width: 128, height: 64), lightText: dark)
        }
        check("layout pixels: transparent and uniform captures cannot pass as text",
              sample(background: nil, foreground: nil, dark: false)?.passes == false &&
              sample(background: nil, foreground: nil, dark: true)?.passes == false &&
              sample(background: 1, foreground: nil, dark: true)?.passes == false &&
              sample(background: 0, foreground: nil, dark: false)?.passes == false)
        check("layout pixels: foreground over a transparent native backing remains readable",
              sample(background: nil, foreground: 0, dark: false)?.passes == true &&
              sample(background: nil, foreground: 1, dark: true)?.passes == true)
    }

    private static func layoutPolicyChecks() {
        let sizes: [CGFloat] = [760, 1024, 1280, 1470, 1512, 1728, 2560]
        for width in sizes {
            for reader in [false, true] {
                for sidebar in [false, true] {
                    for focused in [false, true] {
                        let input = WindowLayout.Input(width: width, reader: reader, terminalMinimum: 672,
                                                       sidebarWanted: sidebar, focus: focused)
                        let r = WindowLayout.resolve(input)
                        let floor: CGFloat = reader ? 380 : 672
                        let dividers = CGFloat([r.sidebar, r.chat, r.panel].filter { $0 > 0 }.count - 1)
                        let label = "layout policy: \(Int(width)) \(reader ? "reader" : "terminal") sidebar=\(sidebar) focus=\(focused)"
                        check(label, (r.chat == 0 || r.chat >= floor) && (r.panel == 0 || r.panel >= 560) &&
                              abs(r.sidebar + r.chat + r.panel + dividers - width) < 0.01,
                              "sidebar=\(r.sidebar) chat=\(r.chat) panel=\(r.panel)")
                    }
                }
            }
        }
        var input = WindowLayout.Input(width: 1280, reader: true, terminalMinimum: 672)
        let roomy = WindowLayout.resolve(input)
        input.width = 1024
        let compressed = WindowLayout.resolve(input)
        input.width = 1280
        check("layout: growing restores preferences without saving compression", WindowLayout.resolve(input) == roomy && compressed.sidebar == 0)
        input.width = 1230
        input.sidebarWasAutoHidden = true
        check("layout: sidebar restore waits for 64 pt of spare width", WindowLayout.resolve(input).sidebar == 0)
        input.width = 1280
        check("layout: sidebar returns when hysteresis is cleared", WindowLayout.resolve(input).sidebar > 0)
        input.sidebarWanted = false
        check("layout: explicitly hidden navigation stays hidden", WindowLayout.resolve(input).sidebar == 0)
        input = WindowLayout.Input(width: 760, reader: false, terminalMinimum: 672, showPanelWhenSingle: false)
        check("layout: small window can return to a full-width terminal", WindowLayout.resolve(input).chat == 760 && WindowLayout.resolve(input).panel == 0)
        input = WindowLayout.Input(width: 2560, reader: true, terminalMinimum: 672, focus: true)
        check("layout: panel focus uses two thirds of the window", abs(WindowLayout.resolve(input).panel - CGFloat(2560) * 2 / 3) < 0.01)
        check("layout: detents are gentle and Option bypasses them",
              WindowLayout.detent(444, targets: [440, 560, 720]) == 440 &&
              WindowLayout.detent(452, targets: [440, 560, 720]) == 452 &&
              WindowLayout.detent(444, targets: [440, 560, 720], bypass: true) == 444)
        check("layout minimum: reader alone is 380 and a PDF surface alone is 560",
              WindowLayout.minimumWidth(reader: true, terminalMinimum: 672, panelWanted: false, panelMinimum: 560) == 380 &&
              WindowLayout.minimumWidth(reader: true, terminalMinimum: 672, panelWanted: true, panelMinimum: 560) == 560)
        check("layout minimum: list panels allow 380 and the terminal keeps its measured floor",
              WindowLayout.minimumWidth(reader: true, terminalMinimum: 672, panelWanted: true, panelMinimum: 360) == 380 &&
              WindowLayout.minimumWidth(reader: false, terminalMinimum: 672, panelWanted: true, panelMinimum: 560) == 672)
        let listMinimum = WindowLayout.resolve(.init(width: 741, reader: true, terminalMinimum: 672, panelMinimum: 360))
        let documentMinimum = WindowLayout.resolve(.init(width: 941, reader: true, terminalMinimum: 672))
        check("layout minimum: both surfaces fit at 741 for lists and 941 for documents",
              listMinimum.chat == 380 && listMinimum.panel == 360 && listMinimum.sidebar == 0 &&
              documentMinimum.chat == 380 && documentMinimum.panel == 560 && documentMinimum.sidebar == 0)
        let legacy = SavedState.read(Data(#"{"sidebarWidth":248,"panelWidth":742}"#.utf8))
        check("layout: old saved state has no new width requirement", legacy != nil && legacy?.readerWidth == nil && legacy?.terminalWidth == nil)
        let malformed = SavedState.read(Data(#"{"readerWidth":"bad","terminalWidth":672,"panelWidth":742}"#.utf8))
        check("layout: a malformed optional width does not discard the saved layout", malformed?.readerWidth == nil && malformed?.terminalWidth == 672 && malformed?.panelWidth == 742)
        check("layout: PDF/code use content floor and list tabs use compact floor",
              WindowLayout.panelMinimum(for: .code) == 560 && WindowLayout.panelMinimum(for: .files) == 360)
    }

    private static func layoutFixture(_ root: URL, provider: String) -> (AppModel, Chat, ReaderMode, TerminalView)? {
        guard let ghostty = GhosttyApp.shared ?? GhosttyApp.start() else { check("layout: terminal engine", false); return nil }
        let model = AppModel()
        model.transcriptLocations = TranscriptLocations(claude: root, codex: root)
        let project = Project(path: root.path)
        let chat = Chat(projectID: project.id, agentID: provider)
        chat.terminalTitle = "Review the file and keep the conversation open"
        chat.activity = .working
        chat.activityDetail = "Reviewing the layout at this window size"
        let hint = provider == "codex" ? "(press esc to interrupt and send immediately)" : "❯ Press up to edit queued messages"
        let output = "Layout fixture for \(provider)\n\nA real Ghostty surface with synthetic output.\n\n? for shortcuts\nesc to interrupt\n" + hint + "\n"
        let sink = root.appendingPathComponent("layout-input-\(provider).bin")
        let script = "stty raw -echo; printf %s " + ShellEscape.quote(output) + "; exec cat -u > " + ShellEscape.quote(sink.path)
        let terminal = TerminalView(app: ghostty.app, launch: .init(workingDirectory: root.path,
                                    command: "/bin/sh -c " + ShellEscape.quote(script)), handlesChildExit: true)
        chat.terminal = terminal
        let transcript = root.appendingPathComponent("layout-\(provider).jsonl")
        let records: [[String: Any]] = (0..<40).map { index in
            let user = index % 2 == 0
            let role = user ? "user" : "assistant"
            let text = user ? "Explain section \(index / 2 + 1) of the document beside this chat."
                : "The document and conversation can stay open together. This paragraph is long enough to wrap naturally at a compact width.\n\n```swift\nlet availableWidth = window.bounds.width - sidebarWidth - panelWidth\n```\n\nKeep the running agent and the current draft while resizing."
            if provider == "claude" {
                return ["type": role, "uuid": "layout-\(index)", "message": ["role": role, "content": [["type": "text", "text": text]]]]
            }
            return ["type": "response_item", "timestamp": "2026-11-11T12:00:\(String(format: "%02d", index)).000Z",
                    "payload": ["type": "message", "role": role, "content": [["type": user ? "input_text" : "output_text", "text": text]]]]
        }
        let session = "layout-" + provider
        var fixtureRecords = records
        if provider == "codex" {
            fixtureRecords.insert(["type": "session_meta", "payload": ["id": session, "cwd": root.path, "source": "cli"]], at: 0)
        }
        let lines = fixtureRecords.compactMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) }
        try? (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        model.projects = [project]
        model.chats = [chat]
        model.selectedChatID = chat.id
        // Use the same verified identity handoff as a process-owned Codex rollout.
        model.followSession(chat, session: .init(id: session, path: transcript.path), verifiedCodex: provider == "codex")
        chat.discoveryTimer?.invalidate()
        chat.follower?.poll()
        model.readerReload.send(chat.id)
        let settings = ChatSettings(file: root.appendingPathComponent("layout-settings-\(provider).json"))
        settings.showChatsAsReader = true
        return (model, chat, ReaderMode(settings: settings), terminal)
    }

    private static func compactReaderChecks(_ root: URL, provider: String) {
        guard let (model, chat, mode, terminal) = layoutFixture(root, provider: provider) else { return }
        let main = MainAreaController(model: model, mode: mode)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -3000, width: 380, height: 720),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        GhosttyApp.shared?.setColorScheme(dark: false)
        window.contentView = main.view
        window.orderFrontRegardless()
        defer { chat.follower?.stop(); terminal.destroy(); window.orderOut(nil); window.close() }
        let reader = main.readerMode
        reader.commandDiscoveryEnabled = false
        reader.statusProvider = { _ in nil }
        main.sync()
        let ready = waitUntil(10) { reader.refresh(); return reader.reader?.page.ready == true && reader.composerMode.isWorking }
        check("layout \(provider): fixture reader is working at 380 pt", ready)
        let attachment = root.appendingPathComponent("a-long-document-name-to-wrap-in-the-attachment-strip.txt")
        try? "Layout fixture".write(to: attachment, atomically: true, encoding: .utf8)
        reader.composer.setAttachments([ComposerAttachment(url: attachment)])
        reader.composer.textView.text = "Keep this multiline draft while I read the file.\nThe next line must remain editable."
        chat.pendingMessages.enqueue(id: "layout-queued", text: "Check the smaller layout next.", files: [], agentID: provider, existing: chat.allEntries)
        chat.pendingMessages.markSubmitted(id: "layout-queued")
        chat.pendingMessages.queuePaused = true
        for width in [CGFloat(440), 479, 480, 560, 720, 784, 1200, 380] {
            window.setContentSize(NSSize(width: width, height: 720))
            for blocked in [false, true] {
                chat.activity = blocked ? .needsPermission : .working
                chat.activityDetail = blocked ? "Wants to run a command with a long description. Review it in the terminal." : "Reviewing the document"
                main.view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                reader.refresh()
                main.view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                main.layoutTerminals()
                let box = reader.composer
                let frame = box.convert(box.bounds, to: main.view)
                let inset: CGFloat = width < 480 ? 16 : 32
                let expectedWidth = min(720, width - inset * 2)
                check("layout \(provider): composer fills \(Int(width)) pt viewport while blocked=\(blocked)",
                      abs(frame.width - expectedWidth) < 1 && abs(frame.midX - width / 2) < 1,
                      "frame=\(frame) expected width=\(expectedWidth)")
                check("layout \(provider): Send/Stop and attachments stay within the composer",
                      box.bounds.contains(box.action.frame) && box.bounds.contains(box.attach.frame) && !box.action.frame.intersects(box.attach.frame))
                let sections = box.subviews.filter { !$0.isHidden }
                check("layout \(provider): text, attachments and footer stay inside the box without overlap",
                      sections.enumerated().allSatisfy { index, section in
                          box.bounds.insetBy(dx: -0.5, dy: -0.5).contains(section.frame) &&
                          sections.dropFirst(index + 1).allSatisfy { !section.frame.intersects($0.frame) }
                      })
                let controls = reader.deliveryBar.subviews.filter { !$0.isHidden }
                let noOverlap = controls.enumerated().allSatisfy { index, control in
                    reader.deliveryBar.bounds.insetBy(dx: -0.5, dy: -0.5).contains(control.frame) &&
                    controls.dropFirst(index + 1).allSatisfy { !control.frame.intersects($0.frame) }
                }
                check("layout \(provider): delivery actions share one row without clipping or overlap", noOverlap && Set(controls.map { $0.frame.minY }).count <= 1)
                if let agentControls = box.subviews.first(where: { $0 is ComposerAgentControlsView }) {
                    let buttons = agentControls.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }
                    check("layout \(provider): all four model/mode controls remain inside their row",
                          buttons.count == 4 && buttons.allSatisfy { agentControls.bounds.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: agentControls)) })
                    check("layout \(provider): model/mode controls stay in the primary footer row",
                          Set(buttons.map { $0.frame.minY }).count == 1 && buttons.allSatisfy {
                              abs($0.convert($0.bounds, to: box).midY - box.action.frame.midY) < 1 &&
                              $0.toolTip?.isEmpty == false && $0.frame.width >= 18
                          })
                } else { check("layout \(provider): agent controls exist", false) }
                check("layout \(provider): attachment strip stays within its scroll viewport",
                      box.strip.bounds.width <= box.stripScroll.contentView.bounds.width + 1)
                if !blocked, let page = reader.reader?.page {
                    let queueVisible = waitUntil(3) {
                        reader.refresh()
                        return (js(page, "document.querySelectorAll('.send-now').length") as? Int ?? 0) > 0
                    }
                    _ = js(page, "window.scrollTo(0, document.scrollingElement.scrollHeight); 0")
                    check("layout \(provider): Send now remains within the narrow reader", queueVisible &&
                          (js(page, "[...document.querySelectorAll('.send-now')].every(b => { const r=b.getBoundingClientRect(); return r.left>=0 && r.right<=innerWidth; })") as? Bool) == true)
                }
                check("layout \(provider): hidden terminal retains 80 measured columns", terminal.measuredColumns >= 80, "columns=\(terminal.measuredColumns)")
                check("layout \(provider): composer controls fit vertically", reader.bottom.bounds.contains(box.convert(box.bounds, to: reader.bottom)) && reader.bottom.frame.height <= main.view.bounds.height - 40)
                if width == 380 {
                    let name = "layout-380-reader-composer-\(provider)-\(blocked ? "permission" : "working").png"
                    check("layout compact render: \(name)", render(main.view, to: root.appendingPathComponent(name)))
                }
            }
        }
        mode.toggle(chat)
        main.sync()
        main.view.layoutSubtreeIfNeeded()
        check("layout \(provider): terminal face takes its real viewport", abs(terminal.frame.width - main.view.bounds.width) < 1)
    }

    private static func layoutSnapshotFrame(_ size: NSSize) -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: screen.minX + 20, y: screen.minY + 20, width: size.width, height: size.height)
    }

    private static func layoutDocuments(_ root: URL) -> (pdf: URL, code: URL) {
        let pdf = root.appendingPathComponent("layout-document.pdf")
        let code = root.appendingPathComponent("layout-code.swift")
        try? (0..<90).map { "let section\($0) = \"A long code line remains horizontally scrollable in the viewer.\"" }.joined(separator: "\n").write(to: code, atomically: true, encoding: .utf8)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        if let context = CGContext(pdf as CFURL, mediaBox: &mediaBox, nil) {
            for page in 1...4 {
                context.beginPDFPage(nil)
                let graphics = NSGraphicsContext(cgContext: context, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                ("Layout document - page \(page)" as NSString).draw(at: NSPoint(x: 44, y: 720), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black])
                for line in 0..<25 {
                    ("A readable document keeps its page geometry as the panel changes width." as NSString).draw(at: NSPoint(x: 44, y: 670 - line * 22), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.darkGray])
                }
                NSGraphicsContext.restoreGraphicsState()
                context.endPDFPage()
            }
            context.closePDF()
        }
        return (pdf, code)
    }

    private static func singlePaneTransitionChecks(_ root: URL, provider: String, documents: (pdf: URL, code: URL)) {
        guard let (model, chat, mode, terminal) = layoutFixture(root, provider: provider) else { return }
        let window = NSWindow(contentRect: layoutSnapshotFrame(NSSize(width: 1280, height: 832)),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let controller = MainWindowController(model: model, readerMode: mode, review: ReviewCenter(loadSavedState: false), window: window)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { closeLayoutFixture(controller, chat: chat, terminal: terminal) }
        controller.applyInitialWidths()
        let reader = controller.mainArea.readerMode
        reader.commandDiscoveryEnabled = false
        reader.statusProvider = { _ in nil }
        reader.composer.textView.text = "Keep this draft across single-pane transitions."
        for face in [ChatFace.reader, .terminal] {
            if mode.face(of: chat) != face { mode.toggle(chat) }
            for document in [documents.pdf, documents.code] {
                controller.handleLayoutRequest(.reset)
                model.sidebarVisible = true
                model.panelVisible = true
                model.readerWidth = 560
                model.panelWidth = 742
                model.openFile(document.path, line: nil)
                controller.mainArea.sync()
                controller.applyLayout()
                let loaded = waitUntil(5) {
                    controller.panel.code.render()
                    return controller.panel.code.selectedDoc?.path == document.path
                }
                let label = "layout single \(provider) \(face.rawValue) \(document.pathExtension)"
                check(label + ": document selected", loaded)
                guard loaded else { return }
                let originalDocument = controller.panel.code.selectedDoc
                let preferences = [model.sidebarWidth, model.panelWidth, model.readerWidth, model.terminalWidth]
                window.setFrame(layoutSnapshotFrame(NSSize(width: 1280, height: 832)), display: true)
                controller.applyLayout()
                let minimum = controller.minimumWindowSize
                window.setFrame(layoutSnapshotFrame(minimum), display: true)
                controller.applyLayout()
                // Do not reset preferences, recreate the controller, or set another frame
                // during these switches. Native restored-width accumulation must be visible.
                for iteration in 1...12 {
                    for showChat in [true, false] {
                        controller.handleLayoutRequest(showChat ? .chat : .panel)
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                        let stable = waitUntil(3) {
                            window.contentView?.layoutSubtreeIfNeeded()
                            return abs(window.frame.width - minimum.width) < 1 && abs(window.frame.height - minimum.height) < 1 &&
                                controller.sidebarItem.isCollapsed && controller.mainItem.isCollapsed == !showChat &&
                                controller.panelItem.isCollapsed == showChat && layoutCoversWindow(controller)
                        }
                        check(label + ": switch \(iteration) to \(showChat ? "Chat" : "Panel") keeps the exact minimum",
                              stable && preferences == [model.sidebarWidth, model.panelWidth, model.readerWidth, model.terminalWidth] &&
                              reader.composer.textView.string == "Keep this draft across single-pane transitions." &&
                              controller.panel.code.selectedDoc === originalDocument,
                              "requested=\(minimum) actual=\(window.frame.size) effective=\(controller.effectiveLayout) chatCollapsed=\(controller.mainItem.isCollapsed) panelCollapsed=\(controller.panelItem.isCollapsed)")
                        if !stable { return }
                    }
                }
            }
        }
        webContentRecoveryChecks(controller, chat: chat, code: documents.code)
    }

    private static func webContentRecoveryChecks(_ controller: MainWindowController, chat: Chat, code: URL) {
        let model = controller.model
        let reader = controller.mainArea.readerMode
        if reader.mode.face(of: chat) != .reader { reader.mode.toggle(chat) }
        model.openFile(code.path, line: nil)
        model.panelVisible = true
        controller.window?.setFrame(layoutSnapshotFrame(NSSize(width: 1280, height: 832)), display: true)
        controller.mainArea.sync()
        controller.applyLayout()
        guard let page = reader.reader?.page else { check("layout recovery: reader exists", false); return }
        let editor = controller.panel.code
        let loaded = waitUntil(10) {
            editor.render()
            return page.ready && editor.page.ready &&
                (js(page, "document.querySelectorAll('section.entry').length") as? Int ?? 0) >= 40 &&
                (js(editor.page, "!!window.hantuu._view()") as? Bool) == true
        }
        check("layout recovery \(chat.agentID): fixture pages are ready", loaded)
        guard loaded, let document = editor.selectedDoc else { return }
        let token = "layout recovery buffer"
        _ = js(editor.page, "(() => { const v=hantuu._view(); v.dispatch({changes:{from:v.state.doc.length,insert:'\\n// layout recovery buffer\\n'}}); return 0; })()")
        let saved = waitUntil(5) { document.dirty && editor.recoveryStore.read(document.id)?.text.contains(token) == true }
        check("layout recovery \(chat.agentID): unsaved fixture buffer is checkpointed", saved)
        guard saved else { return }
        let draft = reader.composer.textView.string
        let readerTerminations = page.terminationCount
        let editorTerminations = editor.page.terminationCount
        page.webView.navigationDelegate?.webViewWebContentProcessDidTerminate?(page.webView)
        editor.page.webView.navigationDelegate?.webViewWebContentProcessDidTerminate?(editor.page.webView)
        check("layout recovery \(chat.agentID): the actual termination delegate invalidates both pages",
              !page.ready && !editor.page.ready && page.terminationCount == readerTerminations + 1 &&
              editor.page.terminationCount == editorTerminations + 1)
        let restored = waitUntil(10) {
            page.ready && editor.page.ready &&
                (js(page, "document.querySelectorAll('section.entry').length") as? Int ?? 0) >= 40 &&
                (js(editor.page, "hantuu._view()?.state.doc.toString().includes('layout recovery buffer')") as? Bool) == true
        }
        check("layout recovery \(chat.agentID): transcript, unsaved code and draft survive reload",
              restored && reader.composer.textView.string == draft && editor.selectedDoc === document,
              "readerReady=\(page.ready) editorReady=\(editor.page.ready) readerTerminations=\(page.terminationCount) editorTerminations=\(editor.page.terminationCount)")
    }

    private static func layoutWindowSnapshots(_ root: URL, documents: (pdf: URL, code: URL)) {
        let sizes = [NSSize(width: 1280, height: 832), NSSize(width: 1470, height: 956),
                     NSSize(width: 1512, height: 982), NSSize(width: 1728, height: 1117),
                     NSSize(width: 2560, height: 1440), NSSize(width: 0, height: 460)]
        var manifest: [[String: Any]] = []
        var renderedCount = 0
        for provider in ["claude", "codex"] {
            retainedLayoutPaintingChecks(root, provider: provider, documents: documents)
            for size in sizes {
                for dark in (size.width == 1512 || size.width == 1728 ? [false, true] : [false]) {
                    for face in [ChatFace.reader, .terminal] {
                        for document in [documents.pdf, documents.code] {
                            for sidebar in [true, false] {
                                for focus in [false, true] {
                                    let result = autoreleasepool {
                                        layoutSnapshotCell(root, provider: provider, face: face, document: document,
                                            size: size, dark: dark, sidebar: sidebar, focus: focus, panel: true)
                                    }
                                    guard let result else { continue }
                                    manifest.append(result.record)
                                    if result.captured { renderedCount += 1 }
                                    check("layout resources released: " + result.name,
                                          waitUntil(3) { result.lifetime.released }, result.lifetime.detail)
                                }
                            }
                        }
                    }
                }
            }
            for face in [ChatFace.reader, .terminal] {
                let result = autoreleasepool {
                    layoutSnapshotCell(root, provider: provider, face: face, document: documents.pdf,
                        size: NSSize(width: 0, height: 460), dark: false, sidebar: true, focus: false, panel: false)
                }
                guard let result else { continue }
                manifest.append(result.record)
                if result.captured { renderedCount += 1 }
                check("layout resources released: " + result.name,
                      waitUntil(3) { result.lifetime.released }, result.lifetime.detail)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("layout-manifest.json"))
        }
        check("layout: all 260 whole-window combinations were rendered", manifest.count == 260 && renderedCount == 260,
              "attempted=\(manifest.count) captured=\(renderedCount)")
    }

    private static func closeLayoutFixture(_ controller: MainWindowController, chat: Chat, terminal: TerminalView) {
        chat.follower?.stop()
        chat.discoveryTimer?.invalidate()
        terminal.destroy()
        // Stop remote loads and detach the old view tree before the next cell starts.
        let pages: [WebPage?] = [controller.mainArea.readerMode.reader?.page, controller.panel.code.page, controller.panel.side.reader.page]
        for page in pages.compactMap({ $0 }) {
            page.onReady = nil
            page.onMessage = nil
            page.webView.navigationDelegate = nil
            page.webView.stopLoading()
            page.webView.configuration.userContentController.removeScriptMessageHandler(forName: "hantuu")
        }
        controller.window?.orderOut(nil)
        controller.window?.close()
        controller.window?.contentViewController = nil
        controller.window = nil
    }

    private static func presentLayoutWindow(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
    }

    private static func layoutSnapshotCell(_ root: URL, provider: String, face: ChatFace, document: URL,
        size: NSSize, dark: Bool, sidebar: Bool, focus: Bool, panel: Bool)
        -> (name: String, record: [String: Any], captured: Bool, lifetime: LayoutSnapshotLifetime)? {
        guard let (model, chat, mode, terminal) = layoutFixture(root, provider: provider) else { return nil }
        let window = LayoutSnapshotWindow(contentRect: layoutSnapshotFrame(NSSize(width: 1320, height: 820)),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let controller = MainWindowController(model: model, readerMode: mode, review: ReviewCenter(loadSavedState: false), window: window)
        window.isReleasedWhenClosed = false
        defer { closeLayoutFixture(controller, chat: chat, terminal: terminal) }
        let reader = controller.mainArea.readerMode
        reader.commandDiscoveryEnabled = false
        reader.statusProvider = { _ in nil }
        controller.applyInitialWidths()
        if mode.face(of: chat) != face { mode.toggle(chat) }
        model.openFile(document.path, line: nil)
        model.sidebarVisible = sidebar
        model.panelVisible = panel
        if panel { controller.handleLayoutRequest(.panel) }
        if focus { controller.togglePanelFocus() }
        controller.mainArea.sync()
        controller.applyLayout()
        let requested = size.width == 0 ? controller.minimumWindowSize : size
        window.setFrame(layoutSnapshotFrame(requested), display: true)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        GhosttyApp.shared?.setColorScheme(dark: dark)
        controller.applyLayout()
        if controller.effectiveLayout.single && !focus { controller.handleLayoutRequest(.chat) }
        reader.composer.textView.text = "Keep this draft while the panel changes size."
        presentLayoutWindow(window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        controller.mainArea.layoutTerminals()
        let name = "layout-\(Int(requested.width))-\(face.rawValue)-\(panel ? (document.pathExtension == "pdf" ? "pdf" : "code") : "none")-\(provider)-sidebar-\(sidebar ? "open" : "closed")-focus-\(focus ? "on" : "off")-\(dark ? "dark" : "light").png"
        var missing: [String] = []
        let ready = waitUntil(10) {
            missing = layoutMissingContent(controller, chat: chat, face: face, document: document)
            return missing.isEmpty
        }
        check("layout content: " + name, ready, missing.joined(separator: "; "))
        let chatWidth = controller.mainItem.isCollapsed ? 0 : controller.mainArea.view.frame.width
        let panelWidth = controller.panelItem.isCollapsed ? 0 : controller.panel.view.frame.width
        let floor = face == .reader ? WindowLayout.readerMinimum : terminal.minimumWidth(columns: 80)
        check("layout frames: " + name, (chatWidth == 0 || chatWidth + 1 >= floor) &&
              (panelWidth == 0 || panelWidth + 1 >= 560) && terminal.measuredColumns >= 80,
              "chat=\(chatWidth) panel=\(panelWidth) terminal columns=\(terminal.measuredColumns)")
        let geometryReady = layoutCoversWindow(controller) && abs(window.frame.width - requested.width) < 1 && abs(window.frame.height - requested.height) < 1
        check("layout final geometry: " + name, geometryReady,
              "requested=\(requested) window=\(window.frame) effective=\(controller.effectiveLayout)")
        var evidence = prepareLayoutWebPaint(controller, face: face, rasterize: false)
        check("layout WebKit visibility: " + name, evidence.allSatisfy(\.ready),
              evidence.filter { !$0.ready }.map { "\($0.name): \($0.state)" }.joined(separator: "; "))
        let url = root.appendingPathComponent(name)
        let captured = ready && geometryReady && captureLayoutWindow(window, to: url,
            pdfInk: layoutPDFRect(controller), textInk: layoutTextRects(controller, face: face))
        if !captured {
            evidence = prepareLayoutWebPaint(controller, face: face, rasterize: true)
            saveLayoutWebEvidence(evidence, beside: url)
        }
        check("layout snapshot: " + name, captured, ready ? "See compositor and WebKit diagnostic artifacts." : missing.joined(separator: "; "))
        let result = controller.effectiveLayout
        let record: [String: Any] = ["file": name, "requestedWidth": requested.width, "requestedHeight": requested.height,
            "minimumCase": size.width == 0, "width": window.frame.width, "height": window.frame.height,
            "captured": captured, "contentReady": ready, "missing": missing, "sidebar": result.sidebar,
            "chat": chatWidth, "panel": panelWidth, "single": result.single, "terminalColumns": terminal.measuredColumns,
            "webKit": evidence.map { $0.state }]
        return (name, record, captured, LayoutSnapshotLifetime(controller))
    }

    private static func retainedLayoutPaintingChecks(_ root: URL, provider: String, documents: (pdf: URL, code: URL)) {
        guard let (model, chat, mode, terminal) = layoutFixture(root, provider: provider) else { return }
        let window = LayoutSnapshotWindow(contentRect: layoutSnapshotFrame(NSSize(width: 1280, height: 832)),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let controller = MainWindowController(model: model, readerMode: mode, review: ReviewCenter(loadSavedState: false), window: window)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        GhosttyApp.shared?.setColorScheme(dark: false)
        defer { closeLayoutFixture(controller, chat: chat, terminal: terminal) }
        let reader = controller.mainArea.readerMode
        reader.commandDiscoveryEnabled = false
        reader.statusProvider = { _ in nil }
        controller.applyInitialWidths()
        controller.mainArea.sync()
        reader.composer.textView.text = "Keep this draft while the panel changes size."
        let pdf = documents.pdf
        controller.handleLayoutRequest(.reset)
        if mode.face(of: chat) != .reader { mode.toggle(chat) }
        model.sidebarVisible = true
        model.readerWidth = 560
        model.panelVisible = true
        model.openFile(pdf.path, line: nil)
        window.setFrame(layoutSnapshotFrame(NSSize(width: 1728, height: 1117)), display: true)
        controller.mainArea.sync()
        controller.applyLayout()
        _ = waitUntil(5) { controller.panel.code.render(); return controller.panel.code.selectedDoc?.pane is PDFViewer }
        let original = controller.effectiveLayout
        let originalPane = controller.panel.code.selectedDoc?.pane
        controller.togglePanelFocus()
        controller.togglePanelFocus()
        check("layout \(provider): focus restores the exact split and viewer instance",
              controller.effectiveLayout == original && originalPane != nil && controller.panel.code.selectedDoc?.pane === originalPane)
        window.setFrame(layoutSnapshotFrame(NSSize(width: 760, height: 460)), display: true)
        controller.applyLayout()
        window.setFrame(layoutSnapshotFrame(NSSize(width: 1728, height: 1117)), display: true)
        controller.applyLayout()
        check("layout \(provider): temporary compression preserves preferred widths and draft",
              controller.effectiveLayout == original && model.readerWidth == 560 && reader.composer.textView.string.contains("Keep this draft"))
        controller.panel.code.openInNewWindow()
        let detached = controller.panel.code.documentWindows.values.first
        check("layout \(provider): document opens in its own window", detached?.window != nil && detached?.window !== window)
        detached?.window?.performClose(nil)
        check("layout \(provider): closing the document leaves its chat running", chat.terminal === terminal && !terminal.processExited && model.selectedChatID == chat.id)
        let shots = root.appendingPathComponent("retained-painting", isDirectory: true)
        Paths.ensure(shots)
        let phases: [(String, NSSize, Bool, URL)] = [
            ("reader-pdf", NSSize(width: 1280, height: 832), false, documents.pdf),
            ("reader-code", NSSize(width: 1280, height: 832), false, documents.code),
            ("focused-code", NSSize(width: 1280, height: 832), true, documents.code),
            ("resized-code", NSSize(width: 1470, height: 956), false, documents.code),
            ("focused-code-14", NSSize(width: 1512, height: 982), true, documents.code),
            ("restored-reader", NSSize(width: 1728, height: 1117), false, documents.code),
            ("external-code", NSSize(width: 2560, height: 1440), false, documents.code)]
        for (phase, size, focus, document) in phases {
            if mode.face(of: chat) != .reader { mode.toggle(chat) }
            // Hide and restore the same reader, then switch the same file viewer.
            mode.toggle(chat)
            controller.mainArea.sync()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            mode.toggle(chat)
            model.openFile(document.path, line: nil)
            if model.layoutState.focused != focus { controller.togglePanelFocus() }
            window.setFrame(layoutSnapshotFrame(size), display: true)
            controller.mainArea.sync()
            controller.applyLayout()
            presentLayoutWindow(window)
            let ready = waitUntil(10) { layoutMissingContent(controller, chat: chat, face: .reader, document: document).isEmpty }
            let evidence = prepareLayoutWebPaint(controller, face: .reader, rasterize: false)
            let url = shots.appendingPathComponent("layout-paint-\(provider)-\(phase).png")
            let captured = ready && captureLayoutWindow(window, to: url, pdfInk: layoutPDFRect(controller), textInk: layoutTextRects(controller, face: .reader))
            if !captured {
                // Keep the original failure. A later software snapshot is diagnostic and
                // must not repair the baseline used to accept retained-view painting.
                let diagnostic = prepareLayoutWebPaint(controller, face: .reader, rasterize: true)
                saveLayoutWebEvidence(diagnostic, beside: url)
                let retry = layoutDiagnosticFolder(beside: url).appendingPathComponent("after-webkit.png")
                let afterSoftware = ready && captureLayoutWindow(window, to: retry,
                    pdfInk: layoutPDFRect(controller), textInk: layoutTextRects(controller, face: .reader))
                print("layout retained diagnostic \(provider) \(phase): original=false afterSoftwareSnapshot=\(afterSoftware)")
            }
            check("layout retained WebKit \(provider): " + phase, ready && evidence.allSatisfy(\.ready) && captured,
                  "The same views must paint after hide/show, resize, document changes and detached-window focus.")
        }
    }

    private static func layoutWebSurfaces(_ controller: MainWindowController, face: ChatFace) -> [(String, WebPage)] {
        var pages: [(String, WebPage)] = []
        if !controller.mainItem.isCollapsed, face == .reader, let reader = controller.mainArea.readerMode.reader {
            pages.append(("reader", reader.page))
        }
        if !controller.panelItem.isCollapsed, controller.panel.code.selectedDoc?.kind.usesPage == true {
            pages.append(("code", controller.panel.code.page))
        }
        return pages
    }

    /// A software WebKit raster is evidence and a paint request, never a replacement for
    /// the required compositor capture. The two paths must remain distinguishable.
    private static func prepareLayoutWebPaint(_ controller: MainWindowController, face: ChatFace, rasterize: Bool) -> [LayoutWebPaintEvidence] {
        guard let window = controller.window else { return [] }
        presentLayoutWindow(window)
        return layoutWebSurfaces(controller, face: face).map { name, page in
            let view = page.webView
            let nativeVisible = view.window === window && !view.isHiddenOrHasHiddenAncestor &&
                !view.visibleRect.isEmpty && view.alphaValue >= 0.99
            let animationScript = "(() => { const r=(window.__layoutPaintRevision||0)+1; window.__layoutPaintRevision=r; window.__layoutPaintFinished=0; requestAnimationFrame(() => requestAnimationFrame(() => { if (window.__layoutPaintRevision===r) window.__layoutPaintFinished=r; })); return r; })()"
            let revision = js(page, animationScript) as? Int
            let animated = revision.map { expected in waitUntil(3) { (js(page, "window.__layoutPaintFinished") as? Int) == expected } } ?? false
            let diagnosticScript = "(() => { const e=document.querySelector('section.entry p')||document.querySelector('.cm-line'); const r=e?.getBoundingClientRect(); const s=e?getComputedStyle(e):null; return {url:location.href,visibility:document.visibilityState,focused:document.hasFocus(),entries:document.querySelectorAll('section.entry').length,codeLines:document.querySelectorAll('.cm-line').length,firstID:document.querySelector('section.entry')?.dataset.id||null,textRect:r?{x:r.x,y:r.y,width:r.width,height:r.height}:null,color:s?.color||null,background:getComputedStyle(document.body).backgroundColor}; })()"
            var state: [String: Any] = ["name": name, "nativeVisible": nativeVisible,
                "viewFrame": NSStringFromRect(view.frame), "viewBounds": NSStringFromRect(view.bounds),
                "visibleRect": NSStringFromRect(view.visibleRect), "hiddenAncestor": view.isHiddenOrHasHiddenAncestor,
                "alpha": view.alphaValue, "windowKey": window.isKeyWindow, "appActive": NSApp.isActive,
                "occlusion": window.occlusionState.rawValue, "animationFrames": animated,
                "terminationCount": page.terminationCount, "viewIdentity": String(describing: ObjectIdentifier(view)),
                "dom": js(page, diagnosticScript) ?? "No DOM result"]
            state["softwareSnapshotRequested"] = rasterize
            if !rasterize { return LayoutWebPaintEvidence(name: name, ready: nativeVisible && animated, state: state, png: nil) }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = view.bounds
            var image: NSImage?
            var failure: Error?
            var complete = false
            view.takeSnapshot(with: configuration) { result, error in image = result; failure = error; complete = true }
            let finished = waitUntil(5) { complete }
            var png: Data?
            var rasterReady = false
            if finished, let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let bitmap = NSBitmapImageRep(cgImage: cg)
                let sx = CGFloat(bitmap.pixelsWide) / max(1, view.bounds.width)
                let sy = CGFloat(bitmap.pixelsHigh) / max(1, view.bounds.height)
                let pixels = NSRect(x: 8 * sx, y: 8 * sy,
                    width: max(0, CGFloat(bitmap.pixelsWide) - 16 * sx), height: max(0, CGFloat(bitmap.pixelsHigh) - 16 * sy))
                let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let samples = layoutInkSamples(bitmap, pixels: pixels, lightText: dark)
                rasterReady = samples.passes
                state["softwareRaster"] = samples.state
                png = bitmap.representation(using: .png, properties: [:])
            } else {
                state["softwareError"] = failure?.localizedDescription ?? "No WebKit image before timeout"
            }
            state["softwareRasterReady"] = rasterReady
            return LayoutWebPaintEvidence(name: name, ready: nativeVisible && animated && rasterReady, state: state, png: png)
        }
    }

    private static func layoutDiagnosticFolder(beside url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("failed-captures", isDirectory: true)
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    private static func saveLayoutWebEvidence(_ evidence: [LayoutWebPaintEvidence], beside url: URL) {
        let folder = layoutDiagnosticFolder(beside: url)
        Paths.ensure(folder)
        for item in evidence { if let png = item.png { try? png.write(to: folder.appendingPathComponent(item.name + "-webkit.png")) } }
        if let data = try? JSONSerialization.data(withJSONObject: evidence.map(\.state), options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("webkit-state.json"))
        }
    }

    private static func layoutCoversWindow(_ controller: MainWindowController) -> Bool {
        guard let content = controller.window?.contentView else { return false }
        let split = controller.split.splitView
        guard abs(controller.split.view.bounds.width - content.bounds.width) < 1,
              abs(split.bounds.width - content.bounds.width) < 1,
              abs(controller.split.view.bounds.height - content.bounds.height) < 1,
              abs(split.bounds.height - content.bounds.height) < 1 else { return false }
        let panes = [controller.sidebarItem!, controller.mainItem!, controller.panelItem!]
            .filter { !$0.isCollapsed }.map { item -> NSRect in
                let view = item.viewController.view
                return view.convert(view.bounds, to: split)
            }.sorted { $0.minX < $1.minX }
        guard let first = panes.first, let last = panes.last,
              abs(first.minX - split.bounds.minX) < 1,
              abs(last.maxX - split.bounds.maxX) < 1 else { return false }
        guard panes.allSatisfy({ abs($0.minY - split.bounds.minY) < 1 && abs($0.maxY - split.bounds.maxY) < 1 }) else { return false }
        return zip(panes, panes.dropFirst()).allSatisfy { left, right in
            abs(right.minX - left.maxX - split.dividerThickness) < 1
        }
    }

    private static func layoutMissingContent(_ controller: MainWindowController, chat: Chat, face: ChatFace, document: URL) -> [String] {
        let reader = controller.mainArea.readerMode
        reader.refresh()
        controller.panel.sync()
        controller.panel.code.render()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        var missing: [String] = []
        if chat.sessionID == nil || chat.codexIdentityWaiting { missing.append("verified session identity") }
        if !controller.mainItem.isCollapsed {
            if face == .reader {
                if let page = reader.reader?.page, page.ready {
                    let script = "(() => { const entries = [...document.querySelectorAll('section.entry')]; return entries.length >= 40 && entries.some(e => { const r=e.getBoundingClientRect(); return r.width>0 && r.height>0 && r.bottom>0 && r.top<innerHeight; }) && document.body.textContent.includes('The document and conversation can stay open together.'); })()"
                    if (js(page, script) as? Bool) != true { missing.append("rendered reader entries in viewport") }
                    if reader.reader?.view.isHiddenOrHasHiddenAncestor != false { missing.append("visible reader web view") }
                } else { missing.append("reader page ready") }
                let box = reader.composer
                if box.isHiddenOrHasHiddenAncestor || box.bounds.width < 347 || box.bounds.height < 70 ||
                    !reader.bottom.bounds.contains(box.convert(box.bounds, to: reader.bottom)) {
                    missing.append("laid out message box")
                }
            } else if chat.terminal?.geometryIsStable != true || chat.terminal?.activeScreenText().contains("Layout fixture for") != true {
                missing.append("painted terminal fixture")
            }
        }
        if !controller.panelItem.isCollapsed {
            let code = controller.panel.code
            guard let doc = code.selectedDoc, doc.path == document.path else { return missing + ["selected document"] }
            if document.pathExtension == "pdf" {
                if let pane = doc.pane as? PDFViewer, let first = pane.pdf.document?.page(at: 0) {
                    pane.pdf.layoutDocumentView()
                    pane.pdf.go(to: first)
                    pane.pdf.displayIfNeeded()
                    let rect = pane.pdf.convert(first.bounds(for: .mediaBox), from: first).intersection(pane.pdf.bounds)
                    if pane.isHiddenOrHasHiddenAncestor || pane.pdf.scaleFactor <= 0 || rect.isEmpty ||
                        !pane.pdf.visiblePages.contains(where: { $0 === first }) {
                        missing.append("first PDF page laid out")
                    }
                } else { missing.append("loaded PDF document") }
            } else {
                let script = "(() => { const e=document.querySelector('.cm-content'); const line=document.querySelector('.cm-line'); if (!e || !line) return false; const r=line.getBoundingClientRect(); return e.textContent.includes('let section0') && r.width>0 && r.height>0 && r.bottom>0 && r.top<innerHeight; })()"
                if !code.page.ready || code.page.webView.isHiddenOrHasHiddenAncestor || code.page.webView.alphaValue < 0.99 ||
                    (js(code.page, script) as? Bool) != true { missing.append("painted CodeMirror text") }
            }
        }
        return missing
    }

    private static func layoutPDFRect(_ controller: MainWindowController) -> NSRect? {
        guard !controller.panelItem.isCollapsed, let content = controller.window?.contentView,
              let pane = controller.panel.code.selectedDoc?.pane as? PDFViewer,
              let page = pane.pdf.document?.page(at: 0) else { return nil }
        let rect = pane.pdf.convert(page.bounds(for: .mediaBox), from: page).intersection(pane.pdf.bounds).insetBy(dx: 16, dy: 16)
        return rect.isEmpty ? nil : pane.pdf.convert(rect, to: content)
    }

    private static func layoutTextRects(_ controller: MainWindowController, face: ChatFace) -> [(String, NSRect)] {
        guard let content = controller.window?.contentView else { return [] }
        var views: [(String, NSView)] = []
        if !controller.mainItem.isCollapsed {
            if face == .reader, let reader = controller.mainArea.readerMode.reader { views.append(("reader", reader.view)) }
            else if let terminal = controller.model.selectedChat?.terminal { views.append(("terminal", terminal)) }
        }
        if !controller.panelItem.isCollapsed, controller.panel.code.selectedDoc?.kind.usesPage == true {
            views.append(("code", controller.panel.code.page.webView))
        }
        return views.map { name, view in
            (name, view.convert(view.bounds.insetBy(dx: 8, dy: 8), to: content).intersection(content.bounds))
        }
    }

    /// Inspect content-local regions in the actual compositor image, keeping their pixel
    /// coordinates and sample counts available when a capture fails.
    private static func layoutInkSamples(_ bitmap: NSBitmapImageRep, pixels: NSRect, lightText: Bool) -> LayoutInkSamples {
        let x0 = max(0, Int(pixels.minX)), x1 = min(bitmap.pixelsWide, Int(pixels.maxX))
        let y0 = max(0, Int(pixels.minY)), y1 = min(bitmap.pixelsHigh, Int(pixels.maxY))
        var result = LayoutInkSamples(rect: NSRect(x: CGFloat(x0), y: CGFloat(y0),
            width: CGFloat(max(0, x1 - x0)), height: CGFloat(max(0, y1 - y0))))
        guard x1 > x0, y1 > y0 else { return result }
        for y in stride(from: y0, to: y1, by: 3) {
            for x in stride(from: x0, to: x1, by: 3) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    // WebKit software snapshots may leave the native backing transparent.
                    // Composite that alpha before sampling so transparency is never ink.
                    let alpha = color.alphaComponent
                    let backing: CGFloat = lightText ? 0.08 : 0.97
                    let red = color.redComponent * alpha + backing * (1 - alpha)
                    let green = color.greenComponent * alpha + backing * (1 - alpha)
                    let blue = color.blueComponent * alpha + backing * (1 - alpha)
                    let maximum = max(red, max(green, blue))
                    let minimum = min(red, min(green, blue))
                    if lightText ? maximum > 0.65 : maximum < 0.45 { result.ink += 1 }
                    if lightText ? maximum < 0.35 : minimum > 0.75 { result.background += 1 }
                    if result.passes { return result }
                }
            }
        }
        return result
    }

    private static func layoutWindowInk(_ bitmap: NSBitmapImageRep, rect: NSRect, window: NSWindow, lightText: Bool = false) -> LayoutInkSamples {
        guard let content = window.contentView, content.bounds.width > 0, content.bounds.height > 0 else {
            return LayoutInkSamples(rect: .zero)
        }
        let sx = CGFloat(bitmap.pixelsWide) / content.bounds.width
        let sy = CGFloat(bitmap.pixelsHigh) / content.bounds.height
        let top = content.isFlipped ? rect.minY - content.bounds.minY : content.bounds.maxY - rect.maxY
        return layoutInkSamples(bitmap, pixels: NSRect(x: (rect.minX - content.bounds.minX) * sx,
            y: top * sy, width: rect.width * sx, height: rect.height * sy), lightText: lightText)
    }

    /// Capture only this process's scratch window, including the compositor's Metal layer.
    /// There is deliberately no fallback that could pass with a blank terminal surface.
    private static func captureLayoutWindow(_ window: NSWindow, to url: URL, pdfInk: NSRect? = nil, textInk: [(String, NSRect)] = []) -> Bool {
        var complete = false
        var success = false
        var stage = "enumerating current process"
        var captureState = "listed=unknown isOnScreen=unknown isActive=unknown"
        var lastBitmap: NSBitmapImageRep?
        var samples: [[String: Any]] = []
        let windowState = "windowID=\(window.windowNumber) frame=\(window.frame) visible=\(window.isVisible) miniaturized=\(window.isMiniaturized) occlusion=\(window.occlusionState.rawValue)"
        func diagnose(_ reason: String, error: Error? = nil) {
            var message = "Layout capture failed: \(url.lastPathComponent) stage=\(stage) \(windowState) \(captureState) reason=\(reason) samples=\(samples)"
            if let error {
                let native = error as NSError
                message += " errorDomain=\(native.domain) errorCode=\(native.code) description=\(native.localizedDescription) failureReason=\(native.localizedFailureReason ?? "none")"
                if let underlying = native.userInfo[NSUnderlyingErrorKey] as? NSError {
                    message += " underlyingDomain=\(underlying.domain) underlyingCode=\(underlying.code) underlyingDescription=\(underlying.localizedDescription)"
                }
            }
            print(message)
            let folder = layoutDiagnosticFolder(beside: url)
            Paths.ensure(folder)
            if let png = lastBitmap?.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("compositor.png"))
            }
            let state: [String: Any] = ["file": url.lastPathComponent, "stage": stage, "window": windowState,
                "capture": captureState, "reason": reason, "error": error.map { String(describing: $0) } ?? "none", "samples": samples]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("compositor-state.json"))
            }
        }
        let task = Task { @MainActor in
            do {
                let deadline = Date().addingTimeInterval(8)
                var pending = "No matching compositor frame yet."
                for _ in 0..<40 {
                    guard !Task.isCancelled else { complete = true; return }
                    guard Date() < deadline else { diagnose(pending); complete = true; return }
                    // WindowServer geometry can lag setFrame, especially for consecutive
                    // minimum-size windows. Obtain fresh metadata until the frame matches.
                    stage = "enumerating current process"
                    let content = try await SCShareableContent.currentProcess
                    guard !Task.isCancelled else { complete = true; return }
                    stage = "looking up window"
                    guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                        captureState = "listed=false isOnScreen=unavailable isActive=unavailable enumeratedWindowIDs=\(content.windows.map(\.windowID))"
                        pending = "Requested window is absent from current-process shareable content."
                        try await Task.sleep(nanoseconds: 50_000_000)
                        continue
                    }
                    captureState = "listed=true isOnScreen=\(target.isOnScreen) isActive=\(target.isActive) targetFrame=\(target.frame)"
                    let filter = SCContentFilter(desktopIndependentWindow: target)
                    captureState += " filterRect=\(filter.contentRect) pointPixelScale=\(filter.pointPixelScale)"
                    stage = "checking filter geometry"
                    guard abs(filter.contentRect.width - window.frame.width) < 1,
                          abs(filter.contentRect.height - window.frame.height) < 1 else {
                        pending = "WindowServer has not reported the requested dimensions yet."
                        try await Task.sleep(nanoseconds: 50_000_000)
                        continue
                    }
                    let configuration = SCStreamConfiguration()
                    configuration.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
                    configuration.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
                    configuration.showsCursor = false
                    configuration.ignoreShadowsSingleWindow = true
                    captureState += " requestedPixels=\(configuration.width)x\(configuration.height)"
                    stage = "capturing independent window"
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                    guard !Task.isCancelled else { complete = true; return }
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    lastBitmap = bitmap
                    stage = "checking returned pixels"
                    guard image.width == configuration.width, image.height == configuration.height else {
                        diagnose("Returned pixels \(image.width)x\(image.height) differ from configured dimensions.")
                        complete = true
                        return
                    }
                    let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    samples = []
                    var missing: [String] = []
                    if let pdfInk {
                        let result = layoutWindowInk(bitmap, rect: pdfInk, window: window)
                        var state = result.state; state["name"] = "PDF"
                        samples.append(state)
                        if !result.passes { missing.append("PDF page text") }
                    }
                    for (name, rect) in textInk {
                        let result = layoutWindowInk(bitmap, rect: rect, window: window, lightText: dark)
                        var state = result.state; state["name"] = name
                        samples.append(state)
                        if !result.passes { missing.append(name + " text") }
                    }
                    if missing.isEmpty {
                        stage = "encoding PNG"
                        guard let png = bitmap.representation(using: .png, properties: [:]) else {
                            diagnose("PNG encoder returned no data."); complete = true; return
                        }
                        stage = "writing PNG"
                        try png.write(to: url)
                        success = true
                        break
                    }
                    pending = "Capture deadline expired; missing " + missing.joined(separator: ", ")
                    stage = "waiting for drawn text"
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                if !success { diagnose(pending) }
            } catch {
                if !Task.isCancelled { diagnose("ScreenCaptureKit or PNG operation threw.", error: error) }
            }
            complete = true
        }
        let finished = waitUntil(10) { complete }
        if !finished { diagnose("Outer capture timeout."); task.cancel() }
        return finished && success
    }
}
