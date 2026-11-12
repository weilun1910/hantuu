import AppKit

/// Historical lines are shown read-only, never routed to the same number in today's file.
final class HistoricalSourceWindow: NSObject, NSWindowDelegate {
    private static var windows: [HistoricalSourceWindow] = []
    private let window: NSWindow
    private init(text: String, title: String, line: Int) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = title + " (read-only)"
        window.delegate = self
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.string = text
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        scroll.documentView = view
        window.contentView?.addSubview(scroll)
        let lines = text.components(separatedBy: "\n")
        let offset = lines.prefix(max(0, min(line - 1, lines.count))).reduce(0) { $0 + ($1 as NSString).length + 1 }
        let range = NSRange(location: min(offset, (text as NSString).length), length: 0)
        view.setSelectedRange(range)
        view.scrollRangeToVisible(range)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
    static func open(snapshot: GitReviewSnapshot, file: ChangedFile, line: Int, old: Bool) {
        let root = snapshot.info.root
        let path = old ? file.oldPath ?? file.path : file.path
        let revision = old ? (snapshot.scope == .unstaged ? "" : snapshot.baseRevision) : (snapshot.tipRevision ?? "HEAD")
        let spec = revision.isEmpty ? ":" + path : revision + ":" + path
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Git.run(["show", "--no-ext-diff", "--no-textconv", spec], in: root)
            DispatchQueue.main.async {
                guard result.ok else {
                    let a = NSAlert(); a.messageText = "Historical source unavailable"; a.informativeText = result.err; a.runModal(); return
                }
                let controller = HistoricalSourceWindow(text: result.text, title: path + " | " + (revision.isEmpty ? "index" : String(revision.prefix(10))), line: line)
                windows.append(controller)
            }
        }
    }
    func windowWillClose(_ notification: Notification) { Self.windows.removeAll { $0 === self } }
}
