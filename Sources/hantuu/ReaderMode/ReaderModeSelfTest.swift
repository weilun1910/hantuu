import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Self test for reader mode: the setting and per-chat flips, the message box's state for every
/// agent state, its keys, sending and Stop through a fake agent that records every byte, the
/// banner, peeking at the terminal, and offscreen snapshots in tmp/snapshots/.
///
/// `HANTUU_LIVE_READER_TEST=<folder> scripts/selftest.sh` also runs a real Claude Code chat in
/// that folder (one that Claude Code already trusts): one message through the message box, the
/// reply in the reader, and one Stop. It never answers a trust, update or permission prompt.
extension SelfTest {
    static func readerMode(_ dir: URL) {
        let rdir = dir.appendingPathComponent("reader-mode", isDirectory: true)
        Paths.ensure(rdir)
        readerModeSettings(rdir)
        readerModeLogic()
        readerModeNotices()
        readerModeRestoredInput()
        readerModeKeys()
        readerModeAttachments(rdir)
        readerModeFakeAgent(rdir)
        readerBackgroundQueues(rdir)
        readerModeSnapshots(rdir)
        readerModeRealAgent(rdir)
        attachmentLiveProbe(rdir)
    }

    static func snapshotsFolder(_ dir: URL) -> URL {
        // <worktree>/tmp/selftest/reader-mode -> <worktree>/tmp/snapshots
        dir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("snapshots", isDirectory: true)
    }

    // MARK: The setting and per-chat flips

    static func readerModeSettings(_ dir: URL) {
        let file = dir.appendingPathComponent("chat-settings.json")
        let s = ChatSettings(file: file)
        let p = Project(path: dir.path)
        let a = Chat(projectID: p.id, agentID: "claude")
        let b = Chat(projectID: p.id, agentID: "codex")
        let other = Chat(projectID: p.id, agentID: "gemini")
        check("reader mode: off by default, so chats show their terminal", !s.showChatsAsReader && s.face(for: a) == .terminal && s.face(for: b) == .terminal && !FileManager.default.fileExists(atPath: file.path))

        s.showChatsAsReader = true
        let stored = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any]
        check("reader mode: the switch is stored in chat-settings.json", stored?["showChatsAsReader"] as? Bool == true, "\(String(describing: stored))")
        check("reader mode: on, Claude Code and Codex chats show the reader", s.face(for: a) == .reader && s.face(for: b) == .reader)
        check("reader mode: agents without a transcript keep their terminal", s.face(for: other) == .terminal)
        check("reader mode: the switch survives a relaunch", ChatSettings(file: file).showChatsAsReader)

        s.toggle(a)
        check("per-chat: flipping a chat shows its terminal whatever the setting says", s.face(for: a) == .terminal && s.face(for: b) == .reader)
        s.showChatsAsReader = false
        s.toggle(b)
        check("per-chat: with the setting off, a flipped chat shows the reader", s.face(for: b) == .reader && s.face(for: Chat(projectID: p.id, agentID: "claude")) == .terminal)
        check("per-chat: flips survive a relaunch", ChatSettings(file: file).face(for: b) == .reader)
        s.toggle(b)
        check("per-chat: flipping back to the default forgets the flip", s.flipped[b.id] == nil && s.face(for: b) == .terminal)
        s.forget(except: [b.id])
        check("per-chat: flips of removed chats are dropped", s.flipped.isEmpty, "\(s.flipped)")

        let mode = ReaderMode(settings: s)
        s.showChatsAsReader = true
        mode.peek(a)
        check("peek: a peeking chat shows its terminal for now", !mode.showsReader(a) && mode.face(of: a) == .reader)
        mode.toggle(a)
        check("peek: flipping a chat ends its peek", !mode.isPeeking(a) && mode.face(of: a) == .terminal)

        // The reader lives in the main area only, flipped in place with Shift-Cmd-R.
        check("panel: no Reader tab", PanelTab.allCases.map(\.rawValue) == ["Overview", "Changes", "Files", "Code", "Browser", "Side", "Terminal"])
        let saved = try? JSONDecoder().decode([PanelTab].self, from: Data(#"["Reader", "Changes"]"#.utf8))
        check("panel: a saved Reader tab opens Overview and the rest still loads", saved == [.overview, .changes], "\(String(describing: saved))")
        let item = ReaderModeMenuTarget.toggleItem()
        check("shortcut: Shift-Cmd-R flips the chat", item.keyEquivalent == "r" && item.keyEquivalentModifierMask == [.command, .shift])
    }

    // MARK: The message box's state

    static func readerModeLogic() {
        func m(_ act: AgentActivity, _ detail: String = "", waiting: Bool = false, ready: Bool = true, ended: Bool = false,
               live: Bool = true, menu: ScreenMenu? = nil) -> ComposerMode {
            ComposerMode.resolve(.init(agentName: "Claude Code", ended: ended, live: live, activity: act, detail: detail,
                                       waiting: waiting, ready: ready, screenMenu: menu))
        }
        let perm = m(.needsPermission, "Wants to run Bash: npm test", waiting: true)
        check("banner: Needs permission shows the banner and blocks sending",
              perm == .blocked(title: "Claude Code needs your permission", detail: "Wants to run Bash: npm test") && !perm.canSend, "\(perm)")
        let ask = m(.needsAnswer, "Asks: Tea or coffee?", waiting: true)
        check("banner: a question menu shows the banner and blocks sending",
              ask == .blocked(title: "Claude Code is asking you", detail: "Asks: Tea or coffee?") && !ask.canSend, "\(ask)")
        let final = m(.needsAnswer, "Asks: Shall I commit?")
        check("banner: a question in the final message is answered in the message box", final == .asked(question: "Shall I commit?") && final.canSend, "\(final)")
        let work = m(.working, "Running Bash: swift build")
        check("working: the working line shows the detail, and sending still works", work == .working(detail: "Running Bash: swift build") && work.canSend && work.isWorking)
        check("ready: idle and finished chats can send", m(.idle) == .ready && m(.doneUnseen) == .ready)
        check("ended: no message box", m(.ended) == .none && m(.idle, ended: true) == .none && m(.idle, live: false) == .none)
        check("starting: nothing is sent before the agent draws its prompt", m(.idle, ready: false) == .starting && !ComposerMode.starting.canSend)
        let trust = TerminalScreen.analyze("""
         Claude Code

         Do you trust the files in this folder?

         /Users/test/project

         ❯ 1. Yes, proceed
           2. No, exit

         Enter to confirm · Esc to exit
        """)
        check("screen: a trust prompt is found and blocks sending", trust.menu == ScreenMenu(kind: .trust, line: "Do you trust the files in this folder?")
              && m(.idle, menu: trust.menu).isBlocked, "\(String(describing: trust.menu))")
        let idle = TerminalScreen.analyze("╭──────────────╮\n│ >            │\n╰──────────────╯\n  ? for shortcuts\n")
        check("screen: the agent's idle prompt counts as ready, with no menu", idle.ready && idle.menu == nil)
        let codexIdle = TerminalScreen.analyze("› Ask Codex to do anything\n\n  100% context left · ? for shortcuts")
        check("screen: Codex's prompt counts as ready", codexIdle.ready && codexIdle.menu == nil)
        let modelPicker = "Select Model and Effort\n  1. GPT-6-Astra Frontier model\n› 2. GPT-6-Luna (current) Fast model\n  enter select | esc back"
        let effortPicker = "Select Reasoning Level for GPT-6-Luna\n  1. Low Fast responses\n› 2. Medium (current) Balanced responses\n  enter default | s session | esc back"
        check("screen: Codex model picker uses its real compact footer",
              TerminalScreen.codexPicker(modelPicker) == .model && TerminalScreen.analyze(modelPicker).menu?.kind == .menu)
        check("screen: Codex reasoning picker remains blocked after model selection",
              TerminalScreen.codexPicker(effortPicker) == .reasoning && TerminalScreen.analyze(effortPicker).menu?.kind == .menu)
        check("screen: Codex picker supports a wrapped footer",
              TerminalScreen.codexPicker(modelPicker.replacingOccurrences(of: " | esc back", with: "\n esc back")) == .model)
        check("screen: Codex picker title can be above the normal footer scan",
              TerminalScreen.codexPicker(modelPicker.replacingOccurrences(of: "  1.", with: String(repeating: "  3. Example model\n", count: 20) + "  1.")) == .model)
        check("screen: model names and footer prose alone never identify a picker",
              TerminalScreen.codexPicker("Use GPT-6-Luna. Its picker says enter select and esc back.") == nil &&
              TerminalScreen.codexPicker("Select Model and Effort\nenter select | esc back") == nil)
        check("screen: closing or choosing Codex picker restores the ordinary prompt",
              TerminalScreen.analyze("› Ask Codex to do anything\n? for shortcuts").menu == nil &&
              TerminalScreen.codexPicker(modelPicker + "\n› Ask Codex to do anything\n? for shortcuts") == nil)
        check("screen: Codex picker triggers command auto-peek and blocks late Return",
              ReaderCommandLogic.autoPeek(sentAt: Date(), now: Date(), menu: TerminalScreen.analyze(modelPicker).menu) &&
              ReaderSubmissionGuard.refusal(screen: modelPicker, waiting: false, command: "/model") != nil &&
              ReaderSubmissionGuard.refusal(screen: effortPicker, waiting: false, command: nil) != nil)
        let update = TerminalScreen.analyze("Update available! 0.50.0 -> 0.51.0\n› 1. Update now\n  2. Skip\n")
        check("screen: an update offer blocks sending", update.menu?.kind == .update)
        let old = TerminalScreen.analyze("Do you trust the files in this folder?\n" + (1...30).map { "line \($0) of the answer" }.joined(separator: "\n") + "\n? for shortcuts")
        check("screen: a menu phrase higher up in the output doesn't count", old.menu == nil && old.ready)
        check("message: trimmed, line endings made plain", ComposerMessage.prepare("  \n Explain this \r\n in two lines  \n\n") == "Explain this \n in two lines")
        check("message: an empty box sends nothing", ComposerMessage.prepare(" \n\t ") == nil)
        check("drop: files become shell-escaped paths", ComposerMessage.paths([URL(fileURLWithPath: "/tmp/a b/(1).png"), URL(fileURLWithPath: "/tmp/c.pdf")]) == #"/tmp/a\ b/\(1\).png /tmp/c.pdf"#)
        check("working line: elapsed time", Elapsed.text(since: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 74)) == "1m 14s")
    }

    static func readerModeRestoredInput() {
        let rule = String(repeating: "─", count: 60)
        let msg = "Write a 500-word short story about a lighthouse keeper. Don't use any tools."
        // Claude Code after a stop: the history, then the message back in the box between rules.
        let restored = "❯ Read notes.md\n● It says hi.\n\n\(rule)\n❯ \(msg)\n\(rule)\n  ⏵⏵ auto mode on (shift+tab to cycle)"
        let n = ComposerMessage.restoredLength(screen: restored, sent: [msg])
        check("stop detection: a restored message is recognized without deleting it", n >= msg.unicodeScalars.count && n < msg.unicodeScalars.count + 10, "\(n)")
        let empty = "❯ \(msg)\n● Once upon a time\n\n\(rule)\n❯ \n\(rule)\n  ? for shortcuts"
        check("stop: the same text higher up in the history doesn't count", ComposerMessage.restoredLength(screen: empty, sent: [msg]) == 0)
        let pasted = "\(rule)\n❯ [Pasted text #1 +40 lines]\n\(rule)\n  ? for shortcuts"
        check("stop detection: a restored long paste is recognized", ComposerMessage.restoredLength(screen: pasted, sent: [String(repeating: "x\n", count: 40)]) > 80)
        check("stop: two messages from one turn are both counted",
              ComposerMessage.restoredLength(screen: restored, sent: [msg, "and make it sad"]) >= msg.unicodeScalars.count + 15)
        check("stop: nothing sent this turn, nothing deleted", ComposerMessage.restoredLength(screen: restored, sent: []) == 0)
    }

    static func readerModeNotices() {
        check("notices: Claude's idle reminder isn't kept as a Needs you card",
              AppModel.isIdleNotice("Claude Code Claude is waiting for your input")
              && !AppModel.isIdleNotice("Claude Code Claude needs your permission to use Bash"))
    }

    // MARK: Keys in the message box

    static func keyEvent(_ code: UInt16, _ chars: String, mods: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)
    }

