import AppKit
import PDFKit
import ScreenCaptureKit

/// Test sizes are logical window sizes, independent of the attached display.
private final class LayoutSnapshotWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

extension SelfTest {
    static func flexibleLayout(_ dir: URL) {
        layoutPolicyChecks()
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
        defer { chat.follower?.stop(); terminal.destroy(); window.orderOut(nil); window.close() }
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
    }

    private static func layoutWindowSnapshots(_ root: URL, documents: (pdf: URL, code: URL)) {
        let pdf = documents.pdf
        let code = documents.code
        let sizes = [NSSize(width: 1280, height: 832), NSSize(width: 1470, height: 956),
                     NSSize(width: 1512, height: 982), NSSize(width: 1728, height: 1117),
                     NSSize(width: 2560, height: 1440), NSSize(width: 0, height: 460)]
        var manifest: [[String: Any]] = []
        var renderedCount = 0
        for provider in ["claude", "codex"] {
            guard let (model, chat, mode, terminal) = layoutFixture(root, provider: provider) else { continue }
            let snapshotWindow = LayoutSnapshotWindow(contentRect: layoutSnapshotFrame(NSSize(width: 1320, height: 820)),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            let controller = MainWindowController(model: model, readerMode: mode, review: ReviewCenter(loadSavedState: false), window: snapshotWindow)
            guard let window = controller.window else { terminal.destroy(); continue }
            window.isReleasedWhenClosed = false
            let reader = controller.mainArea.readerMode
            reader.commandDiscoveryEnabled = false
            reader.statusProvider = { _ in nil }
            window.orderFrontRegardless()
            controller.applyInitialWidths()
            controller.mainArea.sync()
            check("layout matrix \(provider): long conversation is ready", waitUntil(10) {
                reader.refresh()
                guard let page = reader.reader?.page, page.ready else { return false }
                return (js(page, "document.querySelectorAll('section.entry').length") as? Int ?? 0) >= 30
            })
            reader.composer.textView.text = "Keep this draft while the panel changes size."
            for size in sizes {
                for dark in (size.width == 1512 || size.width == 1728 ? [false, true] : [false]) {
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    GhosttyApp.shared?.setColorScheme(dark: dark)
                    for face in [ChatFace.reader, .terminal] {
                        if mode.face(of: chat) != face { mode.toggle(chat) }
                        for document in [pdf, code] {
                            model.openFile(document.path, line: nil)
                            _ = waitUntil(5) { controller.panel.code.render(); return controller.panel.code.selectedDoc != nil }
                            for sidebar in [true, false] {
                                for focus in [false, true] {
                                    // Every cell starts from the same preferences. The transition
                                    // checks separately exercise repeated changes without resets.
                                    controller.handleLayoutRequest(.reset)
                                    model.panelVisible = true
                                    model.sidebarVisible = sidebar
                                    controller.handleLayoutRequest(.panel)
                                    if focus { controller.togglePanelFocus() }
                                    controller.mainArea.sync()
                                    controller.applyLayout()
                                    let requested = size.width == 0 ? controller.minimumWindowSize : size
                                    window.setFrame(layoutSnapshotFrame(requested), display: true)
                                    controller.applyLayout()
                                    if controller.effectiveLayout.single && !focus { controller.handleLayoutRequest(.chat) }
                                    window.contentView?.layoutSubtreeIfNeeded()
                                    RunLoop.main.run(until: Date().addingTimeInterval(0.35))
                                    controller.mainArea.layoutTerminals()
                                    let result = controller.effectiveLayout
                                    let name = "layout-\(Int(requested.width))-\(face.rawValue)-\(document == pdf ? "pdf" : "code")-\(provider)-sidebar-\(sidebar ? "open" : "closed")-focus-\(focus ? "on" : "off")-\(dark ? "dark" : "light").png"
                                    let chatWidth = controller.mainItem.isCollapsed ? 0 : controller.mainArea.view.frame.width
                                    let panelWidth = controller.panelItem.isCollapsed ? 0 : controller.panel.view.frame.width
                                    let floor = face == .reader ? WindowLayout.readerMinimum : terminal.minimumWidth(columns: 80)
                                    check("layout frames: " + name, (chatWidth == 0 || chatWidth + 1 >= floor) && (panelWidth == 0 || panelWidth + 1 >= 560) && terminal.measuredColumns >= 80,
                                          "chat=\(chatWidth) panel=\(panelWidth) terminal columns=\(terminal.measuredColumns)")
                                    check("layout window size: " + name, abs(window.frame.width - requested.width) < 1 && abs(window.frame.height - requested.height) < 1,
                                          "actual=\(window.frame.size)")
                                    check("layout coverage: " + name, layoutCoversWindow(controller), "split=\(controller.split.view.frame), panes=\(controller.split.splitView.subviews.map(\.frame))")
                                    var missing: [String] = []
                                    let ready = waitUntil(10) {
                                        missing = layoutMissingContent(controller, chat: chat, face: face, document: document)
                                        return missing.isEmpty
                                    }
                                    check("layout content: " + name, ready, missing.joined(separator: "; "))
                                    let geometryReady = layoutCoversWindow(controller) && abs(window.frame.width - requested.width) < 1 && abs(window.frame.height - requested.height) < 1
                                    check("layout final geometry: " + name, geometryReady, "window=\(window.frame) panes=\(controller.split.splitView.subviews.map(\.frame))")
                                    let captured = ready && geometryReady && captureLayoutWindow(window, to: root.appendingPathComponent(name), pdfInk: layoutPDFRect(controller), textInk: layoutTextRects(controller, face: face))
                                    check("layout snapshot: " + name, captured, ready ? "Window capture or PDF ink verification failed." : missing.joined(separator: "; "))
                                    if captured { renderedCount += 1 }
                                    manifest.append(["file": name, "requestedWidth": requested.width, "requestedHeight": requested.height, "minimumCase": size.width == 0,
                                                     "width": window.frame.width, "height": window.frame.height, "captured": captured, "contentReady": ready, "missing": missing,
                                                     "sidebar": result.sidebar, "chat": chatWidth, "panel": panelWidth,
                                                     "single": result.single, "terminalColumns": terminal.measuredColumns])
                                }
                            }
                        }
                    }
                }
            }
            for face in [ChatFace.reader, .terminal] {
                if mode.face(of: chat) != face { mode.toggle(chat) }
                controller.handleLayoutRequest(.reset)
                model.panelVisible = false
                model.sidebarVisible = true
                controller.mainArea.sync()
                controller.applyLayout()
                let minimum = controller.minimumWindowSize
                window.setFrame(layoutSnapshotFrame(minimum), display: true)
                controller.applyLayout()
                let name = "layout-\(Int(minimum.width))-\(face.rawValue)-none-\(provider)-sidebar-open-focus-off-light.png"
                window.appearance = NSAppearance(named: .aqua)
                GhosttyApp.shared?.setColorScheme(dark: false)
                var missing: [String] = []
                let ready = waitUntil(10) {
                    missing = layoutMissingContent(controller, chat: chat, face: face, document: pdf)
                    return missing.isEmpty && layoutCoversWindow(controller)
                }
                check("layout minimum without panel: " + name,
                      ready && abs(window.frame.width - minimum.width) < 1 && abs(window.frame.height - minimum.height) < 1,
                      missing.joined(separator: "; "))
                let captured = ready && captureLayoutWindow(window, to: root.appendingPathComponent(name), textInk: layoutTextRects(controller, face: face))
                check("layout snapshot: " + name, captured, missing.joined(separator: "; "))
                if captured { renderedCount += 1 }
                manifest.append(["file": name, "requestedWidth": minimum.width, "requestedHeight": minimum.height,
                                 "width": window.frame.width, "height": window.frame.height, "captured": captured,
                                 "minimumCase": true, "panel": 0, "chat": controller.mainArea.view.frame.width,
                                 "terminalColumns": terminal.measuredColumns])
            }
            controller.handleLayoutRequest(.reset)
            if mode.face(of: chat) != .reader { mode.toggle(chat) }
            model.sidebarVisible = true
            model.readerWidth = 560
            model.panelVisible = true
            model.openFile(pdf.path, line: nil)
            window.setFrame(layoutSnapshotFrame(NSSize(width: 1728, height: 1117)), display: true)
            controller.mainArea.sync()
            controller.applyLayout()
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
            chat.follower?.stop()
            terminal.destroy()
            window.orderOut(nil)
            window.close()
        }
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("layout-manifest.json"))
        }
        check("layout: all 260 whole-window combinations were rendered", manifest.count == 260 && renderedCount == 260, "attempted=\(manifest.count) captured=\(renderedCount)")
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

