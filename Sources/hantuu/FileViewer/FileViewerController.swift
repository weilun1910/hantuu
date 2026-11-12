import AppKit
import Combine
import SwiftUI

/// What the editor page needs to open a text tab.
struct EditorPayload: Encodable {
    var id: String
    var path: String
    var name: String
    var text: String
    /// "markdown", "svg" or "csv" for files with a rendered preview.
    var preview: String?
    /// "preview" or "source".
    var mode: String
    var readOnly: Bool
    var wrap: Bool
    var eol: String
    var line: Int?
    var base: String
    var links: [DetectedPath]
    var position: EditorPosition?
    var recoveryText: String?
    var generation: String
}

/// One open tab's file, as the viewer keeps it.
final class FileDoc {
    let id: UUID
    let path: String
    /// Where the bytes really are once symlinks are resolved. Saving writes here and nowhere
    /// else (TextFile.save).
    let realPath: String
    /// The path itself is a symlink, so saving writes somewhere else.
    let isLink: Bool
    var kind: ViewerKind
    /// Text tabs: the file as last read from or saved to disk. The editor's unsaved changes
    /// are compared against it.
    var load: TextLoad?
    var links: [DetectedPath] = []
    var loading = false
    /// The editor page has this tab's document.
    var inPage = false
    var dirty = false
    var recovery: EditorRecoveryRecord?
    var recoveryPending = false
    /// The tab's last line request the page has scrolled to (CodeTab.lineRequest).
    var shownLineRequest = 0
    /// The file changed on disk while you had unsaved changes. Holds what's on disk now.
    var pendingDisk: TextLoad?
    var deleted = false
    var error: String?
    /// Couldn't be read or shown, and why.
    var failure: String?
    var fingerprint: FileFingerprint?
    var watch: FileWatch?
    var pane: FileViewerPane?

    init(id: UUID, path: String, kind: ViewerKind) {
        self.id = id
        self.path = path
        self.realPath = TextFile.realPath(path)
        var st = stat()
        self.isLink = lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
        self.kind = kind
        self.fingerprint = FileFingerprint.of(realPath)
    }

    var name: String { (path as NSString).lastPathComponent }
}

/// The quiet bar above the selected tab, when there's something to say.
enum FileBanner: Equatable {
    case recovery(String)
    case changedOnDisk(String)
    case deleted(String, dirty: Bool)
    case note(symbol: String, text: String)
    case error(String)
}

/// The bar observes its content without retaining the controller that owns its host view.
final class FileViewerBarState: ObservableObject {
    @Published var banner: FileBanner?
    weak var viewer: FileViewerController?
}

/// The Code tab: any file in a tab. Text and code open in an editor you can save (a
/// CodeMirror 6 page), Markdown, SVG and CSV can switch to a rendered preview, and everything
/// else gets the native view that suits it (FileKinds). It watches every open file, so an
/// agent's edit shows up in place, or as a Reload / Keep Mine bar when you have unsaved
/// changes.
final class FileViewerController: NSObject, ObservableObject {
    let page = WebPage(page: "code.html", identifier: "hantuu.code")
    let root = FillView(color: Theme.chrome)
    private let content = FillView(color: Theme.chrome)
    private var barHost: NSView!
    private var barHeight: NSLayoutConstraint!
    private let model: AppModel
    private(set) var docs: [UUID: FileDoc] = [:]
    @Published private(set) var banner: FileBanner? { didSet { barState.banner = banner } }
    private let barState = FileViewerBarState()
    let recoveryStore = EditorRecoveryStore()
    private var generation = UUID().uuidString
    private var shownKey = ""
    private var bag = Set<AnyCancellable>()
    private(set) var documentWindows: [UUID: FileDocumentWindow] = [:]