    static func readerModeKeys() {
        let w = makeWindow()
        let tv = ComposerTextView.make()
        tv.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        w.contentView?.addSubview(tv)
        defer { tv.removeFromSuperview() }
        w.makeFirstResponder(tv)
        var sends = 0, escapes = 0
        tv.onSend = { sends += 1 }
        tv.onEscape = { escapes += 1; return true }
        tv.text = "hello"
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        if let e = keyEvent(36, "\r", window: w) { tv.keyDown(with: e) }
        check("keys: Return sends", sends == 1 && tv.string == "hello", "sends=\(sends) text=\(tv.string.debugDescription)")
        if let e = keyEvent(36, "\r", mods: .shift, window: w) { tv.keyDown(with: e) }
        check("keys: Shift-Return adds a new line", sends == 1 && tv.string == "hello\n", tv.string.debugDescription)
        if let e = keyEvent(53, "\u{1b}", window: w) { tv.keyDown(with: e) }
        check("keys: Esc goes to Stop", escapes == 1)
        let box = ComposerBox(frame: NSRect(x: 0, y: 0, width: 400, height: 50))
        let one = box.preferredHeight
        box.textView.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
        box.textView.text = (1...4).map { "line \($0)" }.joined(separator: "\n")
        let four = box.preferredHeight
        box.textView.text = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let many = box.preferredHeight
        let cap = ComposerBox.padTop + ComposerStyle.lineHeight * ComposerStyle.maxLines + ComposerBox.footer
        check("message box: two lines to start, grows with the text, up to a limit",
              abs(one - (ComposerBox.padTop + ComposerStyle.lineHeight * 2 + ComposerBox.footer)) < 0.5 && four > one && many > four && many <= cap + 0.5,
              "one=\(one) four=\(four) many=\(many)")
    }

    // MARK: Pasting and dropping files and pictures

    /// A private pasteboard holding `items`, so the test never touches the clipboard.
    static func testPasteboard(_ items: [NSPasteboardItem]) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("hantuu.selftest.\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects(items)
        return pb
    }

    static func item(_ pairs: [(NSPasteboard.PasteboardType, Data)]) -> NSPasteboardItem {
        let it = NSPasteboardItem()
        for (t, d) in pairs { it.setData(d, forType: t) }
        return it
    }

    static func fileItem(_ url: URL) -> NSPasteboardItem {
        // What Finder's Copy writes: the file URL, its name as text, and its icon as a TIFF.
        let it = NSPasteboardItem()
        it.setString(url.absoluteString, forType: .fileURL)
        it.setString(url.lastPathComponent, forType: .string)
        if let tiff = NSWorkspace.shared.icon(forFile: url.path).tiffRepresentation { it.setData(tiff, forType: .tiff) }
        return it
    }