    /// A loaded PDF is insufficient: require text ink inside its page in the actual capture.
    private static func layoutHasInk(_ bitmap: NSBitmapImageRep, rect: NSRect, window: NSWindow, lightText: Bool = false) -> Bool {
        guard let content = window.contentView, content.bounds.width > 0, content.bounds.height > 0 else { return false }
        let sx = CGFloat(bitmap.pixelsWide) / content.bounds.width
        let sy = CGFloat(bitmap.pixelsHigh) / content.bounds.height
        let x0 = max(0, Int((rect.minX - content.bounds.minX) * sx))
        let x1 = min(bitmap.pixelsWide, Int((rect.maxX - content.bounds.minX) * sx))
        let top = content.isFlipped ? rect.minY - content.bounds.minY : content.bounds.maxY - rect.maxY
        let y0 = max(0, Int(top * sy))
        let y1 = min(bitmap.pixelsHigh, Int((top + rect.height) * sy))
        guard x1 > x0, y1 > y0 else { return false }
        var ink = 0
        var background = 0
        for y in stride(from: y0, to: y1, by: 3) {
            for x in stride(from: x0, to: x1, by: 3) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    let text = lightText
                        ? max(color.redComponent, max(color.greenComponent, color.blueComponent)) > 0.65
                        : max(color.redComponent, max(color.greenComponent, color.blueComponent)) < 0.45
                    if text { ink += 1 }
                    let paper = lightText
                        ? max(color.redComponent, max(color.greenComponent, color.blueComponent)) < 0.35
                        : min(color.redComponent, min(color.greenComponent, color.blueComponent)) > 0.75
                    if paper { background += 1 }
                    if ink >= 40 && background >= 100 { return true }
                }
            }
        }
        return false
    }

    /// Capture only this process's scratch window, including the compositor's Metal layer.
    /// There is deliberately no fallback that could pass with a blank terminal surface.
    private static func captureLayoutWindow(_ window: NSWindow, to url: URL, pdfInk: NSRect? = nil, textInk: [(String, NSRect)] = []) -> Bool {
        var complete = false
        var success = false
        var stage = "enumerating current process"
        var captureState = "listed=unknown isOnScreen=unknown isActive=unknown"
        let windowState = "windowID=\(window.windowNumber) frame=\(window.frame) visible=\(window.isVisible) miniaturized=\(window.isMiniaturized) occlusion=\(window.occlusionState.rawValue)"
        func diagnose(_ reason: String, error: Error? = nil) {
            var message = "Layout capture failed: \(url.lastPathComponent) stage=\(stage) \(windowState) \(captureState) reason=\(reason)"
            if let error {
                let native = error as NSError
                message += " errorDomain=\(native.domain) errorCode=\(native.code) description=\(native.localizedDescription) failureReason=\(native.localizedFailureReason ?? "none")"
                if let underlying = native.userInfo[NSUnderlyingErrorKey] as? NSError {
                    message += " underlyingDomain=\(underlying.domain) underlyingCode=\(underlying.code) underlyingDescription=\(underlying.localizedDescription)"
                }
            }
            print(message)
        }
        let task = Task { @MainActor in
            do {
                let content = try await SCShareableContent.currentProcess
                guard !Task.isCancelled else { complete = true; return }
                stage = "looking up window"
                guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                    captureState = "listed=false isOnScreen=unavailable isActive=unavailable enumeratedWindowIDs=\(content.windows.map(\.windowID))"
                    diagnose("Requested window is absent from current-process shareable content.")
                    complete = true
                    return
                }
                captureState = "listed=true isOnScreen=\(target.isOnScreen) isActive=\(target.isActive) targetFrame=\(target.frame)"
                let filter = SCContentFilter(desktopIndependentWindow: target)
                captureState += " filterRect=\(filter.contentRect) pointPixelScale=\(filter.pointPixelScale)"
                stage = "checking filter geometry"
                guard abs(filter.contentRect.width - window.frame.width) < 1,
                      abs(filter.contentRect.height - window.frame.height) < 1 else {
                    diagnose("Filter dimensions differ from the requested window.")
                    complete = true
                    return
                }
                let configuration = SCStreamConfiguration()
                configuration.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
                configuration.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                // Independent-window capture uses the full window bounds. Leave sourceRect
                // unset so an oversized window is not cropped to its visible screen portion.
                captureState += " requestedPixels=\(configuration.width)x\(configuration.height)"
                var missingInk: [String] = []
                let deadline = Date().addingTimeInterval(8)
                for _ in 0..<30 {
                    guard !Task.isCancelled else { complete = true; return }
                    guard Date() < deadline else {
                        diagnose("Capture deadline expired; missing " + missingInk.joined(separator: ", "))
                        complete = true
                        return
                    }
                    stage = "capturing independent window"
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                    guard !Task.isCancelled else { complete = true; return }
                    stage = "checking returned pixels"
                    guard image.width == configuration.width, image.height == configuration.height else {
                        diagnose("Returned pixels \(image.width)x\(image.height) differ from configured dimensions.")
                        complete = true
                        return
                    }
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    let pdfDrawn = pdfInk.map { layoutHasInk(bitmap, rect: $0, window: window) } ?? true
                    missingInk = pdfDrawn ? [] : ["PDF page text"]
                    for (name, rect) in textInk where !layoutHasInk(bitmap, rect: rect, window: window, lightText: dark) {
                        missingInk.append(name + " text")
                    }
                    if missingInk.isEmpty {
                        stage = "encoding PNG"
                        guard let png = bitmap.representation(using: .png, properties: [:]) else {
                            diagnose("PNG encoder returned no data.")
                            complete = true
                            return
                        }
                        stage = "writing PNG"
                        try png.write(to: url)
                        success = true
                        break
                    }
                    stage = "waiting for drawn text"
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                if !success { diagnose("Missing " + missingInk.joined(separator: ", ")) }
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