    func openInNewWindow() {
        guard let document = selectedDoc else { return }
        if let existing = documentWindows[document.id] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = FileDocumentWindow(owner: self, document: document)
        documentWindows[document.id] = controller
        controller.onClose = { [weak self] in self?.documentWindows[document.id] = nil }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// The self test answers the unsaved-changes prompt instead of a person.
    var promptOverride: (([CodeTab]) -> SaveChoice)?

    enum SaveChoice { case save, discard, cancel }

    init(model: AppModel) {
        self.model = model
        super.init()
        root.identifier = NSUserInterfaceItemIdentifier("hantuu.code")
        barState.viewer = self
        barHost = ChromeHostingView(rootView: FileViewerBar(state: barState))
        for v in [barHost!, content] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        barHeight = barHost.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            barHost.topAnchor.constraint(equalTo: root.topAnchor),
            barHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            barHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            barHeight,
            content.topAnchor.constraint(equalTo: barHost.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        fill(content, with: page.webView)
        model.fileViewer = self
        recoveryStore.onError = { [weak self] id, error in
            self?.docs[id]?.error = "Recovery could not be saved: \(error.localizedDescription)"
            self?.updateBanner()
        }
        page.onReady = { [weak self] in self?.pageLoaded() }
        page.onMessage = { [weak self] msg in self?.handle(msg) }
        model.$codeTabs.combineLatest(model.$selectedCodeTabID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.render() }
            .store(in: &bag)
        model.$panelTab.combineLatest(model.$panelVisible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab, visible in
                guard let self else { return }
                if visible && tab == .code {
                    self.page.call("relayout")
                } else {
                    for d in self.docs.values { d.pane?.didHide() }
                }
            }
            .store(in: &bag)
    }

    var view: NSView { root }

    private func fill(_ parent: NSView, with v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: parent.topAnchor),
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    var selectedTab: CodeTab? {
        guard let id = model.selectedCodeTabID else { return nil }
        return model.codeTabs.first { $0.id == id }
    }
    var selectedDoc: FileDoc? { model.selectedCodeTabID.flatMap { docs[$0] } }

    // MARK: Showing tabs

    /// The page reloaded (first load, or its process restarted): it has no documents now.
    private func pageLoaded() {
        generation = UUID().uuidString
        for d in docs.values {
            d.inPage = false
            if d.dirty {
                recoveryStore.flush(d.id)
                d.recovery = recoveryStore.read(d.id)
                d.recoveryPending = d.recovery != nil
            }
        }
        shownKey = ""
        render()
    }

    func projectDidChange() {
        // WebKit paints asynchronously. Keep the previous project's pixels hidden until
        // the page confirms that it is showing the selected document.
        page.webView.alphaValue = 0
        shownKey = ""
        render()
    }

    func render() {
        for tab in model.allCodeTabs where docs[tab.id] == nil { _ = makeDoc(tab) }
        let open = Set(model.allCodeTabs.map(\.id))
        for (id, d) in docs where !open.contains(id) { drop(d) }
        guard let tab = selectedTab else {
            showPane(nil)
            page.webView.isHidden = false
            if shownKey != "none" { page.call("clear") }
            shownKey = "none"
            updateBanner()
            return
        }
        let d = docs[tab.id] ?? makeDoc(tab)
        if d.kind.usesPage && d.failure == nil {
            showPane(nil)
            page.webView.isHidden = false
            guard d.load != nil else {
                if shownKey != "loading" { page.call("blank") }
                shownKey = "loading"
                startLoading(d)
                updateBanner()
                return
            }
            let key = "\(tab.id)|\(tab.preview)|\(tab.lineRequest)"
            // Scroll to the link's line only when a link asked for it, not on every visit.
            let line = tab.lineRequest != d.shownLineRequest ? tab.line : nil
            d.shownLineRequest = tab.lineRequest
            if !d.inPage {
                var p = payload(d, tab)
                p.line = line
                page.call("open", p)
                d.inPage = true
            } else if key != shownKey {
                page.call("show", ["id": tab.id.uuidString, "mode": tab.preview ? "preview" : "source", "line": line ?? 0] as [String: Any])
            }
            shownKey = key
        } else {
            if !shownKey.hasPrefix("pane|") { page.call("blank") }
            shownKey = "pane|\(tab.id)"
            page.webView.isHidden = true
            showPane(d.pane ?? makePane(d))
        }
        updateBanner()
    }

    private func makeDoc(_ tab: CodeTab) -> FileDoc {
        let d = FileDoc(id: tab.id, path: tab.path, kind: tab.kind)
        docs[tab.id] = d
        if let r = recoveryStore.read(tab.id), r.path == tab.path, r.projectID == projectID(for: tab.id) {
            d.recovery = r
            if d.kind == .missing { d.kind = .text; d.deleted = true }
            d.recoveryPending = true
            setDirty(d, true)
        }
        if d.kind != .missing && d.kind != .directory {
            d.watch = FileWatch(path: d.realPath) { [weak self, weak d] in
                guard let self, let d else { return }
                self.diskChanged(d)
            }
        }
        return d
    }

    private func drop(_ d: FileDoc) {
        d.watch?.stop()
        d.watch = nil
        d.pane?.didHide()
        d.pane?.close()
        d.pane?.removeFromSuperview()
        d.pane = nil
        if d.inPage { page.call("close", d.id.uuidString) }
        recoveryStore.remove(d.id)
        docs[d.id] = nil
    }

    private func startLoading(_ d: FileDoc) {
        guard !d.loading else { return }
        d.loading = true
        let path = d.path, kind = d.kind
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let load = TextFile.read(path) ?? d.recovery.map { TextLoad(text: $0.baseline) }
            let links = kind == .markdown ? PathDetector.detect(in: load?.text ?? "", base: (path as NSString).deletingLastPathComponent) : []
            DispatchQueue.main.async {
                guard let self, self.docs[d.id] === d else { return }
                d.loading = false
                if let load {
                    d.load = load
                    d.links = links
                    d.fingerprint = load.fingerprint
                } else {
                    d.failure = "hantuu couldn't read this file."
                }
                if self.model.selectedCodeTabID == d.id { self.render() }
            }
        }
    }

    static func wraps(_ path: String) -> Bool {
        ["md", "markdown", "mdx", "txt", "text", "rst", "tex"].contains((path as NSString).pathExtension.lowercased())
    }

    private func payload(_ d: FileDoc, _ tab: CodeTab) -> EditorPayload {
        let load = d.load ?? TextLoad(text: "")
        let preview: String? = switch d.kind {
        case .markdown: "markdown"
        case .svg: "svg"
        case .csv: "csv"
        default: nil
        }
        return EditorPayload(id: d.id.uuidString, path: d.path, name: d.name, text: load.text, preview: preview,
                             mode: tab.preview && preview != nil ? "preview" : "source", readOnly: load.readOnly != nil || d.recoveryPending,
                             wrap: Self.wraps(d.path), eol: load.eol, line: tab.line, base: (d.path as NSString).deletingLastPathComponent,
                             links: d.links, position: tab.editorPosition, recoveryText: d.recovery?.text, generation: generation)
    }

    private func makePane(_ d: FileDoc) -> FileViewerPane {
        let url = URL(fileURLWithPath: d.path)
        let pane: FileViewerPane
        if let failure = d.failure {
            pane = FallbackViewer(url: url, reason: failure)
        } else {
            switch d.kind {
            case .pdf:
                let v = PDFViewer(url: url)
                v.onFailure = { [weak self, weak d] in d.map { self?.fail($0, "PDFKit couldn't open this PDF.") } }
                pane = v.loaded ? v : FallbackViewer(url: url, reason: "PDFKit couldn't open this PDF.")
            case .image:
                let v = ImageViewer(url: url)
                v.onFailure = { [weak self, weak d] in d.map { self?.fail($0, "macOS couldn't read this image.") } }
                pane = v.loaded ? v : FallbackViewer(url: url, reason: "macOS couldn't read this image.")
            case .video, .audio:
                let v = MediaViewer(url: url, audioOnly: d.kind == .audio)
                v.onFailure = { [weak self, weak d] in d.map { self?.fail($0, "macOS can't play this file.") } }
                pane = v
            case .quickLook:
                pane = QuickLookViewer(url: url)
            case .directory:
                pane = FallbackViewer(url: url, reason: "This is a folder.")
            case .missing:
                pane = FallbackViewer(url: url, reason: "This file doesn't exist anymore.")
            default:
                pane = FallbackViewer(url: url)
            }
        }
        d.pane = pane
        return pane
    }

    /// A native view gave up (an image that won't decode, a video AVFoundation can't play).
    private func fail(_ d: FileDoc, _ reason: String) {
        guard docs[d.id] === d, d.failure == nil else { return }
        d.failure = reason
        d.pane?.close()
        d.pane?.removeFromSuperview()
        d.pane = nil
        if model.selectedCodeTabID == d.id { shownKey = ""; render() }
    }

    private var shownPane: FileViewerPane?

    private func showPane(_ pane: FileViewerPane?) {
        if let old = shownPane, old !== pane {
            old.didHide()
            old.isHidden = true
        }
        shownPane = pane
        guard let pane else { return }
        if pane.superview !== content { fill(content, with: pane) }
        pane.isHidden = false
    }

    // MARK: The bar

    func updateBanner() {
        let b = bannerFor(selectedDoc)
        if b != banner { banner = b }
        barHeight.constant = b == nil ? 0 : 32
    }

    private func bannerFor(_ d: FileDoc?) -> FileBanner? {
        guard let d else { return nil }
        if let e = d.error { return .error(e) }
        if d.recoveryPending { return .recovery(d.name) }
        if d.pendingDisk != nil { return .changedOnDisk(d.name) }
        if d.deleted { return .deleted(d.name, dirty: d.dirty) }
        if d.kind.usesPage, d.failure == nil, let load = d.load {
            switch load.readOnly {
            case .large(let size):
                let big = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                let shown = ByteCountFormatter.string(fromByteCount: Int64(TextFile.previewBytes), countStyle: .file)
                return .note(symbol: "lock", text: "\(big) is too large to edit here. Showing the first \(shown), read-only.")
            case .binary:
                return .note(symbol: "lock", text: "This file has binary data in it, so it's read-only.")
            case .encoding:
                return .note(symbol: "lock", text: "This file isn't UTF-8, so it's read-only. Saving could change its encoding.")
            case nil:
                break
            }
            if d.isLink {
                return .note(symbol: "arrow.turn.down.right", text: "A link to \(Self.abbreviate(d.realPath)). Saving writes there.")
            }
        }
        return nil
    }

    static func abbreviate(_ path: String) -> String {
        let home = Paths.home.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Messages from the page

    private func handle(_ msg: [String: Any]) {
        let base = msg["base"] as? String
        switch msg["type"] as? String {
        case "shown":
            let id = (msg["id"] as? String).flatMap(UUID.init)
            if id == model.selectedCodeTabID { page.webView.alphaValue = 1 }
        case "position":
            guard let id = (msg["id"] as? String).flatMap(UUID.init),
                  let raw = msg["position"], let data = try? JSONSerialization.data(withJSONObject: raw),
                  let position = try? JSONDecoder().decode(EditorPosition.self, from: data) else { return }
            model.setEditorPosition(id, position)
        case "recovery":
            guard msg["generation"] as? String == generation,
                  let id = (msg["id"] as? String).flatMap(UUID.init), let d = docs[id], !d.recoveryPending,
                  let text = msg["text"] as? String, let baseline = msg["baseline"] as? String,
                  let project = projectID(for: id) else { return }
            if text == baseline {
                d.recovery = nil
                recoveryStore.remove(id)
            } else {
                let record = EditorRecoveryRecord(projectID: project, documentID: id, path: d.path, realPath: d.realPath, text: text, baseline: baseline, baselineFingerprint: EditorRecoveryRecord.fingerprint(baseline), updated: Date())
                d.recovery = record
                recoveryStore.put(record)
            }
            setDirty(d, text != baseline)
        case "dirty":
            guard let id = (msg["id"] as? String).flatMap(UUID.init), let d = docs[id] else { return }
            guard msg["generation"] as? String == generation, !d.recoveryPending else { return }
            setDirty(d, msg["dirty"] as? Bool ?? false)
        case "conflict":
            // A reload arrived as you were typing: keep your edits and show the bar.
            guard let id = (msg["id"] as? String).flatMap(UUID.init), let d = docs[id], let load = d.load else { return }
            d.pendingDisk = load
            updateBanner()
        case "open":
            if let p = msg["path"] as? String { FileRouter.shared.open(p, base: base) }
        case "link":
            if let h = msg["href"] as? String { FileRouter.shared.open(h.removingPercentEncoding ?? h, base: base) }
        default:
            break
        }
    }

    private func setDirty(_ d: FileDoc, _ dirty: Bool) {
        d.dirty = dirty
        model.setCodeTabDirty(d.id, dirty)
        if case .deleted = banner { updateBanner() }
    }

    // MARK: Changes on disk

    func diskChanged(_ d: FileDoc) {
        guard docs[d.id] === d else { return }
        guard let fp = FileFingerprint.of(d.realPath) else {
            // Gone. An atomic save puts it back in a moment, and the watch fires again then.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.docs[d.id] === d, FileFingerprint.of(d.realPath) == nil else { return }
                d.deleted = true
                self.updateBanner()
            }
            return
        }
        if d.deleted {
            d.deleted = false
            updateBanner()
        }
        guard fp != d.fingerprint else { return }
        guard d.kind.usesPage else {
            d.fingerprint = fp
            d.pane?.reload()
            return
        }
        guard d.load != nil, d.failure == nil else { return }
        let path = d.path, kind = d.kind
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let load = TextFile.read(path)
            let links = kind == .markdown ? PathDetector.detect(in: load?.text ?? "", base: (path as NSString).deletingLastPathComponent) : []
            DispatchQueue.main.async {
                guard let self, self.docs[d.id] === d, let load else { return }
                self.arrived(load, links: links, for: d)
            }
        }
    }

