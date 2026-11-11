import AppKit
import PDFKit
import WebKit

/// PDFKit page images and page sizes for the reader. All document access is serialized.
/// The reader never embeds a PDF plugin; the Code tab keeps the native interactive viewer.
enum PDFThumbnails {
    private static let queue = DispatchQueue(label: "local.hantuu.pdf-pages", qos: .userInitiated)
    private static let cache: NSCache<NSString, NSData> = {
        let value = NSCache<NSString, NSData>()
        value.totalCostLimit = 64 * 1024 * 1024
        value.countLimit = 128
        return value
    }()
    private static let documents: NSCache<NSString, PDFDocument> = {
        let value = NSCache<NSString, PDFDocument>()
        value.countLimit = 4
        return value
    }()

    private struct PageSize: Encodable { let width: CGFloat; let height: CGFloat }
    private struct Info: Encodable { let pages: [PageSize] }

    private static func fileKey(_ path: String) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return "\(path)|\(mtime)|\(bytes)"
    }

    private static func document(_ path: String, key: String) -> PDFDocument? {
        if let hit = documents.object(forKey: key as NSString) { return hit }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), !doc.isLocked else { return nil }
        documents.setObject(doc, forKey: key as NSString)
        return doc
    }

    private static func size(_ page: PDFPage) -> CGSize? {
        guard let ref = page.pageRef else { return nil }
        // Match getDrawingTransform's effective box, including PDFs whose crop box
        // extends beyond their media box. Otherwise the bitmap can contain white bands.
        let bounds = ref.getBoxRect(.cropBox).intersection(ref.getBoxRect(.mediaBox))
        guard !bounds.isNull, !bounds.isEmpty else { return nil }
        var box = bounds.size
        if ref.rotationAngle % 180 != 0 { box = CGSize(width: box.height, height: box.width) }
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { return nil }
        return box
    }

    /// This only reads page boxes. Raster work starts when an individual page is requested.
    static func info(path: String) -> Data? {
        queue.sync {
            let key = fileKey(path)
            let cacheKey = "\(key)|info" as NSString
            if let hit = cache.object(forKey: cacheKey) { return hit as Data }
            guard let doc = document(path, key: key), doc.pageCount > 0 else { return nil }
            var pages: [PageSize] = []
            for index in 0..<doc.pageCount {
                guard let page = doc.page(at: index), let box = size(page) else { return nil }
                pages.append(PageSize(width: box.width, height: box.height))
            }
            guard let data = try? JSONEncoder().encode(Info(pages: pages)) else { return nil }
            cache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
            return data
        }
    }

    /// Pages are numbered from one. Width takes priority; height keeps the compact URL working.
    static func png(path: String, page number: Int = 1, width: Int? = nil, height: Int = 400) -> Data? {
        queue.sync {
            let key = fileKey(path)
            guard number > 0, let doc = document(path, key: key), number <= doc.pageCount,
                  let page = doc.page(at: number - 1), let box = size(page), let ref = page.pageRef else { return nil }
            let requestedScale: CGFloat
            if let width { requestedScale = CGFloat(max(40, min(width, 3200))) / box.width }
            else { requestedScale = CGFloat(max(40, min(height, 1600))) / box.height }
            // Bound both dimensions and total pixels even for unusually tall or wide pages.
            let scale = min(requestedScale, 4096 / max(box.width, box.height), sqrt(8_000_000 / box.width / box.height))
            let w = max(1, Int((box.width * scale).rounded()))
            let h = max(1, Int((box.height * scale).rounded()))
            let cacheKey = "\(key)|\(number)|\(w)x\(h)" as NSString
            if let hit = cache.object(forKey: cacheKey) { return hit as Data }
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            let rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(rect)
            ctx.interpolationQuality = .high
            // getDrawingTransform only scales pages down. Scale the bitmap explicitly,
            // then ask it to handle crop offsets and rotation at the page's own size.
            // Passing the pixel rectangle directly leaves small pages centered in white.
            ctx.scaleBy(x: CGFloat(w) / box.width, y: CGFloat(h) / box.height)
            let pageRect = CGRect(origin: .zero, size: box)
            ctx.concatenate(ref.getDrawingTransform(.cropBox, rect: pageRect, rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(ref)
            guard let cg = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
            cache.setObject(png as NSData, forKey: cacheKey, cost: w * h * 4)
            return png
        }
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
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self else { return e }
                // A nil result consumes Esc. Coalescing it with the original event would
                // also send Esc to the composer, where it can stop the running agent.
                return self.handle(e)
            }
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
        update(expanded: 0)
        return nil
    }
}