    static func imageData(_ color: NSColor, width: Int, height: Int, type: UTType) -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hantuu-selftest-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "img")")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        ctx.setFillColor((color.usingColorSpace(.sRGB) ?? color).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let img = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return (try? Data(contentsOf: url)) ?? Data()
    }

    static func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// A drag that's only a pasteboard, for dropping things on views without a real drag.
    final class FakeDrag: NSObject, NSDraggingInfo {
        let pb: NSPasteboard
        let at: NSPoint
        let window: NSWindow
        init(_ pb: NSPasteboard, at: NSPoint, in window: NSWindow) { self.pb = pb; self.at = at; self.window = window }
        var draggingDestinationWindow: NSWindow? { window }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { at }
        var draggedImageLocation: NSPoint { at }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { pb }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    static func readerModeAttachments(_ dir: URL) {
        let files = dir.appendingPathComponent("attach-files", isDirectory: true)
        Paths.ensure(files)
        let shot = files.appendingPathComponent("Screen Shot (1).png")
        let notes = files.appendingPathComponent("notes.pdf")
        let photo = files.appendingPathComponent("IMG_0042.tiff")
        try? imageData(.systemOrange, width: 40, height: 30, type: .png).write(to: shot)
        writeTinyPDF(to: notes, text: "notes")
        try? imageData(.systemTeal, width: 30, height: 20, type: .tiff).write(to: photo)
        let saved = PastedImages.folder
        func savedFiles() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: saved.path)) ?? []).sorted() }

        // What's on the pasteboard, case by case.
        let png = imageData(.systemRed, width: 64, height: 48, type: .png)
        let onlyImage = testPasteboard([item([(.png, png)])])
        // How the box behaved before: a plain-text NSTextView, as it was set up.
        let stock = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        stock.isRichText = false
        stock.importsGraphics = false
        let tookImage = stock.readSelection(from: onlyImage)
        let finderBefore = testPasteboard([fileItem(shot), fileItem(notes)])
        _ = stock.readSelection(from: finderBefore)
        check("before: a plain text box pastes nothing for a picture, and only the names for Finder files",
              !tookImage && stock.string == "Screen Shot (1).png\nnotes.pdf", "\(tookImage) \(stock.string.debugDescription)")
        check("paste: a picture with no file behind it is a picture", ComposerPasteboard.read(onlyImage) == .images([.init(data: png, type: .png)]))
        check("paste: the Paste menu stays on for a picture alone", ComposerPasteboard.hasContent(onlyImage))
        let finder = testPasteboard([fileItem(shot), fileItem(notes)])
        check("paste: files copied in Finder are the files, not their names or icons",
              ComposerPasteboard.read(finder) == .files([shot, notes]), "\(ComposerPasteboard.read(finder))")
        let tiff = imageData(.systemGreen, width: 50, height: 40, type: .tiff)
        let safari = NSPasteboardItem()
        safari.setData(tiff, forType: .tiff)
        safari.setString("https://example.com/cat.jpg", forType: .string)
        check("paste: a copied web image with its address is the picture", ComposerPasteboard.read(testPasteboard([safari])) == .images([.init(data: tiff, type: .tiff)]))
        let cells = NSPasteboardItem()
        cells.setString("a\tb\n1\t2", forType: .string)
        cells.setData(png, forType: .png)
        check("paste: copied cells or slides with a picture of them stay text", ComposerPasteboard.read(testPasteboard([cells])) == .text("a\tb\n1\t2", images: []))
        let pdfData = (try? Data(contentsOf: notes)) ?? Data()
        check("paste: a PDF with no file is a PDF", ComposerPasteboard.read(testPasteboard([item([(.pdf, pdfData)])])) == .pdf(pdfData))
        check("paste: an empty pasteboard is nothing", ComposerPasteboard.read(testPasteboard([])) == .nothing)
        let both = NSPasteboardItem()
        both.setData(png, forType: .png)
        both.setData(tiff, forType: .tiff)
        check("paste: PNG is kept over TIFF when both are there", ComposerPasteboard.read(testPasteboard([both])) == .images([.init(data: png, type: .png)]))

        // Saving pasted pictures.
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let a = ComposerAttachment.make(from: .images([.init(data: png, type: .png)]), now: t0)
        check("saved: a pasted PNG is written as it came, in the data folder's attachments",
              a.count == 1 && a[0].pasted && a[0].url.deletingLastPathComponent().standardizedFileURL == saved.standardizedFileURL
              && a[0].url.pathExtension == "png" && (try? Data(contentsOf: a[0].url)) == png, "\(a.map(\.url.path))")
        check("saved: it's called Pasted image on its chip, and its file is named by time",
              a.first?.label == "Pasted image" && a.first?.url.lastPathComponent.hasPrefix("Pasted ") == true, a.first?.url.lastPathComponent ?? "")
        let b = ComposerAttachment.make(from: .images([.init(data: tiff, type: .tiff)]), existing: a, now: t0.addingTimeInterval(1))
        _ = waitUntil(5) { !b.contains { PastedImages.isPending($0.url) } }
        check("saved: a TIFF becomes a PNG at the same size, and the second is Pasted image 2",
              b.first?.url.pathExtension == "png" && b.first.flatMap { pixelSize($0.url) }.map { $0 == (50, 40) } == true && b.first?.label == "Pasted image 2",
              "\(b.map(\.url.lastPathComponent)) \(String(describing: b.first.flatMap { pixelSize($0.url) }))")
        let c = ComposerAttachment.make(from: .images([.init(data: png, type: .png)]), now: t0)
        let names = [a, b, c].compactMap(\.first?.url.lastPathComponent)
        check("saved: names sort by time, and two in the same second don't clash", names.count == 3 && Set(names).count == 3 && names[0] < names[1], "\(names)")
        let unreadable = ComposerAttachment.make(from: .images([.init(data: Data("nope".utf8), type: .tiff)]))
        let failedImage = unreadable.first.map { attachment in
            if case .failed(let reason) = attachment.preparation { return !reason.isEmpty && attachment.pasted }
            return false
        } ?? false
        check("saved: an unreadable picture remains a failed chip", unreadable.count == 1 && failedImage)
        var unreadableResult: Result<[ComposerMessage.OutgoingFile], ComposerAttachmentTransport.Failure>?
        ComposerAttachmentTransport.prepare(unreadable, agentID: "claude") { _, result in unreadableResult = result }
        if case .some(.failure(_)) = unreadableResult { check("saved: an unreadable picture cannot submit", true) }
        else { check("saved: an unreadable picture cannot submit", false) }

        // A big picture: a 6000 x 4000 TIFF full of noise, the slowest case there is. The chip
        // appears at once and the PNG is written in the background.
        var noise = Data(count: 6000 * 4000 * 4)
        noise.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        let bigTIFF: Data = {
            guard let provider = CGDataProvider(data: noise as CFData),
                  let img = CGImage(width: 6000, height: 4000, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 6000 * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return Data() }
            let d = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(d, UTType.tiff.identifier as CFString, 1, nil) else { return Data() }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
            return d as Data
        }()
        var start = Date()
        let big = ComposerAttachment.make(from: .images([.init(data: bigTIFF, type: .tiff)]))
        let pasteTime = Date().timeIntervalSince(start)
        let written = waitUntil(15) { !big.contains { PastedImages.isPending($0.url) } }
        let convertTime = Date().timeIntervalSince(start)
        let bigPNG = imageData(.systemPurple, width: 6000, height: 4000, type: .png)
        start = Date()
        let bigP = ComposerAttachment.make(from: .images([.init(data: bigPNG, type: .png)]))
        let pngTime = Date().timeIntervalSince(start)
        print(String(format: "      big picture: a %.0f MB TIFF gets its chip in %.2fs and is a PNG %.2fs later; a PNG is saved in %.3fs",
                     Double(bigTIFF.count) / 1e6, pasteTime, convertTime - pasteTime, pngTime))
        check("saved: a 6000 x 4000 picture gets its chip at once and is saved at full size in the background",
              big.count == 1 && bigP.count == 1 && pasteTime < 0.3 && pngTime < 0.3 && written
              && big.first.flatMap { pixelSize($0.url) }.map { $0 == (6000, 4000) } == true,
              String(format: "paste %.2fs convert %.2fs png %.3fs", pasteTime, convertTime, pngTime))
        start = Date()
        let thumb = big.first.flatMap { AttachmentThumbnails.thumbnail($0.url, pixels: 72) }
        check("chips: a big picture's thumbnail is small and quick", thumb.map { max($0.size.width, $0.size.height) <= 72 } == true && Date().timeIntervalSince(start) < 1,
              "\(String(describing: thumb?.size)) \(Date().timeIntervalSince(start))")

        // Clearing out old ones at launch.
        let old = saved.appendingPathComponent("Pasted 2020-01-01 at 10.00.00.png")
        try? png.write(to: old)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: old.path)
        let oldDrop = PastedImages.newFolder(now: Date(timeIntervalSince1970: 0))
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-9 * 24 * 3600)], ofItemAtPath: oldDrop.path)
        let before = savedFiles().count
        let removed = PastedImages.cleanUp()
        check("cleanup: pictures older than a week are deleted at launch, newer ones stay",
              removed == 2 && !FileManager.default.fileExists(atPath: old.path) && !FileManager.default.fileExists(atPath: oldDrop.path)
              && savedFiles().count == before - 2 && FileManager.default.fileExists(atPath: a[0].url.path), "removed=\(removed) \(savedFiles())")

        // The text view: paste from a private pasteboard.
        let box = ComposerBox(frame: NSRect(x: 0, y: 0, width: 720, height: 120))
        let w = makeWindow()
        w.contentView?.addSubview(box)
        defer { box.removeFromSuperview() }
        let tv = box.textView
        let plain = "  keep   this\n\texactly  "
        tv.text = ""
        tv.paste(from: testPasteboard([{ let i = NSPasteboardItem(); i.setString(plain, forType: .string); return i }()]))
        check("paste: plain text goes in exactly as it was, with no attachments", tv.string == plain && box.attachments.isEmpty, tv.string.debugDescription)
        tv.text = "look "
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        let h0 = box.preferredHeight
        tv.paste(from: onlyImage)
        check("paste: a picture becomes a chip, and the text stays as it was",
              box.attachments.count == 1 && box.attachments[0].pasted && tv.string == "look " && box.strip.chips.count == 1, "\(box.attachments) \(tv.string.debugDescription)")
        check("chips: the box grows by a row for them", box.preferredHeight > h0 + ChipStyle.height - 1, "\(h0) -> \(box.preferredHeight)")
        tv.paste(from: finder)
        check("paste: files copied in Finder become chips, not their names", box.attachments.count == 3 && tv.string == "look "
              && box.attachments.suffix(2).map(\.url) == [shot, notes], "\(box.attachments.map(\.label)) \(tv.string.debugDescription)")
        tv.paste(from: finder)
        check("paste: the same file twice is one chip", box.attachments.count == 3)
        if let rtfd = NSAttributedString(attachment: { let t = NSTextAttachment(); t.fileWrapper = FileWrapper(regularFileWithContents: png); t.fileWrapper?.preferredFilename = "figure.png"; return t }()) as NSAttributedString?,
           let rich = { () -> Data? in
               let m = NSMutableAttributedString(string: "See the figure: ")
               m.append(rtfd)
               m.append(NSAttributedString(string: " below"))
               return m.rtfd(from: NSRange(location: 0, length: m.length), documentAttributes: [:])
           }() {
            let it = NSPasteboardItem()
            it.setData(rich, forType: .rtfd)
            it.setString("See the figure: \u{FFFC} below", forType: .string)
            tv.text = ""
            box.setAttachments([])
            tv.paste(from: testPasteboard([it]))
            check("paste: rich text with a picture inside gives the text and a chip for the picture",
                  tv.string == "See the figure:  below" && box.attachments.count == 1 && box.attachments[0].pasted, "\(tv.string.debugDescription) \(box.attachments.count)")
        }
        // Dropping: files from Finder and a picture from a browser become chips; text stays text.
        box.setAttachments([])
        tv.text = ""
        let mid = tv.convert(NSPoint(x: 10, y: 10), to: nil)
        let fileDrop = FakeDrag(testPasteboard([fileItem(shot), fileItem(notes)]), at: mid, in: w)
        check("drop: dragging files over the box offers to copy them", tv.draggingEntered(fileDrop) == .copy)
        let droppedFiles = tv.performDragOperation(fileDrop)
        check("drop: dropped files become chips, not typed paths", droppedFiles && box.attachments.map(\.url) == [shot, notes] && tv.string.isEmpty,
              "\(box.attachments.map(\.label)) \(tv.string.debugDescription)")
        let picDrop = FakeDrag(testPasteboard([item([(.png, png)])]), at: mid, in: w)
        check("drop: a dropped picture with no file becomes a pasted image chip", tv.performDragOperation(picDrop) && box.attachments.count == 3 && box.attachments[2].pasted)
        let textDrop = FakeDrag(testPasteboard([{ let i = NSPasteboardItem(); i.setString("some words", forType: .string); return i }()]), at: mid, in: w)
        check("drop: dropped text is not an attachment", !ComposerPasteboard.dropHasAttachment(textDrop.pb) && box.attachments.count == 3)

        // Removing: the x on a chip, and Backspace in an empty box.
        box.setAttachments([ComposerAttachment(url: shot), ComposerAttachment(url: notes), ComposerAttachment(url: photo)])
        box.layoutSubtreeIfNeeded()
        if let x = box.strip.chips.first?.remove {
            _ = x.accessibilityPerformPress()
        }
        check("chips: the x takes one out", box.attachments.map(\.url) == [notes, photo], "\(box.attachments.map(\.label))")
        check("accessibility: the x reads as Remove and the file's name", box.strip.chips.first?.remove.accessibilityLabel() == "Remove notes.pdf")
        tv.text = ""
        w.makeFirstResponder(tv)
        if let e = keyEvent(51, "\u{7f}", window: w) { tv.keyDown(with: e) }
        check("chips: Backspace in an empty box takes out the last one", box.attachments.map(\.url) == [notes])
        tv.text = "ab"
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        if let e = keyEvent(51, "\u{7f}", window: w) { tv.keyDown(with: e) }
        check("chips: Backspace with text deletes text, not a chip", box.attachments.count == 1 && tv.string == "a", tv.string.debugDescription)
        let many = (1...12).map { ComposerAttachment(url: files.appendingPathComponent("file number \($0) with a fairly long name.txt")) }
        box.setAttachments(many)
        let cap = ChipStyle.height * 3 + ChipStyle.gap * 2
        check("chips: many files wrap, up to three rows, then scroll", abs(box.stripVisibleHeight - cap) < 0.5 && box.strip.contentHeight(width: 696) > cap,
              "\(box.stripVisibleHeight) \(box.strip.contentHeight(width: 696))")
        box.setAttachments([])
        check("chips: none, and the box is its old height again", abs(box.preferredHeight - ComposerBox(frame: .zero).preferredHeight) < 0.5)

        // What gets typed for each agent.
        let img = ComposerMessage.OutgoingFile(path: "/tmp/a b.png", image: true)
        let img2 = ComposerMessage.OutgoingFile(path: "/tmp/c.png", image: true)
        let doc = ComposerMessage.OutgoingFile(path: "/tmp/notes (1).pdf", image: false)
        check("send to Claude Code: each image pasted on its own, then the text after a space, then Return",
              ComposerMessage.steps(text: "what is this?", files: [img, img2], agentID: "claude")
              == [.image(#"/tmp/a\ b.png"#), .image("/tmp/c.png"), .paste(" what is this?"), .pressReturn])
        check("send to Codex: each image pasted on its own (one path per paste), then the text",
              ComposerMessage.steps(text: "what is this?", files: [img, img2], agentID: "codex")
              == [.image(#"/tmp/a\ b.png"#), .image("/tmp/c.png"), .paste("what is this?"), .pressReturn])
        check("send: other files go as their paths after the text",
              ComposerMessage.steps(text: "summarize", files: [doc], agentID: "codex") == [.paste(#"summarize /tmp/notes\ \(1\).pdf"#), .pressReturn])
        check("send: a file on its own doesn't start the message with a slash",
              ComposerMessage.steps(text: nil, files: [doc], agentID: "claude") == [.paste(#" /tmp/notes\ \(1\).pdf"#), .pressReturn])
        check("send: an image on its own is the image and Return",
              ComposerMessage.steps(text: nil, files: [img], agentID: "claude") == [.image(#"/tmp/a\ b.png"#), .pressReturn])
        check("send: agents hantuu doesn't know get every file as a path in the text",
              ComposerMessage.steps(text: "hi", files: ComposerMessage.outgoingFiles([ComposerAttachment(url: shot)], agentID: "gemini"), agentID: "gemini")
              == [.paste("hi " + ShellEscape.escape(shot.path)), .pressReturn])
        check("send: plain text alone is one paste and Return, as before", ComposerMessage.steps(text: "hello", files: [], agentID: "claude") == [.paste("hello"), .pressReturn])
        var converted: [URL] = []
        let out = ComposerMessage.outgoingFiles([ComposerAttachment(url: shot), ComposerAttachment(url: photo), ComposerAttachment(url: notes), ComposerAttachment(url: files)],
                                                agentID: "codex") { converted.append($0); return PastedImages.convert($0) }
        _ = waitUntil(5) { !out.contains { PastedImages.isPending(URL(fileURLWithPath: $0.path)) } }
        check("send: PNG goes as it is, TIFF is converted to PNG first, PDFs and folders go as paths",
              out.map(\.image) == [true, true, false, false] && out[0].path == shot.path && converted == [photo]
              && out[1].path.hasSuffix("IMG_0042.png") && out[1].path.hasPrefix(saved.path) && pixelSize(URL(fileURLWithPath: out[1].path)).map { $0 == (30, 20) } == true,
              "\(out)")
        // How each agent records a message sent with a pasted image (shapes from Claude Code
        // 2.1.322 and Codex 0.167.1), and what the reader shows for it.
        let pixel = "iVBORw0KGgo="
        var claudeParser = ClaudeTranscriptParser()
        let claudeLine = #"{"type":"user","uuid":"u9","message":{"role":"user","content":[{"type":"text","text":"[Image #1] What colour is this square?"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(pixel)"}}]},"imagePasteIds":[1]}"#
        let ce = claudeParser.parse(line: Data(claudeLine.utf8))
        check("reader: a Claude Code message with a pasted image shows its text and the image",
              ce.count == 1 && ce[0].kind == .user && ce[0].text == "[Image #1] What colour is this square?" && ce[0].images == ["data:image/png;base64,\(pixel)"], "\(ce)")
        var codexParser = CodexTranscriptParser()
        let codexLine = #"{"timestamp":"2026-11-11T16:31:20.717Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<image name=[Image #1] path=\"/tmp/attachments/Pasted 2026-11-11 at 11.31.19.png\">"},{"type":"input_image","image_url":"data:image/png;base64,\#(pixel)","detail":"high"},{"type":"input_text","text":"</image>"},{"type":"input_text","text":"[Image #1] What colour is this square?"}]}}"#
        let xe = codexParser.parse(line: Data(codexLine.utf8))
        check("reader: a Codex message with a pasted image shows its text and the image, without Codex's image tags",
              xe.count == 1 && xe[0].text == "[Image #1] What colour is this square?" && xe[0].images == ["data:image/png;base64,\(pixel)"], "\(xe)")
        check("screen: image chips are counted at the bottom of the agent's screen",
              ComposerMessage.imageMarks("❯ [Image #1] earlier\n" + String(repeating: "x\n", count: 20) + "──────\n❯ [Image #4] [Image #5]what\n──────\n  ? for shortcuts") == 2)
    }

    // MARK: Sending, Stop and the banner, through a fake agent

    /// A "chat" whose program shows an idle prompt line, turns on bracketed paste and records
    /// every byte it gets.
    static func recordingTerminal(_ g: GhosttyApp, dir: URL, file: URL, acknowledgeImageBytes: Int? = nil) -> TerminalView {
        try? FileManager.default.removeItem(at: file)
        let recording: String
        if let count = acknowledgeImageBytes {
            recording = "dd bs=1 count=\(count) of=\(ShellEscape.quote(file.path)) 2>/dev/null; printf '[Image #1]\\n  ? for shortcuts\\n'; exec cat -u >> \(ShellEscape.quote(file.path))"
        } else {
            recording = "exec cat -u > \(ShellEscape.quote(file.path))"
        }
        let script = "stty -icanon -icrnl -echo min 1 time 0; printf '\\033[?2004h'; printf '  ? for shortcuts\\n'; " + recording
        return TerminalView(app: g.app, launch: .init(workingDirectory: dir.path, command: "/bin/sh -c \(ShellEscape.quote(script))"), handlesChildExit: true)
    }

    /// Two independent byte sinks prove a hidden chat keeps its own transport and timer.
    static func readerBackgroundQueues(_ dir: URL) {
        guard let ghostty = GhosttyApp.shared ?? GhosttyApp.start() else { check("background queue: libghostty", false); return }
        for provider in ["claude", "codex"] {
            let settings = ChatSettings(file: dir.appendingPathComponent("background-" + provider + ".json"))
            settings.showChatsAsReader = true
            let mode = ReaderMode(settings: settings)
            let app = AppModel()
            app.transcriptLocations = TranscriptLocations(claude: dir, codex: dir)
            let project = Project(path: dir.path)
            let owner = Chat(projectID: project.id, agentID: provider)
            let other = Chat(projectID: project.id, agentID: provider)
            owner.sessionID = "fixture-owner"
            other.sessionID = "fixture-other"
            let ownerFile = dir.appendingPathComponent("background-" + provider + "-owner.bin")
            let otherFile = dir.appendingPathComponent("background-" + provider + "-other.bin")
            let a = recordingTerminal(ghostty, dir: dir, file: ownerFile)
            let b = recordingTerminal(ghostty, dir: dir, file: otherFile)
            owner.terminal = a; other.terminal = b
            app.projects = [project]; app.chats = [owner, other]; app.selectedChatID = owner.id
            let window = NSWindow(contentRect: NSRect(x: -6000, y: -4000, width: 900, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
            window.contentView = host
            a.frame = host.bounds; b.frame = host.bounds
            host.addSubview(a); host.addSubview(b)
            let controller = ReaderModeController(model: app, mode: mode, commandCatalog: ReaderCommandCatalog(home: dir))
            controller.commandDiscoveryEnabled = false
            controller.statusProvider = { _ in nil }
            controller.install(in: host, top: host.topAnchor, above: b)
            window.orderFrontRegardless()
            defer {
                owner.terminal = nil; other.terminal = nil
                a.destroy(); b.destroy(); window.orderOut(nil)
            }
            controller.sync(selected: owner)
            guard waitUntil(10, { controller.refresh(); return controller.composerMode == .ready && TerminalScreen.analyze(b.activeScreenText()).ready }) else {
                check("background queue: \(provider) fixture is ready", false); continue
            }
            func ownerBytes() -> Data { (try? Data(contentsOf: ownerFile)) ?? Data() }
            func acknowledge(_ text: String) {
                let entry = ReaderEntry(id: UUID().uuidString, kind: .user, text: text)
                owner.liveEntries.append(entry)
                _ = owner.pendingMessages.reconcile([entry])
            }
            owner.activity = .working
            controller.refresh()
            controller.composer.textView.text = "first background message"
            let first = controller.send()
            controller.composer.textView.text = "second background message"
            let second = controller.send()
            check("queue default: \(provider) Return retains editable queued bubbles without terminal input",
                  first && second && owner.pendingMessages.entries.allSatisfy { $0.pendingState == "Queued" && $0.pendingActions?.contains("edit") == true } && ownerBytes().isEmpty)
            mode.toggle(other)
            app.selectedChatID = other.id
            controller.sync(selected: other)
            controller.composer.textView.text = "Other chat draft"
            check("background queue: \(provider) switching to a terminal does not pause waiting input",
                  first && second && !owner.pendingMessages.queuePaused && owner.pendingMessages.entries.count == 2 && ownerBytes().isEmpty)
            owner.activity = .idle
            let delivered = waitUntil(6) { ownerBytes().contains(0x0D) && !controller.isTyping }
            let firstBytes = String(decoding: ownerBytes(), as: UTF8.self)
            check("background queue: \(provider) timer submits only to the hidden owner",
                  delivered && firstBytes == "\u{1b}[200~first background message\u{1b}[201~\r" &&
                  ((try? Data(contentsOf: otherFile)) ?? Data()).isEmpty && controller.composer.textView.string == "Other chat draft")
            acknowledge("first background message")
            owner.activity = .needsPermission
            controller.refresh()
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            check("background queue: \(provider) permission wait holds remaining input without pausing the queue",
                  ownerBytes().count == firstBytes.utf8.count && !owner.pendingMessages.queuePaused)
            owner.activity = .idle
            app.selectedChatID = nil
            controller.sync(selected: nil)
            let next = waitUntil(6) { String(decoding: ownerBytes(), as: UTF8.self).hasSuffix("second background message\u{1b}[201~\r") && !controller.isTyping }
            check("background queue: \(provider) continues with no selected chat", next && !owner.pendingMessages.queuePaused)
            acknowledge("second background message")

            app.selectedChatID = owner.id
            controller.sync(selected: owner)
            controller.composer.textView.text = "switch during delayed return"
            let before = ownerBytes().count
            let sending = controller.send()
            app.selectedChatID = other.id
            controller.sync(selected: other)
            let finished = waitUntil(5) { !controller.isTyping && ownerBytes().last == 0x0D }
            check("background queue: \(provider) switching during a paste preserves its delayed Return",
                  sending && finished && String(decoding: ownerBytes().dropFirst(before), as: UTF8.self) == "\u{1b}[200~switch during delayed return\u{1b}[201~\r" &&
                  !owner.pendingMessages.queuePaused && ((try? Data(contentsOf: otherFile)) ?? Data()).isEmpty)
            acknowledge("switch during delayed return")

            app.selectedChatID = owner.id
            controller.sync(selected: owner)
            controller.composer.textView.text = "background session replacement"
            let replacementMark = ownerBytes().count
            let started = controller.send()
            app.selectedChatID = other.id
            controller.sync(selected: other)
            owner.sessionID = "replacement-session"
            let refused = waitUntil(5) { !controller.isTyping }
            check("background queue: \(provider) still cancels delayed Return after session replacement",
                  started && refused && !ownerBytes().dropFirst(replacementMark).contains(0x0D) && owner.pendingMessages.inputNeedsReview)
        }
    }

    static func readerModeFakeAgent(_ dir: URL) {
        guard let g = GhosttyApp.shared ?? GhosttyApp.start() else { check("reader mode: libghostty", false); return }
        let settings = ChatSettings(file: dir.appendingPathComponent("fake-chat-settings.json"))
        settings.showChatsAsReader = true
        let mode = ReaderMode(settings: settings)
        let model = AppModel()
        let project = Project(path: dir.path)
        model.projects = [project]
        let chat = Chat(projectID: project.id, agentID: "claude")
        let sent = dir.appendingPathComponent("sent.bin")
        let tv = recordingTerminal(g, dir: dir, file: sent)
        chat.terminal = tv
        model.chats = [chat]
        model.selectedChatID = chat.id

        let w = NSWindow(contentRect: NSRect(x: -6000, y: -4000, width: 900, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        w.contentView = host
        tv.frame = host.bounds
        host.addSubview(tv)
        let rm = ReaderModeController(model: model, mode: mode, commandCatalog: ReaderCommandCatalog(home: dir))
        rm.commandDiscoveryEnabled = false
        var statusOverride: StatusState?
        rm.statusProvider = { _ in statusOverride }
        rm.install(in: host, top: host.topAnchor, above: tv)
        w.orderFrontRegardless()
        defer {
            tv.destroy()
            w.orderOut(nil)
        }
        let layout = rm.sync(selected: chat)
        check("reader mode: the main area shows the reader over the chat's terminal", layout.showsReader && !rm.root.isHidden && rm.reader != nil)
        let ready = waitUntil(10) { rm.refresh(); return rm.composerMode == .ready }
        check("reader mode: the message box is ready once the agent's prompt is up", ready, "\(rm.composerMode) screen=\(tv.activeScreenText().suffix(120).debugDescription)")
        _ = waitUntil(10) { rm.reader?.page.ready == true }

        // Keyboard: the terminal's focus request lands in the message box, and the reader page
        // never takes the keyboard.
        w.makeFirstResponder(rm.focusTarget(for: tv))
        check("focus: asking for the chat's terminal gives the keyboard to the message box", w.firstResponder === rm.composer.textView)
        if let wv = rm.reader?.page.webView {
            // A real click on the reader, through the window, the way AppKit hands out focus.
            let p = wv.convert(NSPoint(x: wv.bounds.midX, y: wv.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { w.sendEvent(e) }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            check("focus: clicking the reader keeps the keyboard in the message box", !wv.acceptsFirstResponder && w.firstResponder === rm.composer.textView,
                  "firstResponder=\(String(describing: w.firstResponder))")
            _ = w.makeFirstResponder(wv)
            check("focus: the reader page never becomes the first responder", w.firstResponder !== wv)
            w.makeFirstResponder(nil)
            (wv as? FocuslessWebView)?.onMouseDown?()
            check("focus: a click on the reader puts the keyboard back in the message box", w.firstResponder === rm.composer.textView)
            _ = rm.reader?.interaction.message(["type": "focusRequested"])
            check("focus: explicit reader controls can still take keyboard focus", wv.acceptsFirstResponder)
            (wv as? FocuslessWebView)?.onMouseDown?()
            check("focus: an ordinary click releases a prior control's keyboard focus", !wv.acceptsFirstResponder && w.firstResponder === rm.composer.textView)
        }

        func bytes() -> Data { (try? Data(contentsOf: sent)) ?? Data() }
        func reviewInputForNextScenario() {
            // This byte-recording fixture has no editable input buffer. Simulate the explicit
            // user review action between independent scenarios, never an automatic reset.
            let beforeReview = bytes().count
            _ = rm.perform(NSSelectorFromString("reviewedInputPressed"))
            check("recovery: explicit Input reviewed unlocks without sending", !chat.pendingMessages.inputNeedsReview && bytes().count == beforeReview)
        }
        // Send: one bracketed paste, then a real Return.
        rm.composer.textView.text = "Explain the build script\nin two lines  \n\n"
        let ok = rm.send()
        let arrived = waitUntil(5) { bytes().last == 0x0D }
        let first = String(decoding: bytes(), as: UTF8.self)
        check("send: the message goes in as one bracketed paste, then Return", ok && arrived && first == "\u{1b}[200~Explain the build script\nin two lines\u{1b}[201~\r", first.debugDescription)
        check("send: the message box empties", rm.composer.textView.string.isEmpty)
        // The same through the keyboard: Return in the box.
        rm.composer.textView.text = "second message"
        if let e = keyEvent(36, "\r", window: w) { rm.composer.textView.keyDown(with: e) }
        _ = waitUntil(5) { String(decoding: bytes(), as: UTF8.self).hasSuffix("second message\u{1b}[201~\r") }
        check("send: Return in the message box sends it", String(decoding: bytes(), as: UTF8.self).hasSuffix("\u{1b}[200~second message\u{1b}[201~\r"), String(decoding: bytes(), as: UTF8.self).debugDescription)

        // Commands use literal key text. All discovery roots here are in the fixture folder.
        let commandMark = bytes().count
        rm.composer.textView.text = "/model example-model"
        let commandSent = rm.send()
        let commandArrived = waitUntil(5) { !rm.isTyping && bytes().count > commandMark && bytes().last == 0x0D }
        check("commands transport: the command token stays outside the argument paste", commandSent && commandArrived && String(decoding: bytes().suffix(from: commandMark), as: UTF8.self) == "/model \u{1b}[200~example-model\u{1b}[201~\r")
        check("commands peek: an inline model argument keeps the reader", !mode.isPeeking(chat))
        let bareCommandMark = bytes().count
        rm.composer.textView.text = "/model"
        _ = rm.send()
        let bareArrived = waitUntil(5) { !rm.isTyping && bytes().count > bareCommandMark && bytes().last == 0x0D }
        check("commands mirror: submission waits for menu evidence before revealing terminal", bareArrived && !mode.isPeeking(chat))
        check("commands transport: a bare command sends exactly one Return", String(decoding: bytes().suffix(from: bareCommandMark), as: UTF8.self) == "/model\r")
        _ = rm.sync(selected: chat)
        w.makeFirstResponder(rm.focusTarget(for: tv))
        check("commands mirror: a fake agent with no menu keeps composer focus", w.firstResponder === rm.composer.textView)
        rm.refresh()
        check("commands mirror: a calm prompt stays in the reader", !mode.isPeeking(chat))
        _ = rm.sync(selected: chat)
        w.makeFirstResponder(rm.focusTarget(for: tv))
        check("commands peek: focus returns to the message box", w.firstResponder === rm.composer.textView)
        let longMark = bytes().count
        let arguments = String(repeating: "context ", count: 200).trimmingCharacters(in: .whitespaces)
        rm.composer.textView.text = "/compact " + arguments
        _ = rm.send()
        let longArrived = waitUntil(5) { !rm.isTyping && bytes().count > longMark && bytes().last == 0x0D }
        check("commands transport: long arguments cannot swallow the command name", longArrived && String(decoding: bytes().suffix(from: longMark), as: UTF8.self) == "/compact \u{1b}[200~" + arguments + "\u{1b}[201~\r")

        let multilineMark = bytes().count
        let multilineArguments = "Preserve the conversation token.\nKeep the summary brief."
        rm.composer.textView.text = "/compact " + multilineArguments
        _ = rm.send()
        let multilineArrived = waitUntil(5) { !rm.isTyping && bytes().count > multilineMark && bytes().last == 0x0D }
        check("commands transport: multiline compact arguments use one text paste and one submit",
              multilineArrived && String(decoding: bytes().suffix(from: multilineMark), as: UTF8.self) == "/compact \u{1b}[200~" + multilineArguments + "\u{1b}[201~\r")

        let namespaceMark = bytes().count
        rm.composer.textView.text = "/example:task_name detail"
        _ = rm.send()
        let namespaceArrived = waitUntil(5) { !rm.isTyping && bytes().count > namespaceMark && bytes().last == 0x0D }
        check("commands transport: namespaces and underscores remain literal key text", namespaceArrived && String(decoding: bytes().suffix(from: namespaceMark), as: UTF8.self) == "/example:task_name \u{1b}[200~detail\u{1b}[201~\r")

        // Attachments: the image's path as its own paste, then the text with the PDF's path.
        // The fake agent never draws "[Image #1]", so don't wait long for it.
        rm.imageWait = 0.3
        let shot = dir.appendingPathComponent("shot one.png")
        let pdf = dir.appendingPathComponent("notes (1).pdf")
        try? imageData(.systemBlue, width: 20, height: 20, type: .png).write(to: shot)
        writeTinyPDF(to: pdf, text: "notes")
        rm.composer.add([ComposerAttachment(url: shot), ComposerAttachment(url: pdf)])
        check("send: attachments alone are enough to send", rm.composer.action.kind == .send && rm.composer.action.active)
        rm.composer.textView.text = "what are these"
        let mark = bytes().count
        let sentFiles = rm.send()
        let gotFiles = waitUntil(8) { !rm.isTyping && bytes().count > mark }
        let typedFiles = String(decoding: bytes().suffix(from: mark), as: UTF8.self)
        let failedImage = chat.pendingMessages.entries.last
        check("send: image timeout stops before text, PDF or Return",
              sentFiles && gotFiles && typedFiles == "\u{1b}[200~" + ShellEscape.escape(shot.path) + "\u{1b}[201~", typedFiles.debugDescription)
        check("send: failed image retains recoverable text and attachments",
              failedImage.map { chat.pendingMessages.stage(id: $0.id) == .failed && chat.pendingMessages.recovery(id: $0.id)?.attachments.map(\.url) == [shot, pdf] } == true)
        check("send: accepted input moves from composer into recoverable pending state", rm.composer.attachments.isEmpty && rm.composer.textView.string.isEmpty && rm.composer.stripScroll.isHidden)
        check("send: partial image failure requires input review", chat.pendingMessages.inputNeedsReview)
        let lockedBytes = bytes().count
        rm.composer.textView.text = "must wait for review"
        check("send: locked input refuses another send and retains draft", !rm.send() && bytes().count == lockedBytes && rm.composer.textView.string == "must wait for review")
        rm.composer.textView.text = ""
        reviewInputForNextScenario()
        // Conversion succeeds independently of native acknowledgement. A missing image chip
        // must still prevent Return after the converted file path has been pasted.
        let tiffFile = dir.appendingPathComponent("scan.tiff")
        try? imageData(.systemGray, width: 2400, height: 1600, type: .tiff).write(to: tiffFile)
        rm.composer.add([ComposerAttachment(url: tiffFile)])
        let mark3 = bytes().count
        rm.send()
        _ = waitUntil(8) { !rm.isTyping && bytes().count > mark3 }
        let typedTIFF = String(decoding: bytes().suffix(from: mark3), as: UTF8.self)
        let pngPath = ShellEscape.escape(PastedImages.folder.path)
        check("send: TIFF conversion writes a PNG but unconfirmed image never submits",
              typedTIFF.hasPrefix("\u{1b}[200~" + pngPath) && typedTIFF.hasSuffix("scan.png\u{1b}[201~") && !typedTIFF.contains("\r"), typedTIFF.debugDescription)
        reviewInputForNextScenario()
        // The fake terminal deliberately has no image acknowledgement. Use text-only input
        // for this independent serialized transport check.
        let mark2 = bytes().count
        rm.composer.textView.text = "first"
        rm.send()
        rm.composer.textView.text = "second"
        rm.send()
        _ = waitUntil(8) { String(decoding: bytes().suffix(from: mark2), as: UTF8.self).hasSuffix("second\u{1b}[201~\r") && !rm.isTyping }
        let two = String(decoding: bytes().suffix(from: mark2), as: UTF8.self)
        check("send: a second message waits for the first to finish typing",
              two == "\u{1b}[200~first\u{1b}[201~\r\u{1b}[200~second\u{1b}[201~\r", two.debugDescription)
        check("send: idle sends remain pending until transcript acknowledgement", chat.pendingMessages.entries.contains { $0.text == "second" })
        // Permission state can change between a paste and its delayed Return.
        let permissionMark = bytes().count
        rm.composer.textView.text = "late permission fixture"
        let permissionStarted = rm.send()
        chat.activity = .needsPermission
        chat.activityDetail = "A permission dialog appeared during submission"
        let permissionStopped = waitUntil(5) { !rm.isTyping }
        check("send: late permission state cancels delayed Return and locks partial input",
              permissionStarted && permissionStopped && chat.pendingMessages.inputNeedsReview && !bytes().suffix(from: permissionMark).contains(0x0D))
        let permissionPending = chat.pendingMessages.entries.last
        check("send: late permission keeps recoverable original text", permissionPending?.text == "late permission fixture" && permissionPending.map { chat.pendingMessages.stage(id: $0.id) == .failed } == true)
        chat.activity = .idle
        chat.activityDetail = ""
        rm.refresh()
        reviewInputForNextScenario()

        // A native /resume or fork can change identity during the same delayed submission.
        let oldSession = chat.sessionID
        let sessionMark = bytes().count
        rm.composer.textView.text = "session replacement fixture"
        let sessionStarted = rm.send()
        chat.sessionID = "fixture-replacement-session"
        let sessionStopped = waitUntil(5) { !rm.isTyping }
        check("send: native session change cancels Return without replay",
              sessionStarted && sessionStopped && chat.pendingMessages.inputNeedsReview && !bytes().suffix(from: sessionMark).contains(0x0D))
        check("send: native session change retains failed input", chat.pendingMessages.entries.last.map { $0.text == "session replacement fixture" && chat.pendingMessages.stage(id: $0.id) == .failed } == true)
        chat.sessionID = oldSession
        rm.refresh()
        reviewInputForNextScenario()
        // Isolate the following queue scenario. This is a fixture reset, not app Stop behavior.
        chat.pendingMessages.removeAll()
        // Each chat keeps its own attachments.
        let other = Chat(projectID: project.id, agentID: "claude")
        other.terminal = tv
        model.chats = [chat, other]
        rm.composer.add([ComposerAttachment(url: pdf)])
        model.selectedChatID = other.id
        rm.sync(selected: other)
        let otherEmpty = rm.composer.attachments.isEmpty
        model.selectedChatID = chat.id
        rm.sync(selected: chat)
        check("chats: each chat keeps its own attachments", otherEmpty && rm.composer.attachments.map(\.url) == [pdf])
        rm.composer.setAttachments([])
        model.chats = [chat]
        // Dropping a file anywhere on the reader puts it in the message box.
        if let wv = rm.reader?.page.webView as? FocuslessWebView {
            let drop = FakeDrag(testPasteboard([fileItem(shot)]), at: wv.convert(NSPoint(x: wv.bounds.midX, y: wv.bounds.midY), to: nil), in: w)
            let took = wv.draggingEntered(drop) == .copy && wv.performDragOperation(drop)
            check("drop: a file dropped on the reader goes into the message box", took && rm.composer.attachments.map(\.url) == [shot])
            rm.composer.setAttachments([])
        }

        // A busy send appears before its transcript arrives, and keeps its chat ownership.
        chat.activity = .working
        rm.refresh()
        rm.composer.textView.text = "queued reader thought"
        let queuedSend = rm.send(intent: .steer)
        check("queue send: a busy send immediately creates a pending bubble", queuedSend && chat.pendingMessages.entries.first?.text == "queued reader thought")
        if let id = chat.pendingMessages.entries.first?.id {
            check("send now: cannot interrupt a message that is still being pasted", !rm.sendNow(chatID: chat.id, id: id))
        }
        _ = waitUntil(5) { !rm.isTyping }
        model.chats = [chat, other]
        model.selectedChatID = other.id
        rm.sync(selected: other)
        check("queue send: switching chats preserves the waiting message", chat.pendingMessages.entries.count == 1 && other.pendingMessages.isEmpty)
        let queuedEntry = ReaderEntry(id: "queued-delivered", kind: .user, text: "queued reader thought")
        chat.liveEntries.append(queuedEntry)
        model.readerAppend.send((chat.id, chat.pendingMessages.reconcile([queuedEntry])))
        model.selectedChatID = chat.id
        rm.sync(selected: chat)
        check("queue send: delivery while another chat is selected clears the pending state", chat.pendingMessages.isEmpty)
        model.chats = [chat]

        // Stop during a delayed paste cancels Return and preserves a recoverable copy.
        rm.composer.textView.text = "cancel before return"
        let cancelMark = bytes().count
        _ = rm.send(intent: .steer)
        let cancelled = rm.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        check("queue send: Stop retains input and cancels the delayed Return",
              cancelled && chat.pendingMessages.entries.contains { $0.text == "cancel before return" && (chat.pendingMessages.stage(id: $0.id) == .failed || chat.pendingMessages.stage(id: $0.id) == .unconfirmed) }
              && !rm.isTyping && !bytes().suffix(from: cancelMark).contains(0x0D))
        chat.activity = .idle
        rm.refresh()

        reviewInputForNextScenario()
        // Stop: Esc, only while working.
        let before = bytes().count
        check("stop: does nothing while the agent isn't working", rm.stop() == false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        check("stop: no Esc sent then", bytes().count == before)
        chat.activity = .working
        chat.activityDetail = "Running Bash: swift build"
        rm.refresh()
        check("working: the working line shows the detail", rm.composerMode == .working(detail: "Running Bash: swift build") && !rm.statusHost.isHidden && rm.status.mode.isWorking)
        check("stop: the send button turns into Stop while the box is empty", rm.composer.action.kind == .stop)
        check("accessibility: the button reads as Stop", rm.composer.action.isAccessibilityElement() && rm.composer.action.accessibilityRole() == .button
              && rm.composer.action.accessibilityLabel() == "Stop Claude Code", rm.composer.action.accessibilityLabel() ?? "nil")
        rm.composer.textView.text = "queued thought"
        check("stop: it's Send again once there's text to send", rm.composer.action.kind == .send && rm.composer.action.active)
        check("accessibility: the button reads as Send, and the paperclip as Add Files", rm.composer.action.accessibilityLabel() == "Send"
              && rm.composer.action.isAccessibilityEnabled() && rm.composer.attach.accessibilityRole() == .button
              && (rm.composer.attach.accessibilityLabel() ?? "").hasPrefix("Add files"))
        rm.composer.textView.text = ""
        let stopped = rm.stop()
        check("stop: sends Esc to the terminal", stopped && waitUntil(5) { bytes().count == before + 1 && bytes().last == 0x1B }, bytes().suffix(8).map { String(format: "%02x", $0) }.joined(separator: " "))
        // The half-second refresh may already have seen that fake screen go quiet and ended the
        // turn; start a fresh one so the key press below always meets a working agent.
        chat.activity = .idle
        rm.refresh()
        chat.activity = .working
        rm.refresh()
        if let e = keyEvent(53, "\u{1b}", window: w) { rm.composer.textView.keyDown(with: e) }
        check("stop: Esc in the message box stops a working agent", waitUntil(5) { bytes().count == before + 2 && bytes().last == 0x1B })
        // The fake agent's screen shows its prompt and no "esc to interrupt", like Claude Code
        // after a stop that its status never reported.
        rm.refresh()
        check("stop: once the screen shows the turn stopped, the working line goes even if the status lags",
              rm.composerMode == .ready && chat.activity == .working, "\(rm.composerMode)")
        check("screen: a running turn is seen on screen", TerminalScreen.analyze("✻ Thinking… (esc to interrupt)\n> \n  ? for shortcuts").busy
              && !TerminalScreen.analyze("> \n  ? for shortcuts").busy)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check("stop: nothing is deleted when the agent's box doesn't show what was sent", !bytes().suffix(from: before).contains(0x7F))
        let beforeBS = bytes().count
        tv.pressBackspace(times: 3)
        check("stop: Backspace reaches the terminal as DEL", waitUntil(5) { bytes().count == beforeBS + 3 && bytes().suffix(3).allSatisfy { $0 == 0x7F } },
              bytes().suffix(4).map { String(format: "%02x", $0) }.joined(separator: " "))

        // End the preceding stopped-turn scenario before testing permission banners.
        chat.activity = .idle
        rm.refresh()
        reviewInputForNextScenario()
        // The banner: a permission prompt is waiting.
        chat.activity = .needsPermission
        chat.activityDetail = "Wants to run Bash: npm test"
        statusOverride = nil
        rm.refresh()
        check("banner: appears for Needs permission, with the detail", rm.composerMode == .blocked(title: "Claude Code needs your permission", detail: "Wants to run Bash: npm test")
              && !rm.statusHost.isHidden && rm.statusHost.frame.height >= 0)
        let held = bytes().count
        rm.composer.textView.text = "this must not reach a menu"
        let refused = rm.send() == false
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        check("banner: nothing is sent while the prompt waits, and the text stays", refused && bytes().count == held && rm.composer.textView.string == "this must not reach a menu")
        chat.activity = .needsAnswer
        chat.activityDetail = "Asks: Tea or coffee?"
        rm.refresh()
        check("banner: appears for a question menu too", rm.composerMode == .blocked(title: "Claude Code is asking you", detail: "Asks: Tea or coffee?"))
        statusOverride = StatusState()   // nothing in waits: the question is in its final message
        rm.refresh()
        check("asked: a final question is answered in the message box", rm.composerMode == .asked(question: "Tea or coffee?") && rm.composerMode.canSend)
        statusOverride = nil

        // Show Terminal: the live terminal comes up, and the reader returns once it carries on.
        chat.activity = .needsPermission
        chat.activityDetail = "Wants to run Bash: npm test"
        rm.refresh()
        rm.showTerminal()
        let peek = rm.sync(selected: chat)
        check("peek: Show Terminal swaps the live terminal in", peek.peeking && !peek.showsReader && rm.root.isHidden && !rm.peekBar.isHidden)
        rm.focusComposer()
        check("peek: the terminal keeps the keyboard while it's up", rm.focusTarget(for: tv) === tv)
        chat.activity = .working
        chat.activityDetail = "Running Bash: npm test"
        rm.refresh()
        rm.refresh()
        let back = rm.sync(selected: chat)
        check("peek: the reader comes back once the agent carries on", !back.peeking && back.showsReader && !mode.isPeeking(chat))

        // Ended: the reader stays, without the message box.
        chat.status = .ended
        chat.activity = .ended
        rm.refresh()
        check("ended: no message box, room for the Resume bar", rm.composerMode == .none && rm.composer.isHidden && rm.focusTarget(for: tv) == nil)
        chat.status = .running
    }

    // MARK: Snapshots

    static func snapshotTranscript(_ url: URL, project: String) {
        func line(_ o: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) }
        func user(_ id: String, _ text: String) -> String { line(["type": "user", "uuid": id, "message": ["role": "user", "content": text]]) }
        func text(_ id: String, _ t: String) -> String { line(["type": "assistant", "uuid": id, "message": ["role": "assistant", "content": [["type": "text", "text": t]]]]) }
        func tool(_ id: String, _ tid: String, _ name: String, _ input: [String: Any]) -> String {
            line(["type": "assistant", "uuid": id, "message": ["role": "assistant", "content": [["type": "tool_use", "id": tid, "name": name, "input": input]]]])
        }
        func result(_ id: String, _ tid: String, _ out: String) -> String {
            line(["type": "user", "uuid": id, "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": tid, "content": out]]]])
        }
        let lines = [
            user("u1", "Why does the build fail on a clean checkout?"),
            tool("a1", "t1", "Bash", ["command": "swift build", "description": "Build the package"]),
            result("r1", "t1", "error: vendor/GhosttyKit.xcframework not found"),
            tool("a2", "t2", "Read", ["file_path": project + "/Package.swift"]),
            result("r2", "t2", "// swift-tools-version: 6.2"),
            tool("a3", "t3", "Grep", ["pattern": "GhosttyKit", "path": project]),
            result("r3", "t3", "Package.swift"),
            text("a4", """
            The build fails because `vendor/GhosttyKit.xcframework` isn't there on a clean checkout. `Package.swift` points at it as a binary target:

            ```swift
            .binaryTarget(name: "GhosttyKit", path: "vendor/GhosttyKit.xcframework")
            ```

            It's made by `scripts/build-libghostty.sh`, which downloads Zig and the Ghostty source. Run it once and the build works. The first run takes a few minutes, and later builds skip it.
            """),
            user("u2", "Can you make build.sh say that, instead of failing with a linker error?"),
            tool("a5", "t5", "Edit", ["file_path": project + "/scripts/build.sh", "old_string": "set -e", "new_string": "set -e"]),
            result("r5", "t5", "ok"),
            text("a6", "Done. `scripts/build.sh` now stops early with a plain message when the framework is missing:\n\n```bash\nif [ ! -d vendor/GhosttyKit.xcframework ]; then\n  echo \"Run scripts/build-libghostty.sh first.\" >&2\n  exit 1\nfi\n```"),
        ]
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func readerModeSnapshots(_ dir: URL) {
        guard let g = GhosttyApp.shared ?? GhosttyApp.start() else { return }
        let out = snapshotsFolder(dir)
        Paths.ensure(out)
        Theme.configure(from: g)
        ActivityDot.fixedPhase = 0.45
        let shared = ChatSettings.shared
        let wasOn = shared.showChatsAsReader
        shared.showChatsAsReader = true
        defer {
            ActivityDot.fixedPhase = nil
            shared.showChatsAsReader = wasOn
        }

        let projectDir = dir.appendingPathComponent("hantuu", isDirectory: true)
        Paths.ensure(projectDir.appendingPathComponent("scripts"))
        try? "// swift-tools-version: 6.2\n".write(to: projectDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try? "#!/bin/bash\n".write(to: projectDir.appendingPathComponent("scripts/build.sh"), atomically: true, encoding: .utf8)
        let model = AppModel()
        let project = Project(path: projectDir.path)
        model.projects = [project]
        let chat = Chat(projectID: project.id, agentID: "claude")
        chat.terminalTitle = "Clean checkout build"
        let transcript = dir.appendingPathComponent("snapshot-transcript.jsonl")
        snapshotTranscript(transcript, project: projectDir.path)
        let f = TranscriptFollower(url: transcript, kind: .claude, baseDir: projectDir.path)
        f.poll()
        chat.follower = f
        chat.transcriptPath = transcript.path
        let tv = recordingTerminal(g, dir: dir, file: dir.appendingPathComponent("snapshot-sent.bin"))
        chat.terminal = tv
        model.chats = [chat]
        model.selectedChatID = chat.id

        let main = MainAreaController(model: model)
        let w = NSWindow(contentRect: NSRect(x: -7000, y: -4000, width: 960, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = main.view
        main.view.frame = NSRect(x: 0, y: 0, width: 960, height: 720)
        w.orderFrontRegardless()
        defer {
            tv.destroy()
            w.orderOut(nil)
        }
        let rm = main.readerMode
        main.sync()
        _ = waitUntil(10) { rm.reader?.page.ready == true }
        let ready = waitUntil(10) { rm.refresh(); return rm.composerMode == .ready }
        check("snapshot: reader mode is the main area for the chat", ready && !rm.root.isHidden, "\(rm.composerMode)")
        _ = waitUntil(5) { (js(rm.reader!.page, "document.querySelectorAll('section.entry').length") as? Int ?? 0) > 3 }
        w.makeFirstResponder(rm.composer.textView)

        func shot(_ name: String) -> Bool {
            main.sync()
            main.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            return render(main.view, to: out.appendingPathComponent(name))
        }
        let idle = shot("reader-mode-idle.png")
        // The same view in light mode: the window chrome, the composer and the page's CSS.
        if let page = rm.reader?.page {
            w.appearance = NSAppearance(named: .aqua)
            g.setColorScheme(dark: false)
            let lightText = waitUntil(5) { (js(page, "getComputedStyle(document.body).color") as? String) == "rgb(43, 43, 43)" }
            check("reader page: switches to light colours with the app", lightText, js(page, "getComputedStyle(document.body).color") as? String ?? "")
            _ = shot("reader-mode-idle-light.png")
            w.appearance = NSAppearance(named: .darkAqua)
            g.setColorScheme(dark: true)
            _ = waitUntil(5) { (js(page, "getComputedStyle(document.body).color") as? String) == "rgb(227, 227, 227)" }
        }
        if let page = rm.reader?.page {
            let summary = js(page, "(document.querySelector('.toolgroup .sumtext') || {}).textContent || ''") as? String ?? ""
            check("reader page: a run of tool calls folds into one summary line", summary == "Ran a command, read a file and 1 more", summary)
            let rel = js(page, "Array.from(document.querySelectorAll('.toolrows a.path')).map(a => a.textContent).join('|')") as? String ?? ""
            check("reader page: paths in the chat's folder read relative to it", rel.contains("Package.swift") && !rel.contains("/"), rel)
            let lang = js(page, "Array.from(document.querySelectorAll('.codeblock .codehead .lang')).map(l => l.textContent).join('|')") as? String ?? ""
            check("reader page: code blocks get a header with the language", lang == "swift|bash", lang)
            let bubble = js(page, "getComputedStyle(document.querySelector('.entry.user')).alignItems + '|' + getComputedStyle(document.querySelector('.entry.user > .label')).display") as? String ?? ""
            check("reader page: your messages are bubbles on the right, without a label", bubble == "flex-end|none", bubble)
            _ = js(page, "document.querySelector('.toolgroup .toolsum').click(); 0")
            let opened = js(page, "document.querySelector('.toolgroup').classList.contains('open') && getComputedStyle(document.querySelector('.toolgroup .toolrows')).display === 'block'") as? Bool ?? false
            check("reader page: clicking the summary shows the steps", opened)
            _ = js(page, "document.scrollingElement.scrollTop = 0; 0")
            _ = shot("reader-mode-steps-open.png")
            _ = js(page, "document.scrollingElement.scrollTop = document.scrollingElement.scrollHeight; 0")
            _ = js(page, "document.querySelector('.toolgroup .toolsum').click(); 0")
        }

        // The message box with attachments: one pasted picture, then several files with a long
        // name, in dark and light. The crops show just the bottom of the window.
        let attachDir = dir.appendingPathComponent("snapshot-files", isDirectory: true)
        Paths.ensure(attachDir)
        let photo = attachDir.appendingPathComponent("Pasted image.png")
        writeGradient(to: photo, width: 1200, height: 800)
        let diagram = attachDir.appendingPathComponent("architecture-diagram.png")
        writeGradient(to: diagram, width: 900, height: 900, warm: true)
        let pdf = attachDir.appendingPathComponent("Lecture 7 - Fourier series and the heat equation (annotated).pdf")
        writeTinyPDF(to: pdf, text: "Lecture 7")
        let csv = attachDir.appendingPathComponent("results.csv")
        try? "a,b\n1,2\n".write(to: csv, atomically: true, encoding: .utf8)
        func attachShots(_ name: String, _ list: [ComposerAttachment], text: String) -> Bool {
            rm.composer.setAttachments(list)
            rm.composer.textView.text = text
            rm.refresh()
            var ok = true
            for (suffix, dark) in [("", true), ("-light", false)] {
                w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                g.setColorScheme(dark: dark)
                if let page = rm.reader?.page {
                    let want = dark ? "rgb(227, 227, 227)" : "rgb(43, 43, 43)"
                    _ = waitUntil(5) { (js(page, "getComputedStyle(document.body).color") as? String) == want }
                }
                let file = out.appendingPathComponent("\(name)\(suffix).png")
                ok = shot("\(name)\(suffix).png") && ok
                cropBottom(file, height: 210, to: out.appendingPathComponent("composer-\(name.replacingOccurrences(of: "reader-mode-", with: ""))\(suffix).png"))
            }
            w.appearance = NSAppearance(named: .darkAqua)
            g.setColorScheme(dark: true)
            return ok
        }
        let oneImage = attachShots("reader-mode-attach-image", [ComposerAttachment(url: photo, pasted: true, label: "Pasted image")], text: "What's wrong with this layout?")
        let several = attachShots("reader-mode-attach-several", [
            ComposerAttachment(url: photo, pasted: true, label: "Pasted image"),
            ComposerAttachment(url: diagram),
            ComposerAttachment(url: pdf),
            ComposerAttachment(url: csv),
            ComposerAttachment(url: attachDir),
        ], text: "")
        check("snapshot: the message box with one picture, and with several files and a long name, in dark and light", oneImage && several)
        check("snapshot: literal multiline command with image draft in both appearances",
              attachShots("composer-command-multiline", [ComposerAttachment(url: photo)], text: "/plan Review this image\nDescribe the smallest useful change."))
        rm.composer.setAttachments([])
        rm.composer.textView.text = ""
        _ = waitUntil(3) { (js(rm.reader!.page, "getComputedStyle(document.body).color") as? String) == "rgb(227, 227, 227)" }

        chat.activity = .working
        chat.activityDetail = "Running Bash: swift build"
        chat.activitySince = Date().addingTimeInterval(-14)
        rm.refresh()
        let working = shot("reader-mode-working.png")
        for (name, stage, detail) in [
            ("held", PendingReaderMessages.Stage.waiting, "Paused for review"),
            ("unconfirmed", PendingReaderMessages.Stage.unconfirmed, "Delivery was not acknowledged. Check the terminal before restoring."),
            ("failed", PendingReaderMessages.Stage.failed, "The image was not confirmed. Restore the input to retry."),
        ] {
            let id = "snapshot-" + name
            chat.pendingMessages.removeAll()
            chat.pendingMessages.enqueue(id: id, text: "Check the keyboard flow after this turn", files: [], agentID: "claude", existing: chat.allEntries, stage: stage, sessionID: chat.sessionID)
            chat.pendingMessages.update(id: id, stage: stage, detail: detail)
            chat.pendingMessages.queuePaused = true
            chat.pendingMessages.inputNeedsReview = stage != .waiting
            model.readerAppend.send((chat.id, chat.pendingMessages.entries))
            rm.refresh()
            let rendered = attachShots("reader-mode-" + name + "-queue-draft", [ComposerAttachment(url: pdf)], text: "Keep this draft while I review the queued message.")
            check("snapshot: " + name + " queue, delivery controls and draft render in both appearances", rendered)
            // Remove the fixture bubble before the next distinct state capture.
            _ = js(rm.reader!.page, "document.querySelector('section.entry[data-id=\"" + id + "\"]')?.remove(); 0")
        }
        chat.pendingMessages.removeAll()
        chat.pendingMessages.queuePaused = false
        chat.pendingMessages.inputNeedsReview = false
        rm.composer.textView.text = ""
        rm.composer.setAttachments([])

        chat.activity = .needsPermission
        chat.activityDetail = "Wants to run Bash: npm test"
        rm.refresh()
        let needs = shot("reader-mode-needs-permission.png")

        chat.status = .ended
        chat.activity = .ended
        chat.activityDetail = "Ended"
        rm.refresh()
        let ended = shot("reader-mode-ended.png")
        chat.status = .running

        // A message that arrives live fades in, and is fully shown afterwards even here, where
        // the offscreen window may not run animations.
        model.readerAppend.send((chat.id, [ReaderEntry(id: "live-1", kind: .assistant, text: "Arrived while you were reading.")]))
        let shownLive = waitUntil(5) { (js(rm.reader!.page, "(() => { const e = document.querySelector('section.entry[data-id=\"live-1\"]'); return !!e && !e.classList.contains('fresh') && getComputedStyle(e).opacity === '1'; })()") as? Bool) == true }
        check("reader page: a message that arrives live ends up fully shown", shownLive)

        let form = NSHostingView(rootView: Form { ChatSettingsSection() }.formStyle(.grouped).environment(\.colorScheme, .dark))
        form.appearance = NSAppearance(named: .darkAqua)
        form.frame = NSRect(x: 0, y: 0, width: 520, height: 140)
        w.contentView?.addSubview(form)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let settingsShot = render(form, to: out.appendingPathComponent("reader-mode-settings.png"))
        form.removeFromSuperview()
        check("snapshot: reader mode idle, working, needs permission, ended and its setting in \(out.path)", idle && working && needs && ended && settingsShot)
    }

    /// A soft two-colour gradient, so a chip's thumbnail looks like a real picture.
    static func writeGradient(to url: URL, width: Int, height: Int, warm: Bool = false) {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let a = warm ? NSColor(srgbRed: 0.96, green: 0.80, blue: 0.62, alpha: 1) : NSColor(srgbRed: 0.42, green: 0.62, blue: 0.86, alpha: 1)
        let b = warm ? NSColor(srgbRed: 0.72, green: 0.38, blue: 0.40, alpha: 1) : NSColor(srgbRed: 0.90, green: 0.92, blue: 0.95, alpha: 1)
        if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        ctx.setFillColor(NSColor(white: 1, alpha: 0.85).cgColor)
        ctx.fill(CGRect(x: width / 6, y: height / 5, width: width / 2, height: height / 9))
        guard let img = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    /// The bottom `height` points of a snapshot, saved on their own.
    static func cropBottom(_ file: URL, height: CGFloat, to out: URL) {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        let scale = CGFloat(img.width) / 960
        let h = Int(height * scale)
        guard let crop = img.cropping(to: CGRect(x: 0, y: img.height - h, width: img.width, height: h)),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, crop, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: A real Claude Code chat

    static func readerModeRealAgent(_ dir: URL) {
        guard let folder = ProcessInfo.processInfo.environment["HANTUU_LIVE_READER_TEST"], !folder.isEmpty else { return }
        guard let g = GhosttyApp.shared ?? GhosttyApp.start() else { check("live reader: libghostty", false); return }
        setvbuf(stdout, nil, _IOLBF, 0)
        let out = snapshotsFolder(dir)
        let settings = ChatSettings(file: dir.appendingPathComponent("live-chat-settings.json"))
        settings.showChatsAsReader = true
        let mode = ReaderMode(settings: settings)
        let model = AppModel()
        let project = Project(path: folder)
        model.projects = [project]
        let center = StatusCenter()
        center.notifier = NoticeRecorder()
        center.appIsActive = { true }
        center.start(model: model, live: false)
        let chat = Chat(projectID: project.id, agentID: "claude")
        chat.sessionID = UUID().uuidString.lowercased()
        let argv = chat.agent.launchArguments(sessionID: chat.sessionID)
        let env = ["HANTUU_CHAT_ID": chat.id.uuidString].merging(AgentHooks.environment(for: chat.id)) { a, _ in a }
        let tv = TerminalView(app: g.app, launch: .init(workingDirectory: folder, command: LoginShell.surfaceCommand(argv), environment: env), handlesChildExit: true)
        let events = LiveEvents(chat: chat, center: center)
        tv.events = events
        chat.terminal = tv
        chat.startedAt = Date()
        model.chats = [chat]
        model.selectedChatID = chat.id
        print("      live reader: claude in \(folder)")

        let w = NSWindow(contentRect: NSRect(x: -8000, y: -4000, width: 960, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        let host = FillView(color: Theme.background)
        host.frame = NSRect(x: 0, y: 0, width: 960, height: 720)
        w.contentView = host
        tv.frame = host.bounds
        host.addSubview(tv)
        let rm = ReaderModeController(model: model, mode: mode)
        rm.statusProvider = { center.state(of: $0.id) }
        rm.install(in: host, top: host.topAnchor, above: tv)
        w.orderFrontRegardless()
        rm.sync(selected: chat)

        // Follow the transcript the way AppModel does.
        let discovery = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            center.poll()
            guard chat.follower == nil, let sid = chat.sessionID, let u = ClaudeTranscriptParser.locate(sessionID: sid, cwd: folder) else { return }
            chat.transcriptPath = u.path
            let f = TranscriptFollower(url: u, kind: .claude, baseDir: folder)
            f.onAppend = { fresh in model.readerAppend.send((chat.id, fresh)) }
            chat.follower = f
            f.start()
            model.readerReload.send(chat.id)
        }
        var modes: [String] = []
        func note() {
            let d = "\(rm.composerMode)"
            if modes.last != d { modes.append(d); print("      live reader: \(d)") }
        }
        func wait(_ t: TimeInterval, _ cond: () -> Bool) -> Bool {
            waitUntil(t) { rm.refresh(); note(); return cond() || chat.status == .ended }
        }
        defer {
            discovery.invalidate()
            chat.follower?.stop()
            print("      live reader: screen at the end:\n" + tv.activeScreenText().split(separator: "\n").suffix(10).map { "        | " + $0 }.joined(separator: "\n"))
            tv.destroy()   // ends only the agent this test started
            w.orderOut(nil)
        }

        let started = wait(90) { rm.composerMode == .ready || rm.composerMode.isBlocked }
        if rm.composerMode.isBlocked {
            check("live reader: Claude Code opened without a menu (left unanswered: \(rm.composerMode))", false, String(tv.activeScreenText().suffix(600)))
            return
        }
        check("live reader: Claude Code started and the message box is ready", started && rm.composerMode == .ready, "\(rm.composerMode)")
        guard rm.composerMode == .ready else { return }
        _ = wait(2) { false }

        // One message through the message box: typed, then Return.
        w.makeFirstResponder(rm.composer.textView)
        rm.composer.textView.text = "What is 17 plus 25? Reply with just the number."
        if let e = keyEvent(36, "\r", window: w) { rm.composer.textView.keyDown(with: e) }
        let worked = wait(60) { rm.composerMode.isWorking }
        let got = wait(60) {
            guard let p = chat.transcriptPath, let t = try? String(contentsOfFile: p, encoding: .utf8) else { return false }
            return t.contains("What is 17 plus 25?")
        }
        check("live reader: the agent got the message from the message box", got, String(tv.activeScreenText().suffix(400)))
        check("live reader: the working line showed while it answered", worked || modes.contains { $0.hasPrefix("working") }, "\(modes)")
        let replied = wait(120) {
            (js(rm.reader!.page, "Array.from(document.querySelectorAll('section.entry.assistant')).some(e => /\\b42\\b/.test(e.innerText))") as? Bool) == true
        }
        check("live reader: the reply shows in the reader", replied, String(tv.activeScreenText().suffix(400)))
        _ = wait(30) { rm.composerMode == .ready }
        _ = render(host, to: out.appendingPathComponent("reader-mode-live.png"))

        // Stop: a longer answer, interrupted with Esc.
        _ = wait(2) { false }
        rm.composer.textView.text = "Write a 400-word story about a lighthouse keeper. Don't use any tools."
        rm.send()
        let busy = wait(60) { rm.composerMode.isWorking }
        _ = wait(2) { false }
        let pressed = rm.stop()
        // Claude Code's own screen is the evidence: no "esc to interrupt" once it has stopped.
        let halted = wait(30) { !TerminalScreen.analyze(tv.activeScreenText()).busy }
        let shown = wait(10) { !rm.composerMode.isWorking }
        check("live reader: Stop interrupts the turn and the working line goes", busy && pressed && halted && shown,
              "busy=\(busy) pressed=\(pressed) halted=\(halted) mode=\(rm.composerMode) status=\(chat.activity.rawValue) \(chat.activityDetail)")
        print("      live reader: after Stop: \(chat.activity.rawValue) \(chat.activityDetail)")
        print("      live reader: transcript \(chat.transcriptPath ?? "none")")
    }
}
