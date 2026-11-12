import AppKit

/// A second view of a file. Editing stays with the Code tab's single save/conflict owner.
/// Text mirrors that owner's live buffer, including unsaved changes, without another writer.
final class FileDocumentWindow: NSWindowController, NSWindowDelegate {
    private weak var viewer: FileViewerController?
    let fileDocument: FileDoc
    private var pane: FileViewerPane?
    private var textView: NSTextView?
    private var timer: Timer?
    private var watch: FileWatch?
    private var reading = false
    var onClose: (() -> Void)?

    init(owner: FileViewerController, document: FileDoc) {
        self.viewer = owner
        self.fileDocument = document
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = document.name
        window.subtitle = "Read-only view"
        window.representedURL = URL(fileURLWithPath: document.path)
        window.minSize = NSSize(width: 380, height: 320)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        let url = URL(fileURLWithPath: document.path)
        switch document.kind {
        case .pdf: pane = PDFViewer(url: url)
        case .image: pane = ImageViewer(url: url)
        default:
            if document.kind.usesPage {
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 760))
                scroll.hasVerticalScroller = true
                scroll.hasHorizontalScroller = true
                scroll.autohidesScrollers = true
                let text = NSTextView(frame: scroll.bounds)
                text.isEditable = false
                text.isRichText = false
                text.isHorizontallyResizable = true
                text.isVerticallyResizable = true
                text.minSize = .zero
                text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                text.textContainer?.containerSize = text.maxSize
                text.textContainer?.widthTracksTextView = false
                text.textContainerInset = NSSize(width: 20, height: 16)
                text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                text.textColor = .textColor
                text.backgroundColor = .textBackgroundColor
                text.string = document.recovery?.text ?? document.load?.text ?? "Loading file…"
                scroll.documentView = text
                window.contentView = scroll
                textView = text
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshText() }
                refreshText()
            } else {
                pane = QuickLookViewer(url: url)
            }
        }
        if let pane { window.contentView = pane }
        watch = FileWatch(path: document.realPath) { [weak self] in
            self?.pane?.reload()
            self?.refreshText()
        }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refreshText() {
        guard textView != nil, !reading else { return }
        if let viewer, viewer.docs[fileDocument.id] === fileDocument, fileDocument.recoveryPending, let recovery = fileDocument.recovery {
            showText(recovery.text)
        } else if let viewer, viewer.docs[fileDocument.id] === fileDocument, fileDocument.inPage {
            reading = true
            viewer.page.webView.evaluateJavaScript("hantuu.snapshot(\(FileViewerController.jsString(fileDocument.id.uuidString)))") { [weak self] (result: Any?, _: Error?) in
                guard let self else { return }
                self.reading = false
                if let text = (result as? [String: Any])?["text"] as? String { self.showText(text) }
            }
        } else if let text = TextFile.read(fileDocument.path)?.text {
            showText(text)
        }
    }

    private func showText(_ text: String) {
        guard let textView, textView.string != text else { return }
        let selection = textView.selectedRange()
        let origin = textView.enclosingScrollView?.contentView.bounds.origin
        textView.string = text
        textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        if let origin { textView.enclosingScrollView?.contentView.scroll(to: origin) }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        watch?.stop()
        watch = nil
        pane?.close()
        onClose?()
    }

    deinit { timer?.invalidate(); watch?.stop() }
}
