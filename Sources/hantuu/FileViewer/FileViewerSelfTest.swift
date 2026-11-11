import AppKit
import AVFoundation
import AVKit
import PDFKit
import WebKit

/// Self test for the Code tab as a file viewer and editor: which viewer each kind of file
/// gets, routing, reading text in its many shapes, atomic saves and symlinks, the editor
/// end to end (edit, the unsaved dot, save, undo, find), changes on disk with and without
/// unsaved edits, the prompts, the large-file guard, the native viewers, and the reader's
/// pop-out button. Writes snapshots in light and dark to <worktree>/tmp/snapshots/file-viewer/.
extension SelfTest {
    static func fileViewer(_ dir: URL) {
        let fx = FileViewerFixtures.make(dir.appendingPathComponent("file-viewer"))
        fileKinds(fx)
        fileRouting(fx)
        textFileReading(fx)
        textFileSaving(fx)
        fileViewerPanel(dir, fx)
        readerPopout(dir, fx)
    }

    static func fileViewerSnapshots(_ dir: URL) -> URL {
        // <worktree>/tmp/selftest -> <worktree>/tmp/snapshots/file-viewer
        dir.deletingLastPathComponent().appendingPathComponent("snapshots/file-viewer", isDirectory: true)
    }

    // MARK: Which viewer

    static func fileKinds(_ fx: FileViewerFixtures) {
        let expected: [(URL, ViewerKind)] = [
            (fx.code, .text), (fx.typescript, .text), (fx.markdown, .markdown), (fx.svg, .svg), (fx.csv, .csv),
            (fx.pdf, .pdf), (fx.png, .image), (fx.heic, .image), (fx.gif, .image), (fx.video, .video),
            (fx.audio, .audio), (fx.rtf, .quickLook), (fx.docx, .quickLook), (fx.blob, .unsupported),
            (fx.big, .text), (fx.folder, .directory), (fx.link, .text),
            (fx.root.appendingPathComponent("nope.swift"), .missing),
        ]
        let wrong = expected.filter { FileKinds.kind(of: $0.0.path) != $0.1 }
            .map { "\($0.0.lastPathComponent) is \(FileKinds.kind(of: $0.0.path)), wanted \($0.1)" }
        check("viewer kinds: code, Markdown, SVG, CSV, PDF, PNG, HEIC, GIF, video, audio, RTF, Word, binary, folder", wrong.isEmpty, "\(wrong)")
        check("viewer kinds: .ts is TypeScript, not an MPEG stream", FileKinds.kind(of: fx.typescript.path) == .text)
        check("viewer kinds: only text kinds are editable", ViewerKind.text.isEditable && ViewerKind.svg.isEditable && !ViewerKind.pdf.isEditable && !ViewerKind.image.isEditable)
    }

    static func fileRouting(_ fx: FileViewerFixtures) {
        var routes: [FileRouter.Route] = []
        FileRouter.shared.recorder = { routes.append($0) }
        defer { FileRouter.shared.recorder = nil }
        let r = FileRouter.shared
        let base = fx.root.path
        r.open("chart.png", base: base)
        r.open("paper.pdf", base: base)
        r.open("clip.mov", base: base)
        r.open("letter.rtf", base: base)
        r.open("NOTES.md:3", base: base)
        r.open("model.weights", base: base)
        r.open("Sources", base: base)
        check("route: images, PDFs, video and Quick Look files open in the Code tab",
              routes.count >= 4 && routes[0] == .code(fx.png.path, nil) && routes[1] == .code(fx.pdf.path, nil)
              && routes[2] == .code(fx.video.path, nil) && routes[3] == .code(fx.rtf.path, nil), "\(routes)")
        check("route: text keeps its line", routes.count > 4 && routes[4] == .code(fx.markdown.path, 3))
        check("route: files nothing can preview, and folders, go to Finder",
              routes.count == 7 && routes[5] == .finder(fx.blob.path) && routes[6] == .finder(fx.folder.path), "\(routes)")
    }

    // MARK: Reading and saving text

    static func textFileReading(_ fx: FileViewerFixtures) {
        let code = TextFile.read(fx.code.path)
        check("text: UTF-8 code reads editable", code?.readOnly == nil && code?.text == FileViewerFixtures.swiftSource && code?.eol == "\n")
        let big = TextFile.read(fx.big.path)
        if case .large(let size)? = big?.readOnly {
            check("text: a 5 MB log is read-only and only its start is read", size > 4_000_000 && (big?.text.utf8.count ?? 0) <= TextFile.previewBytes)
        } else {
            check("text: a 5 MB log is read-only and only its start is read", false, "\(String(describing: big?.readOnly))")
        }
        check("text: NUL bytes make it read-only", TextFile.read(fx.binaryText.path)?.readOnly == .binary)
        let latin = TextFile.read(fx.latin1.path)
        check("text: not UTF-8 is read-only, shown in Latin-1", latin?.readOnly == .encoding && latin?.text == "café\n")
        check("text: Windows line endings are kept", TextFile.read(fx.crlf.path)?.eol == "\r\n")
        let bom = TextFile.read(fx.bom.path)
        check("text: a byte order mark is noted and hidden", bom?.bom == true && bom?.text == "with a byte order mark\n")
    }

