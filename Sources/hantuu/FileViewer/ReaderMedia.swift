import AppKit
import PDFKit
import WebKit

/// Pictures of a PDF's first page for the reader's compact previews (hantuu://thumb/<path>).
/// A picture is light and crisp, and unlike an embedded PDF it never catches the scroll wheel.
enum PDFThumbnails {
    private static let cache = NSCache<NSString, NSData>()

    /// A PNG of the first page, `height` pixels tall. Nil when it isn't a PDF that opens.
    static func png(path: String, height: Int) -> Data? {
        let h = max(40, min(height, 1600))
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(mtime)|\(h)" as NSString
        if let hit = cache.object(forKey: key) { return hit as Data }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), !doc.isLocked, let page = doc.page(at: 0) else { return nil }
        var box = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { box = CGSize(width: box.height, height: box.width) }
        guard box.width > 0, box.height > 0 else { return nil }
        let w = Int((CGFloat(h) * box.width / box.height).rounded())
        // Drawn at exactly this many pixels, on white like a printed page.
        guard w > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(w) / box.width, y: CGFloat(h) / box.height)
        page.draw(with: .cropBox, to: ctx)
        guard let cg = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        cache.setObject(png as NSData, forKey: key)
        return png
    }
}

/// Esc shrinks an opened-out preview in the reader. In reader mode the page never has the
/// keyboard (the message box does), so while something is opened out this catches Esc for
/// the reader's window before the message box sees it. With nothing opened out, Esc goes on
/// to the message box as before (where it stops the agent).
final class ReaderMediaKeys {
    private weak var page: WebPage?
    private var monitor: Any?
    private(set) var expanded = 0

    init(page: WebPage) { self.page = page }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    /// The page reports how many previews are opened out.
    func update(expanded count: Int) {
        expanded = count
        if count > 0, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handle(e) ?? e }
        } else if count == 0, let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    /// Returns nil when Esc was used to shrink a preview.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 53, expanded > 0, let page, page.ready,
              !page.webView.isHiddenOrHasHiddenAncestor, page.webView.window != nil,
              event.window === page.webView.window,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
        // Esc in a terminal or the Code tab is theirs.
        if let v = event.window?.firstResponder as? NSView, v is TerminalView || v.hantuuIsInCodeViewer { return event }
        page.call("collapseMedia")
        expanded = 0
        return nil
    }
}