    /// A fresh read of a text tab's file after it changed on disk.
    private func arrived(_ fresh: TextLoad, links: [DetectedPath], for d: FileDoc) {
        guard let old = d.load else { return }
        d.fingerprint = fresh.fingerprint
        if fresh.text == old.text && fresh.readOnly == old.readOnly {
            d.load?.fingerprint = fresh.fingerprint
            return
        }
        if d.dirty {
            d.links = links
            d.pendingDisk = fresh
            updateBanner()
            return
        }
        apply(fresh, links: links, to: d, force: false)
    }

    /// Puts what's on disk into the tab. Unless `force`, the page refuses if you've just
    /// started typing, and the bar shows instead.
    private func apply(_ fresh: TextLoad, links: [DetectedPath], to d: FileDoc, force: Bool) {
        let old = d.load
        d.load = fresh
        d.links = links
        d.fingerprint = fresh.fingerprint
        d.pendingDisk = nil
        defer { updateBanner() }
        guard d.inPage else { return }
        let sameShape = old?.readOnly == fresh.readOnly && old?.eol == fresh.eol
        if sameShape {
            page.call("reload", ["id": d.id.uuidString, "text": fresh.text, "force": force,
                                 "links": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(links))) ?? []] as [String: Any])
        } else {
            // Read-only or line endings changed: start the document again.
            page.call("close", d.id.uuidString)
            d.inPage = false
            if model.selectedCodeTabID == d.id { shownKey = ""; render() }
        }
    }

    /// Reload from the bar: what's on disk replaces your unsaved changes.
    func reloadFromDisk() {
        guard let d = selectedDoc, let fresh = d.pendingDisk ?? (d.deleted ? nil : TextFile.read(d.path)) else { return }
        d.recovery = nil
        d.recoveryPending = false
        recoveryStore.remove(d.id)
        setDirty(d, false)
        apply(fresh, links: d.links, to: d, force: true)
    }

    /// Keep Mine from the bar: your text stays, and saving will write it over the disk's.
    func keepMine() {
        guard let d = selectedDoc, let fresh = d.pendingDisk else { return }
        d.pendingDisk = nil
        d.load = fresh
        d.fingerprint = fresh.fingerprint
        page.call("rebase", ["id": d.id.uuidString, "text": fresh.text] as [String: Any])
        updateBanner()
    }

    func dismissError() {
        selectedDoc?.error = nil
        updateBanner()
    }

    private func projectID(for id: UUID) -> UUID? {
        if model.codeTabs.contains(where: { $0.id == id }) { return model.currentProject?.id }
        return model.projectPanels.first { $0.value.codeTabs?.contains(where: { $0.id == id }) == true }?.key
    }

    func restoreRecovery() {
        guard let d = selectedDoc, let record = d.recovery else { return }
        d.recoveryPending = false
        if let disk = TextFile.read(d.path) {
            d.load = disk
            d.pendingDisk = record.matchesDisk(disk.text) && record.realPath == TextFile.realPath(d.path) ? nil : disk
        }
        page.call("close", d.id.uuidString)
        d.inPage = false
        shownKey = ""
        render()
        setDirty(d, true)
    }

    func compareRecovery() {
        guard let d = selectedDoc, let recovery = d.recovery else { return }
        let alert = NSAlert()
        alert.messageText = "Recovered changes and current disk file"
        alert.informativeText = "Left: recovered text. Right: current disk. Restore keeps your text unsaved."
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        row.frame = NSRect(x: 0, y: 0, width: 680, height: 340)
        for text in [recovery.text, TextFile.read(d.path)?.text ?? "File unavailable"] {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 330, height: 340))
            view.string = text
            view.isEditable = false
            view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            scroll.documentView = view
            row.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalToConstant: 334).isActive = true
        }
        alert.accessoryView = row
        alert.addButton(withTitle: "Restore unsaved changes")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { restoreRecovery() }
    }

    // MARK: Saving

    var canSaveSelected: Bool {
        guard let d = selectedDoc, !d.recoveryPending, d.pendingDisk == nil, d.kind.usesPage, d.failure == nil, let load = d.load, load.readOnly == nil else { return false }
        return d.dirty || d.deleted
    }

    func saveSelected() {
        guard let id = model.selectedCodeTabID else { return }
        save(id) { _ in }
    }

    /// Saves a tab's editor text to its file. Checks the disk first: if the file changed since
    /// it was loaded and you haven't seen that, the bar shows instead and nothing is written.
    func save(_ id: UUID, completion: @escaping (Bool) -> Void) {
        guard let d = docs[id], !d.recoveryPending, d.pendingDisk == nil, d.kind.usesPage, d.inPage, let load = d.load, load.readOnly == nil else { return completion(false) }
        if d.pendingDisk == nil, let fp = FileFingerprint.of(d.realPath), fp != d.fingerprint {
            if let fresh = TextFile.read(d.path), fresh.text != load.text {
                d.load = fresh
                d.fingerprint = fresh.fingerprint
                d.pendingDisk = fresh
                updateBanner()
                NSSound.beep()
                return completion(false)
            }
            d.fingerprint = fp
        }
        page.webView.evaluateJavaScript("hantuu.snapshot(\(Self.jsString(id.uuidString)))") { [weak self] result, _ in
            guard let self, let snap = result as? [String: Any], let text = snap["text"] as? String,
                  let token = (snap["token"] as? NSNumber)?.intValue, self.docs[id] === d else { return completion(false) }
            guard d.pendingDisk == nil, TextFile.realPath(d.path) == d.realPath,
                  (FileFingerprint.of(d.realPath) == d.fingerprint || (d.deleted && FileFingerprint.of(d.realPath) == nil)) else {
                d.pendingDisk = TextFile.read(d.path)
                d.error = "The file changed before saving. Review the disk changes first."
                self.updateBanner()
                return completion(false)
            }
            do {
                let fp = try TextFile.save(text, bom: load.bom, to: d.path, realPath: d.realPath)
                d.load?.text = text
                d.load?.fingerprint = fp
                d.fingerprint = fp
                d.pendingDisk = nil
                d.deleted = false
                d.error = nil
                if d.kind == .markdown { d.links = PathDetector.detect(in: text, base: (d.path as NSString).deletingLastPathComponent) }
                self.page.call("saved", ["id": id.uuidString, "token": token,
                                         "links": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(d.links))) ?? []] as [String: Any])
                self.updateBanner()
                completion(true)
            } catch {
                d.error = "Couldn't save \(d.name). \(error.localizedDescription)"
                self.updateBanner()
                completion(false)
            }
        }
    }

    static func jsString(_ s: String) -> String {
        String(decoding: (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    /// Saves every tab in `ids`, waiting for each (the text comes from the page). For quitting.
    func saveAllAndWait(_ ids: [UUID], timeout: TimeInterval = 8) -> Bool {
        var left = ids.count
        var ok = true
        for id in ids {
            save(id) { saved in
                ok = ok && saved
                left -= 1
            }
        }
        let end = Date().addingTimeInterval(timeout)
        while left > 0 && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        return ok && left == 0
    }

    // MARK: Unsaved changes

    var unsavedTabs: [CodeTab] { model.allCodeTabs.filter { $0.dirty } }

    func ask(_ tabs: [CodeTab]) -> SaveChoice {
        if let promptOverride { return promptOverride(tabs) }
        let a = NSAlert()
        if tabs.count == 1 {
            a.messageText = "Do you want to save the changes you made to \u{201C}\(tabs[0].name)\u{201D}?"
        } else {
            a.messageText = "You have unsaved changes in \(tabs.count) files. Do you want to save them?"
            a.informativeText = tabs.map(\.name).joined(separator: "\n")
        }
        if a.informativeText.isEmpty { a.informativeText = "Your changes will be lost if you don't save them." }
        a.addButton(withTitle: tabs.count == 1 ? "Save" : "Save All")
        a.addButton(withTitle: "Cancel")
        let discard = a.addButton(withTitle: "Don't Save")
        discard.hasDestructiveAction = true
        switch a.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// Closing a tab: asks first if it has unsaved changes. `close` runs once it's fine to.
    func confirmClose(_ tab: CodeTab, close: @escaping () -> Void) {
        guard tab.dirty else { return close() }
        switch ask([tab]) {
        case .cancel: return
        case .discard: close()
        case .save: save(tab.id) { ok in if ok { close() } }
        }
    }

    /// Quitting: false keeps hantuu open.
    func confirmQuit() -> Bool {
        let tabs = unsavedTabs
        guard !tabs.isEmpty else { return true }
        switch ask(tabs) {
        case .cancel: return false
        case .discard:
            for tab in tabs { recoveryStore.remove(tab.id) }
            return true
        case .save:
            if saveAllAndWait(tabs.map(\.id)) { return true }
            let a = NSAlert()
            a.messageText = "Some files couldn't be saved"
            a.informativeText = "hantuu stayed open so you can try again or copy your changes."
            a.runModal()
            return false
        }
    }
}

/// The bar above a tab: changed on disk, deleted, read-only, or a save that failed.
struct FileViewerBar: View {
    @ObservedObject var state: FileViewerBarState

    var body: some View {
        VStack(spacing: 0) {
            if let b = state.banner {
                HStack(spacing: 8) {
                    Image(systemName: symbol(b))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(tint(b))
                        .frame(width: 14)
                    Text(text(b))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.hSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(text(b))
                    Spacer(minLength: 8)
                    buttons(b)
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(maxHeight: .infinity)
                Rectangle().fill(Color.hDivider).frame(height: 1)
            }
        }
        .background(Color.hChrome)
    }

    private func symbol(_ b: FileBanner) -> String {
        switch b {
        case .recovery: return "arrow.counterclockwise"
        case .changedOnDisk: return "arrow.triangle.2.circlepath"
        case .deleted: return "trash"
        case .note(let s, _): return s
        case .error: return "exclamationmark.triangle"
        }
    }

    private func tint(_ b: FileBanner) -> Color {
        switch b {
        case .changedOnDisk: return Color(nsColor: Theme.needsYou)
        case .error: return Color(nsColor: Theme.error)
        default: return Color.hTertiary
        }
    }

    private func text(_ b: FileBanner) -> String {
        switch b {
        case .recovery(let name): return "Unsaved changes recovered for \(name)."
        case .changedOnDisk(let name): return "\(name) changed on disk."
        case .deleted(let name, let dirty): return dirty ? "\(name) was deleted. Save to put it back." : "\(name) was deleted."
        case .note(_, let t): return t
        case .error(let e): return e
        }
    }

    @ViewBuilder private func buttons(_ b: FileBanner) -> some View {
        switch b {
        case .recovery:
            HStack(spacing: 6) {
                Button("Compare") { state.viewer?.compareRecovery() }.buttonStyle(SmallBarButtonStyle(prominent: false))
                Button("Restore") { state.viewer?.restoreRecovery() }.buttonStyle(SmallBarButtonStyle(prominent: true))
            }
        case .changedOnDisk:
            HStack(spacing: 6) {
                Button("Keep Mine") { state.viewer?.keepMine() }.buttonStyle(SmallBarButtonStyle(prominent: false))
                    .help("Keep your changes. Saving writes them over the file on disk.")
                Button("Reload") { state.viewer?.reloadFromDisk() }.buttonStyle(SmallBarButtonStyle(prominent: true))
                    .help("Show the file as it is on disk now. Your unsaved changes are dropped.")
            }
        case .error:
            Button("Dismiss") { state.viewer?.dismissError() }.buttonStyle(SmallBarButtonStyle(prominent: false))
        default:
            EmptyView()
        }
    }
}

/// BarButtonStyle at the bar's smaller height.
struct SmallBarButtonStyle: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: prominent ? .medium : .regular))
            .foregroundStyle(prominent ? Color.hText : Color.hSecondary)
            .padding(.horizontal, 9)
            .frame(height: 21)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.hInk(configuration.isPressed ? 0.12 : (prominent ? 0.08 : 0.0))))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.hDivider, lineWidth: prominent ? 0 : 1))
            .contentShape(Rectangle())
    }
}

/// File > Save (Cmd-S), enabled when the Code tab shows a text file with unsaved changes.
final class FileViewerMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = FileViewerMenuTarget()

    static func saveItem() -> NSMenuItem {
        let it = NSMenuItem(title: "Save", action: #selector(save(_:)), keyEquivalent: "s")
        it.keyEquivalentModifierMask = [.command]
        it.target = shared
        return it
    }

    @objc func save(_ sender: Any?) { AppModel.shared.fileViewer?.saveSelected() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let m = AppModel.shared
        guard m.panelVisible, m.panelTab == .code, let v = m.fileViewer else { return false }
        return v.canSaveSelected
    }
}