    static func textFileSaving(_ fx: FileViewerFixtures) {
        let fm = FileManager.default
        let file = fx.root.appendingPathComponent("save-me.txt")
        try? Data("old\n".utf8).write(to: file)
        chmod(file.path, 0o600)
        let before = FileFingerprint.of(file.path)
        let after = try? TextFile.save("new text\n", bom: false, to: file.path, realPath: TextFile.realPath(file.path))
        let mode = ((try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber)?.intValue
        check("save: writes the text, keeps permissions", (try? String(contentsOf: file, encoding: .utf8)) == "new text\n" && mode == 0o600, "mode=\(String(describing: mode))")
        check("save: atomic, so the file is a new inode", after != nil && after?.inode != before?.inode)
        let leftovers = ((try? fm.contentsOfDirectory(atPath: fx.root.path)) ?? []).filter { $0.contains(".hantuu-") }
        check("save: no temporary files left behind", leftovers.isEmpty, "\(leftovers)")
        _ = try? TextFile.save("with bom\n", bom: true, to: fx.bom.path, realPath: TextFile.realPath(fx.bom.path))
        check("save: keeps a byte order mark", (try? Data(contentsOf: fx.bom))?.starts(with: [0xEF, 0xBB, 0xBF]) == true)

        // Through a symlink: the file it points at changes, and the link stays a link.
        let real = TextFile.realPath(fx.link.path)
        let wrote = (try? TextFile.save("let outside = false\n", bom: false, to: fx.link.path, realPath: real)) != nil
        let still = (try? fm.destinationOfSymbolicLink(atPath: fx.link.path)) == fx.outside.path
        check("save: through a symlink writes its target and keeps the link", wrote && still
              && (try? String(contentsOf: fx.outside, encoding: .utf8)) == "let outside = false\n")
        // The link moved since the tab opened: refuse rather than write somewhere new.
        let other = fx.root.appendingPathComponent("elsewhere/other.swift")
        try? Data("other\n".utf8).write(to: other)
        try? fm.removeItem(at: fx.link)
        try? fm.createSymbolicLink(atPath: fx.link.path, withDestinationPath: other.path)
        var refused = false
        do { try TextFile.save("x", bom: false, to: fx.link.path, realPath: real) } catch TextFile.SaveError.linkMoved { refused = true } catch {}
        check("save: refuses when the link now points somewhere else", refused && (try? String(contentsOf: other, encoding: .utf8)) == "other\n")
        try? fm.removeItem(at: fx.link)
        try? fm.createSymbolicLink(atPath: fx.link.path, withDestinationPath: fx.outside.path)
    }

    // MARK: The panel, end to end

    static func fileViewerPanel(_ dir: URL, _ fx: FileViewerFixtures) {
        let shots = fileViewerSnapshots(dir)
        try? FileManager.default.removeItem(at: shots)
        let model = AppModel()
        let center = ReviewCenter()
        center.fixtureMode = true
        let panel = PanelController(model: model, review: center)
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 560, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 760))
        panel.view.frame = w.contentView!.bounds
        panel.view.autoresizingMask = [.width, .height]
        w.contentView!.addSubview(panel.view)
        w.orderFrontRegardless()
        defer { w.orderOut(nil) }
        let viewer = panel.code
        let page = viewer.page
        model.panelVisible = true
        model.panelTab = .code
        check("editor: page loads with CodeMirror bundled", waitUntil(10) { page.ready } && (js(page, "typeof window.CM.view.EditorView") as? String) == "function")

        func shoot(_ name: String, settle: TimeInterval = 0.5) -> Bool {
            var ok = true
            for dark in [true, false] {
                w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                RunLoop.main.run(until: Date().addingTimeInterval(settle))
                ok = renderFileViewer(panel.view, to: shots.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")) && ok
            }
            w.appearance = NSAppearance(named: .darkAqua)
            return ok
        }
        func tab(_ url: URL) -> CodeTab? { model.codeTabs.first { $0.path == url.path } }
        func inPage(_ id: UUID) -> Bool { waitUntil(6) { (js(page, "hantuu.has('\(id.uuidString)') && !!hantuu._view() && !document.getElementById('editor').hidden") as? Bool) == true } }
        func editorText() -> String { js(page, "hantuu._view().state.doc.toString()") as? String ?? "" }
        func edit(insert: String, at pos: String = "0") {
            _ = js(page, "hantuu._view().dispatch({changes: {from: \(pos), insert: \(FileViewerController.jsString(insert))}, userEvent: 'input'}); 1")
        }
        func pane(_ url: URL) -> FileViewerPane? {
            guard let id = tab(url)?.id else { return nil }
            _ = waitUntil(3) { viewer.docs[id]?.pane != nil }
            return viewer.docs[id]?.pane
        }
        func disk(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        func agentWrites(_ url: URL, _ text: String) { try? Data(text.utf8).write(to: url, options: .atomic) }

        // A code file: highlighted, line numbers, edit, the dot, save, undo back to saved.
        model.openFile(fx.code.path, line: nil)
        guard let codeID = tab(fx.code)?.id, inPage(codeID) else {
            check("editor: a Swift file opens in the editor", false)
            return
        }
        check("editor: a Swift file opens in the editor", editorText() == FileViewerFixtures.swiftSource)
        let lines = js(page, "document.querySelectorAll('.cm-lineNumbers .cm-gutterElement').length") as? Int ?? 0
        let colours = js(page, "new Set(Array.from(document.querySelectorAll('.cm-line span')).map(s => getComputedStyle(s).color)).size") as? Int ?? 0
        check("editor: line numbers and syntax colours", lines > 10 && colours >= 3, "lines=\(lines) colours=\(colours)")
        edit(insert: "// Edited in hantuu.\n")
        check("editor: an edit marks the tab unsaved", waitUntil(3) { tab(fx.code)?.dirty == true })
        check("editor: Save is offered", viewer.canSaveSelected)
        // Find, through the real Cmd-F key binding.
        _ = js(page, "hantuu._view().contentDOM.dispatchEvent(new KeyboardEvent('keydown', {key: 'f', code: 'KeyF', keyCode: 70, metaKey: true, bubbles: true, cancelable: true})); 1")
        let findOpen = waitUntil(2) { (js(page, "!!document.querySelector('.findbar')") as? Bool) == true }
        _ = js(page, "(() => { const f = document.querySelector('.findbar .fb-field'); f.value = 'tokens'; f.dispatchEvent(new Event('input')); f.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true})); return 1; })()")
        let count = waitUntil(2) { (js(page, "document.querySelector('.findbar .fb-count').textContent") as? String ?? "").hasSuffix("of 4") }
        check("editor: Cmd-F opens find, which counts matches", findOpen && count, js(page, "document.querySelector('.findbar .fb-count') && document.querySelector('.findbar .fb-count').textContent") as? String ?? "no bar")
        model.openFile(fx.markdown.path, line: nil)
        model.openFile(fx.csv.path, line: nil)
        model.selectedCodeTabID = codeID
        _ = inPage(codeID)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check("snapshot: a code file being edited, with the unsaved dot and find", shoot("code-editing"))
        _ = js(page, "hantuu._CM.search.closeSearchPanel(hantuu._view()); 1")

        var saved: Bool?
        viewer.save(codeID) { saved = $0 }
        _ = waitUntil(3) { saved != nil }
        check("editor: Save writes the file and clears the dot", saved == true && disk(fx.code).hasPrefix("// Edited in hantuu.\n") && waitUntil(2) { tab(fx.code)?.dirty == false })
        edit(insert: "x")
        _ = waitUntil(2) { tab(fx.code)?.dirty == true }
        // Cmd-Z the way AppKit delivers it: as a key equivalent to the focused web view.
        _ = js(page, "hantuu.focus(); 1")
        w.makeFirstResponder(page.webView)
        let cmdZ = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: w.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
        _ = page.webView.performKeyEquivalent(with: cmdZ)
        check("editor: Cmd-Z undoes, and undoing back to the saved text clears the dot", waitUntil(2) { tab(fx.code)?.dirty == false }
              && disk(fx.code) == editorText())

        // Changes on disk with no unsaved edits: reload in place, same place on screen.
        model.openFile(fx.long.path, line: 80)
        guard let longID = tab(fx.long)?.id, inPage(longID) else { return check("disk: long file opens", false) }
        _ = waitUntil(3) { ((js(page, "hantuu.scrollInfo()") as? [String: Any])?["line"] as? Int ?? 0) > 40 }
        let before = js(page, "hantuu.scrollInfo()") as? [String: Any]
        let original = disk(fx.long)
        agentWrites(fx.long, original + "let added = true\n")
        let reloaded = waitUntil(4) { editorText().hasSuffix("let added = true\n") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let after = js(page, "hantuu.scrollInfo()") as? [String: Any]
        let lineBefore = before?["line"] as? Int ?? -1, lineAfter = after?["line"] as? Int ?? -2
        check("disk: an agent's edit reloads in place when nothing is unsaved", reloaded && tab(fx.long)?.dirty == false && viewer.banner == nil)
        check("disk: the reload keeps the scroll position", lineBefore > 40 && lineBefore == lineAfter, "line \(lineBefore) -> \(lineAfter)")
        model.selectedCodeTabID = codeID
        _ = inPage(codeID)
        model.selectedCodeTabID = longID
        _ = inPage(longID)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let back = (js(page, "hantuu.scrollInfo()") as? [String: Any])?["line"] as? Int ?? -3
        check("tabs: switching away and back keeps your place", back == lineAfter, "line \(lineAfter) -> \(back)")

        // With unsaved edits: neither side is overwritten, and the bar asks.
        edit(insert: "// mine\n")
        _ = waitUntil(2) { tab(fx.long)?.dirty == true }
        agentWrites(fx.long, "// theirs\n" + original)
        let barShown = waitUntil(4) { viewer.banner == .changedOnDisk("Long.swift") }
        check("disk: with unsaved edits the bar shows and nothing is overwritten", barShown && editorText().hasPrefix("// mine\n") && disk(fx.long).hasPrefix("// theirs\n"),
              "banner=\(String(describing: viewer.banner))")
        check("snapshot: the changed-on-disk bar", shoot("changed-on-disk"))
        viewer.keepMine()
        check("disk: Keep Mine hides the bar and keeps your text unsaved", viewer.banner == nil && tab(fx.long)?.dirty == true && editorText().hasPrefix("// mine\n"))
        saved = nil
        viewer.save(longID) { saved = $0 }
        _ = waitUntil(3) { saved != nil }
        check("disk: saving after Keep Mine writes yours", saved == true && disk(fx.long).hasPrefix("// mine\n"))
        edit(insert: "// draft\n")
        _ = waitUntil(2) { tab(fx.long)?.dirty == true }
        agentWrites(fx.long, "// agent again\n")
        _ = waitUntil(4) { viewer.banner == .changedOnDisk("Long.swift") }
        viewer.reloadFromDisk()
        check("disk: Reload shows the file on disk and drops your edits", waitUntil(3) { editorText() == "// agent again\n" } && waitUntil(2) { tab(fx.long)?.dirty == false } && viewer.banner == nil)
        // Save checks the disk first, even before the watcher has noticed.
        edit(insert: "// quick\n")
        _ = waitUntil(2) { tab(fx.long)?.dirty == true }
        agentWrites(fx.long, "// raced\n")
        saved = nil
        viewer.save(longID) { saved = $0 }
        _ = waitUntil(3) { saved != nil }
        check("disk: Save won't write over a change it hasn't shown you", saved == false && disk(fx.long) == "// raced\n" && viewer.banner == .changedOnDisk("Long.swift"))
        viewer.reloadFromDisk()
        _ = waitUntil(2) { tab(fx.long)?.dirty == false }
        // Deleted, then saved back.
        try? FileManager.default.removeItem(at: fx.long)
        check("disk: a deleted file says so", waitUntil(4) { if case .deleted = viewer.banner { return true }; return false })
        agentWrites(fx.long, "// back\n")
        check("disk: and recovers when it comes back", waitUntil(4) { viewer.banner == nil && editorText() == "// back\n" })

        // Closing and quitting with unsaved changes.
        edit(insert: "unsaved ")
        _ = waitUntil(2) { tab(fx.long)?.dirty == true }
        viewer.promptOverride = { _ in .cancel }
        model.closeCodeTab(longID)
        check("prompt: Cancel keeps the tab", tab(fx.long) != nil)
        check("prompt: quitting with unsaved changes asks, and Cancel stays open", !viewer.confirmQuit())
        viewer.promptOverride = { _ in .discard }
        model.closeCodeTab(longID)
        check("prompt: Don't Save closes the tab and leaves the file alone", tab(fx.long) == nil && disk(fx.long) == "// back\n")
        check("prompt: nothing unsaved quits without asking", { viewer.promptOverride = { _ in .cancel }; return viewer.confirmQuit() }())
        model.openFile(fx.long.path, line: nil)
        if let id = tab(fx.long)?.id, inPage(id) {
            edit(insert: "saved on close\n")
            _ = waitUntil(2) { tab(fx.long)?.dirty == true }
            viewer.promptOverride = { _ in .save }
            model.closeCodeTab(id)
            check("prompt: Save writes the file, then closes", waitUntil(3) { tab(fx.long) == nil } && disk(fx.long).hasPrefix("saved on close\n"))
        }
        viewer.promptOverride = nil

        // The large-file guard.
        model.openFile(fx.big.path, line: nil)
        if let id = tab(fx.big)?.id, inPage(id) {
            let ro = js(page, "hantuu._view().state.readOnly") as? Bool ?? false
            let len = js(page, "hantuu._view().state.doc.length") as? Int ?? 0
            let note: Bool = { if case .note? = viewer.banner { return true }; return false }()
            check("large: a 5 MB log opens read-only, its first 2 MB, with a note", ro && len > 1_000_000 && len <= TextFile.previewBytes && note && !viewer.canSaveSelected)
            check("snapshot: a large file's note", shoot("large-file"))
        }

        // Previews: Markdown, SVG, CSV, and the switch to Source.
        model.selectedCodeTabID = tab(fx.markdown)?.id
        let md = waitUntil(4) { (js(page, "!!document.querySelector('#preview article.md h1')") as? Bool) == true }
        check("preview: Markdown opens rendered", md && tab(fx.markdown)?.preview == true)
        if let id = tab(fx.markdown)?.id { model.setPreview(id, false) }
        check("preview: Source switches to the editor", inPage(tab(fx.markdown)!.id) && editorText().hasPrefix("# Notes"))
        model.openFile(fx.svg.path, line: nil)
        check("preview: SVG renders in an img", waitUntil(4) { (js(page, "(() => { const i = document.querySelector('.svgstage img'); return !!i && i.complete && i.naturalWidth > 0; })()") as? Bool) == true })
        check("snapshot: SVG preview", shoot("svg"))
        model.selectedCodeTabID = tab(fx.csv)?.id
        check("preview: CSV renders as a table, quotes and all", waitUntil(4) { (js(page, "document.querySelectorAll('table.csv tbody tr').length") as? Int) == 3 }
              && (js(page, "document.querySelector('table.csv tbody tr td:last-child').textContent") as? String) == "long, careful")
        check("snapshot: CSV preview", shoot("csv"))

        // Native viewers.
        model.openFile(fx.pdf.path, line: nil)
        let pdfPane = pane(fx.pdf) as? PDFViewer
        check("pdf: PDFKit's view, both pages", pdfPane?.pdf.document?.pageCount == 2 && page.webView.isHidden)
        check("snapshot: PDF", shoot("pdf", settle: 0.9))
        model.openFile(fx.png.path, line: nil)
        let imagePane = pane(fx.png) as? ImageViewer
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check("image: fits the panel without being blown up", imagePane?.loaded == true && imagePane!.fitted && imagePane!.scroll.magnification < 1 && imagePane!.scroll.magnification > 0.3,
              "mag=\(imagePane?.scroll.magnification ?? -1)")
        check("snapshot: image", shoot("image"))
        if let png = FileViewerFixtures.chartPNG(width: 400, height: 300, bars: [0.9, 0.2]) { try? png.write(to: fx.png, options: .atomic) }
        check("image: reloads when the file changes", waitUntil(4) { imagePane?.image?.size == NSSize(width: 400, height: 300) })
        model.openFile(fx.heic.path, line: nil)
        check("image: HEIC", (pane(fx.heic) as? ImageViewer)?.loaded == true)
        model.openFile(fx.gif.path, line: nil)
        let gifPane = pane(fx.gif) as? ImageViewer
        check("image: GIF, animated", gifPane?.loaded == true && gifPane?.imageView.animates == true
              && (gifPane?.image?.representations.first as? NSBitmapImageRep)?.value(forProperty: .frameCount) as? Int == 2)
        model.openFile(fx.video.path, line: nil)
        let videoPane = pane(fx.video) as? MediaViewer
        let videoReady = waitUntil(6) { videoPane?.ready == true && videoPane?.videoSize != nil }
        check("video: AVPlayerView at the video's own shape, paused", videoReady && videoPane?.videoSize == CGSize(width: 640, height: 360) && videoPane?.player.rate == 0,
              "size=\(String(describing: videoPane?.videoSize))")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check("snapshot: video, first frame", shoot("video", settle: 0.6))
        model.openFile(fx.audio.path, line: nil)
        let audioPane = pane(fx.audio) as? MediaViewer
        check("audio: the player's controls with the file's name", waitUntil(5) { audioPane?.ready == true } && audioPane?.audioOnly == true)
        check("snapshot: audio", shoot("audio"))
        model.selectedCodeTabID = tab(fx.video)?.id
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        videoPane?.player.play()
        model.selectedCodeTabID = tab(fx.png)?.id
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check("video: switching tabs pauses it", videoPane?.player.rate == 0)
        model.openFile(fx.rtf.path, line: nil)
        check("quick look: RTF in QLPreviewView", pane(fx.rtf) is QuickLookViewer)
        model.openFile(fx.blob.path, line: nil)
        check("fallback: nothing can preview it, so a note with Reveal in Finder", pane(fx.blob) is FallbackViewer)
        check("snapshot: fallback", shoot("fallback"))

        // Cmd-W in the viewer goes through the same prompt.
        let n = model.codeTabs.count
        model.closeCodeTab(model.selectedCodeTabID!)
        check("tabs: closing a tab without changes doesn't ask", model.codeTabs.count == n - 1)
        for t in model.codeTabs { model.removeCodeTab(t.id) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check("tabs: closed tabs stop watching and leave the page", viewer.docs.isEmpty && (js(page, "document.getElementById('empty').hidden") as? Bool) == false)
        print("      file viewer snapshots in \(shots.path)")
    }

    /// Like the panel snapshots in ReviewSelfTest, plus the video frame: AVPlayerView draws
    /// video in a layer that an offscreen capture doesn't include, so the frame the player is
    /// showing is drawn from the same file where the player shows it.
    static func renderFileViewer(_ view: NSView, to url: URL) -> Bool {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        guard let cached = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        view.cacheDisplay(in: bounds, to: cached)
        var shots: [(NSRect, NSImage)] = []
        var frames: [(NSRect, NSImage)] = []
        func all<T: NSView>(_ v: NSView, _ type: T.Type) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { all($0, type) } }
        for w in all(view, WKWebView.self) where !w.isHiddenOrHasHiddenAncestor && w.bounds.width > 0 {
            var image: NSImage?
            var done = false
            w.takeSnapshot(with: nil) { img, _ in image = img; done = true }
            _ = waitUntil(5) { done }
            if let image { shots.append((w.convert(w.bounds, to: view), image)) }
        }
        for m in all(view, MediaViewer.self) where !m.isHiddenOrHasHiddenAncestor && !m.audioOnly {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: m.url))
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            var frame: CGImage?
            var done = false
            gen.generateCGImageAsynchronously(for: m.player.currentTime()) { img, _, _ in frame = img; done = true }
            _ = waitUntil(5) { done }
            if let frame { frames.append((m.convert(m.videoFrame, to: view), NSImage(cgImage: frame, size: .zero))) }
        }
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cached.pixelsWide, pixelsHigh: cached.pixelsHigh, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        out.size = bounds.size
        guard let ctx = NSGraphicsContext(bitmapImageRep: out) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            Theme.chrome.setFill()
            bounds.fill()
        }
        cached.draw(in: bounds)
        // PDFView draws its pages in tiles that an offscreen capture leaves blank, so each
        // visible page is drawn where PDFView laid it out.
        for p in all(view, PDFView.self) where !p.isHiddenOrHasHiddenAncestor {
            guard let doc = p.document, let cg = NSGraphicsContext.current?.cgContext else { continue }
            let clip = p.convert(p.bounds, to: view)
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let box = page.bounds(for: .cropBox)
                let r = p.convert(p.convert(box, from: page), to: view)
                guard r.intersects(clip) else { continue }
                cg.saveGState()
                cg.clip(to: clip)
                cg.translateBy(x: r.minX, y: r.minY)
                cg.scaleBy(x: r.width / box.width, y: r.height / box.height)
                page.draw(with: .cropBox, to: cg)
                cg.restoreGState()
            }
        }
        for (r, img) in shots + frames { img.draw(in: r) }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = out.representation(using: .png, properties: [:]) else { return false }
        Paths.ensure(url.deletingLastPathComponent())
        return (try? png.write(to: url)) != nil
    }

    // MARK: Media in the reader: compact previews, opening out, and the pop-out button

    static func readerPopout(_ dir: URL, _ fx: FileViewerFixtures) {
        let shots = fileViewerSnapshots(dir)
        let model = AppModel()
        let reader = ReaderController(model: model, page: "reader.html?layout=main", identifier: "selftest.popout")
        let page = reader.page
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 640, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        let host = FillView(color: Theme.background)
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 900)
        w.contentView = host
        page.webView.frame = host.bounds
        host.addSubview(page.webView)
        w.orderFrontRegardless()
        defer { w.orderOut(nil) }
        guard waitUntil(10, { page.ready }) else { return check("media: reader page loads", false) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var posted: [[String: Any]] = []
        let previous = page.onMessage
        page.onMessage = { msg in
            posted.append(msg)
            previous?(msg)
        }
        func sent(_ type: String) -> [[String: Any]] { posted.filter { $0["type"] as? String == type } }

        let pasted = "data:image/png;base64," + (FileViewerFixtures.chartPNG(width: 240, height: 150, bars: [0.4, 0.8, 0.6])?.base64EncodedString() ?? "")
        var user = ReaderEntry(id: "u1", kind: .user, text: "Here's the chart I made.")
        user.images = [pasted]
        let text = "I plotted it at \(fx.png.path), wrote up the method in \(fx.pdf.path) and made a slide, \(fx.slides.path)."
        var answer = ReaderEntry(id: "a1", kind: .assistant, text: text)
        answer.links = PathDetector.detect(in: text, base: fx.root.path)
        let entries = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode([user, answer]))) ?? []
        page.call("reset", ["chatID": "media", "entries": entries, "emptyText": ""] as [String: Any])
        let loaded = waitUntil(6) { (js(page, "Array.from(document.querySelectorAll('.media img')).every(i => i.complete && i.naturalWidth > 0) && document.querySelectorAll('.media img').length === 4") as? Bool) == true }
        check("media: images and PDF first pages load (PDFs through hantuu://thumb)", loaded)

        // Small, side by side, wrapping.
        let boxes = js(page, "JSON.stringify(Array.from(document.querySelectorAll('.entry.assistant figure.mfig')).map(f => { const r = f.querySelector('.mbody').getBoundingClientRect(); return [Math.round(r.top), Math.round(r.width), Math.round(r.height)]; }))") as? String ?? "[]"
        let b = (try? JSONSerialization.jsonObject(with: Data(boxes.utf8))) as? [[Int]] ?? []
        check("media: previews are compact, about 180 pt tall", b.count == 3 && b.allSatisfy { $0[2] >= 170 && $0[2] <= 190 }, boxes)
        check("media: previews sit side by side and wrap when there isn't room", b.count == 3 && b[0][0] == b[1][0] && b[2][0] > b[0][0] + 150, boxes)
        let small = js(page, "(() => { const i = document.querySelector('.entry.user img.attached-image'); return [i.naturalHeight, Math.round(i.getBoundingClientRect().height)]; })()") as? [Int] ?? []
        check("media: a small image isn't blown up", small.count == 2 && small[0] == 150 && abs(small[1] - 152) <= 1, "\(small)")
        let twoInRow = js(page, "(() => { const f = Array.from(document.querySelectorAll('.entry.assistant figure.mfig')); return f[0].offsetTop === f[1].offsetTop; })()") as? Bool
        check("media: two previews share a row", twoInRow == true)
        check("media: every preview has a pop-out button, hidden until hover",
              (js(page, "Array.from(document.querySelectorAll('figure.mfig')).every(f => f.querySelector(':scope > button.popout[aria-label]'))") as? Bool) == true
              && js(page, "getComputedStyle(document.querySelector('button.popout')).opacity") as? String == "0")

        // Snapshot, small, with the pop-out button showing on one as hover would.
        func shoot(_ name: String) {
            for dark in [true, false] {
                w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                _ = renderFileViewer(host, to: shots.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
            w.appearance = NSAppearance(named: .darkAqua)
        }
        _ = js(page, "(() => { const b = document.querySelectorAll('.entry.assistant button.popout')[1]; b.style.transition = 'none'; b.style.opacity = 1; window.scrollTo(0, 0); return 1; })()")
        shoot("reader-media-small")

        // Click opens out to full width, in place; click again shrinks it.
        posted.removeAll()
        let topBefore = js(page, "Math.round(document.querySelectorAll('.entry.assistant figure.mfig')[1].getBoundingClientRect().top)") as? Int ?? -1
        _ = js(page, "document.querySelectorAll('.entry.assistant figure.mfig')[1].querySelector('.mbody').click(); 1")
        let opened = js(page, "(() => { const f = document.querySelectorAll('.entry.assistant figure.mfig')[1]; const r = f.getBoundingClientRect(); const m = f.closest('.media').getBoundingClientRect(); return f.classList.contains('expanded') && Math.abs(r.width - m.width) < 2 && !!f.querySelector('iframe') && r.height > 500; })()") as? Bool
        let topAfter = js(page, "Math.round(document.querySelectorAll('.entry.assistant figure.mfig')[1].getBoundingClientRect().top)") as? Int ?? -2
        check("media: clicking a PDF opens it out to full width as the live PDF", opened == true)
        check("media: opening out keeps it where it was on screen", abs(topBefore - topAfter) <= 1, "\(topBefore) -> \(topAfter)")
        check("media: clicking doesn't open the file anymore", sent("open").isEmpty && sent("popout").isEmpty)
        check("media: Swift hears what's opened out", waitUntil(2) { reader.mediaKeys.expanded == 1 })
        _ = js(page, "document.querySelectorAll('.entry.assistant figure.mfig')[1].scrollIntoView({block: 'start'}); window.scrollBy(0, -24); 1")
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        shoot("reader-media-expanded")
        _ = js(page, "document.querySelectorAll('.entry.assistant figure.mfig')[1].querySelector('.mbody').click(); 1")
        let shrunk = js(page, "(() => { const f = document.querySelectorAll('.entry.assistant figure.mfig')[1]; return !f.classList.contains('expanded') && !f.querySelector('iframe') && f.getBoundingClientRect().height < 220; })()") as? Bool
        check("media: clicking again shrinks it", shrunk == true && waitUntil(2) { reader.mediaKeys.expanded == 0 })

        // Esc: on the page, and from the message box through Swift.
        _ = js(page, "document.querySelector('.entry.assistant figure.mfig').querySelector('.mbody').click(); 1")
        _ = js(page, "document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true})); 1")
        check("media: Esc on the page shrinks it", (js(page, "document.querySelectorAll('figure.mfig.expanded').length") as? Int) == 0)
        _ = js(page, "document.querySelector('.entry.assistant figure.mfig').querySelector('.mbody').click(); 1")
        _ = waitUntil(2) { reader.mediaKeys.expanded == 1 }
        let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil,
                                   characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        let swallowed = reader.mediaKeys.handle(esc) == nil
        check("media: Esc in the message box shrinks it first, and only then reaches the box", swallowed
              && waitUntil(2) { (js(page, "document.querySelectorAll('figure.mfig.expanded').length") as? Int) == 0 }
              && waitUntil(2) { reader.mediaKeys.expanded == 0 } && reader.mediaKeys.handle(esc) != nil)

        // The caption still opens the file; the pop-out opens a kept tab.
        posted.removeAll()
        _ = js(page, "document.querySelectorAll('.entry.assistant figcaption a.path')[1].click(); 1")
        check("media: the caption opens the file like a link", waitUntil(2) { sent("open").first?["path"] as? String == fx.pdf.path })
        model.codeTabs = []
        posted.removeAll()
        _ = js(page, "document.querySelector('.entry.assistant figure.image button.popout').click(); 1")
        check("popout: clicking posts {type: 'popout', path}", waitUntil(2) { sent("popout").first?["path"] as? String == fx.png.path })
        check("popout: the image opens as a tab in the Code tab, panel shown", model.codeTabs.map(\.path) == [fx.png.path] && model.panelTab == .code && model.panelVisible)
        _ = js(page, "document.querySelector('figure.pdf button.popout').click(); 1")
        check("popout: a second pop-out adds a tab and keeps the first", waitUntil(2) { model.codeTabs.map(\.path) == [fx.png.path, fx.pdf.path] })
        _ = js(page, "(() => { const f = document.querySelectorAll('.entry.assistant figure.mfig')[2]; f.querySelector('.mbody').click(); f.querySelector('button.popout').click(); return 1; })()")
        check("popout: works on an opened-out preview too", waitUntil(2) { model.codeTabs.last?.path == fx.slides.path })
        let folder = ReaderPopout.folder
        try? FileManager.default.removeItem(at: folder)
        let before = model.codeTabs.count
        _ = js(page, "document.querySelector('.entry.user figure button.popout').click(); 1")
        _ = waitUntil(2) { model.codeTabs.count == before + 1 }
        _ = js(page, "document.querySelector('.entry.user figure button.popout').click(); 1")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        check("popout: a pasted image is written once under attachments/reader and opened", files.count == 1 && files[0].hasSuffix(".png")
              && model.codeTabs.count == before + 1 && model.codeTabs.last?.path == folder.appendingPathComponent(files[0]).path, "\(files) \(model.codeTabs.map(\.name))")
        check("popout: data URL decoding", ReaderPopout.write(dataURL: "data:text/plain,hello%20there", into: dir.appendingPathComponent("popout-test")).map { (try? String(contentsOfFile: $0, encoding: .utf8)) == "hello there" } == true)
        check("media: a PDF thumbnail is a crisp PNG of page one", PDFThumbnails.png(path: fx.slides.path, height: 400).flatMap { NSBitmapImageRep(data: $0) }.map { $0.pixelsHigh == 400 && $0.pixelsWide == 518 } == true)
        check("media: no thumbnail for something that isn't a PDF", PDFThumbnails.png(path: fx.png.path, height: 400) == nil)
    }
}
