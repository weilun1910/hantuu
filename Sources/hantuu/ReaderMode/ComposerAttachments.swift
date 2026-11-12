import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A file waiting in the message box to go out with the next message: one you dropped, picked
/// with the paperclip or copied in Finder, or an image pasted without a file of its own, which
/// hantuu saves first (see PastedImages).
enum AttachmentPreparation: Equatable, Codable {
    case preparing
    case ready
    case failed(String)

    var title: String {
        switch self { case .preparing: return "Preparing"; case .ready: return "Ready"; case .failed: return "Failed" }
    }
}

struct ComposerAttachment: Equatable, Identifiable, Codable {
    let id: UUID
    var preparation: AttachmentPreparation
    var preparedURL: URL?
    /// The file as you chose it. The chip shows its name.
    let url: URL
    /// hantuu wrote this file from pasted image data.
    let pasted: Bool
    /// What the chip says. A pasted image has no name of its own.
    var label: String

    init(url: URL, pasted: Bool = false, label: String? = nil, id: UUID = UUID(), preparation: AttachmentPreparation = .ready, preparedURL: URL? = nil) {
        self.id = id
        self.preparation = preparation
        self.preparedURL = preparedURL
        self.url = url
        self.pasted = pasted
        self.label = label ?? url.lastPathComponent
    }

    var isFolder: Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

    /// Attachments for what a paste or a drop held. Pictures without a file are saved to
    /// PastedImages.folder first; failures stay visible so the user can retry or remove them.
    static func make(from content: ComposerPasteboard.Content, existing: [ComposerAttachment] = [], now: Date = Date()) -> [ComposerAttachment] {
        var pastedCount = existing.filter(\.pasted).count
        func pastedLabel() -> String {
            pastedCount += 1
            return pastedCount == 1 ? "Pasted image" : "Pasted image \(pastedCount)"
        }
        switch content {
        case .files(let urls):
            return urls.filter(\.isFileURL).map { ComposerAttachment(url: $0, preparation: PastedImages.preparation(for: $0)) }
        case .images(let images), .text(_, let images):
            return images.map { img in
                let label = pastedLabel()
                guard let url = PastedImages.save(img.data, type: img.type, now: now) else {
                    return ComposerAttachment(url: PastedImages.newURL(ext: "png", now: now), pasted: true, label: label,
                        preparation: .failed("Could not save pasted image. Paste it again or remove this attachment."))
                }
                return ComposerAttachment(url: url, pasted: true, label: label,
                    preparation: PastedImages.isPending(url) ? .preparing : .ready)
            }
        case .pdf(let data):
            let url = PastedImages.newURL(ext: "pdf", now: now)
            guard (try? data.write(to: url, options: .atomic)) != nil else {
                return [ComposerAttachment(url: url, pasted: true, label: "Pasted PDF", preparation: .failed("Could not save pasted PDF. Paste it again or remove this attachment."))]
            }
            return [ComposerAttachment(url: url, pasted: true, label: "Pasted PDF")]
        case .nothing:
            return []
        }
    }

    /// An image either agent attaches as an image when it's pasted as a path.
    var isImage: Bool { AttachmentFormats.sendable.contains(url.pathExtension.lowercased()) }

    /// Any picture, including ones that need converting before an agent takes them.
    var isPicture: Bool {
        guard !isFolder, let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .image)
    }
}

enum AttachmentFormats {
    /// What Claude Code and Codex both read as an image from a pasted path.
    static let sendable: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    /// Pasteboard image types in the order they're preferred: ones that can be saved as they
    /// are first, then ones that need converting.
    static let pasteboardImageTypes: [NSPasteboard.PasteboardType] = [
        .png,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.webP.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        .tiff,
    ]
}

/// Where pasted images are saved: `<data dir>/attachments/`, named by the time they were pasted
/// so the folder sorts oldest first. The agents read them from there when a message is sent.
/// Files older than a week are deleted the next time hantuu starts. By then the agents have
/// their own copy in the conversation, and the reader shows the image from the transcript.
enum PastedImages {
    static var folder: URL { Paths.dataDir.appendingPathComponent("attachments", isDirectory: true) }
    static let keep: TimeInterval = 7 * 24 * 3600

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    /// A new file name in the folder: "Pasted 2026-11-11 at 14.03.27.png", with " 2", " 3" and
    /// so on for more in the same second.
    static func newURL(ext: String, now: Date = Date(), in dir: URL? = nil) -> URL {
        let dir = dir ?? folder
        Paths.ensure(dir)
        let base = "Pasted \(stamp.string(from: now))"
        var url = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// A new folder for files a drop promised (Photos, Mail): "Dropped 2026-11-11 at 14.03.27".
    static func newFolder(now: Date = Date(), in dir: URL? = nil) -> URL {
        let dir = dir ?? folder
        let base = "Dropped \(stamp.string(from: now))"
        var url = dir.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        Paths.ensure(url)
        return url
    }

    /// Saves image data from the pasteboard. PNG, JPEG, GIF and WebP are written as they came;
    /// anything else (TIFF from Preview or Safari, HEIC) becomes a PNG, which both agents read.
    /// Converting a big picture can take a second, so that happens in the background: the file
    /// is named at once, and `whenReady` says when it's written.
    static func save(_ data: Data, type: NSPasteboard.PasteboardType, now: Date = Date(), in dir: URL? = nil) -> URL? {
        let ut = UTType(type.rawValue)
        if let ut, let ext = ut.preferredFilenameExtension, AttachmentFormats.sendable.contains(ext.lowercased()) {
            let url = newURL(ext: ext.lowercased() == "jpeg" ? "jpg" : ext.lowercased(), now: now, in: dir)
            do { try data.write(to: url, options: .atomic) } catch { return nil }
            return url
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        let url = newURL(ext: "png", now: now, in: dir)
        reserve(url) { writePNG(from: src, to: url) }
        return url
    }

    /// A picture file the agents can't read as an image (TIFF, HEIC, BMP), converted to a PNG
    /// next to the pasted ones, in the background like `save`. Nil when it can't be read.
    static func convert(_ file: URL, now: Date = Date(), in dir: URL? = nil) -> URL? {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        let dir = dir ?? folder
        Paths.ensure(dir)
        let name = file.deletingPathExtension().lastPathComponent
        var url = dir.appendingPathComponent("\(stamp.string(from: now)) \(name).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stamp.string(from: now)) \(name) \(n).png")
            n += 1
        }
        reserve(url) { writePNG(from: src, to: url) }
        return url
    }

    private static func writePNG(from src: CGImageSource, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImageFromSource(dest, src, 0, nil)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: Files still being written

    /// Paths being written in the background, with what to run once each is done. Main thread.
    private static var waiting: [String: [() -> Void]] = [:]
    private static var failures: [String: String] = [:]
    /// Configure before cleanup using persisted draft and queue references. Nil skips deletion.
    static var protectedPathsProvider: (() -> Set<String>)?

    static func preparation(for url: URL) -> AttachmentPreparation {
        if isPending(url) { return .preparing }
        if let error = failures[url.path] { return .failed(error) }
        return .ready
    }

    static func beginPromise(_ url: URL) {
        waiting[url.path] = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            guard waiting[url.path] != nil else { return }
            finishPromise(url, error: "File drop did not finish. Drop the file again or remove this attachment.")
        }
    }
    static func finishPromise(_ url: URL, error: String?) {
        failures[url.path] = error
        (waiting.removeValue(forKey: url.path) ?? []).forEach { $0() }
    }

    /// Claims the name with an empty file, so a second paste in the same second gets another,
    /// and writes the real file off the main thread.
    private static func reserve(_ url: URL, write: @escaping () -> Bool) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        waiting[url.path] = []
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = write()
            DispatchQueue.main.async {
                if !ok {
                    failures[url.path] = "Image conversion failed. Retry or remove this attachment."
                    try? FileManager.default.removeItem(at: url)
                    Log.write("reader mode: couldn't save a pasted picture as PNG")
                }
                (waiting.removeValue(forKey: url.path) ?? []).forEach { $0() }
            }
        }
    }

    static func isPending(_ url: URL) -> Bool { waiting[url.path] != nil }

    /// Runs `block` once the file is written, at once if it already is. Main thread.
    static func whenReady(_ url: URL, _ block: @escaping () -> Void) {
        if waiting[url.path] != nil { waiting[url.path]?.append(block) } else { block() }
    }

    /// Deletes files in the folder last changed more than `keep` ago. Returns how many.
    @discardableResult
    static func cleanUp(now: Date = Date(), in dir: URL? = nil, protectedPaths: Set<String> = []) -> Int {
        let dir = dir ?? folder
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var removed = 0
        for f in files {
            let path = f.standardizedFileURL.path
            guard !protectedPaths.contains(where: { p in
                let protected = URL(fileURLWithPath: p).standardizedFileURL.path
                return protected == path || protected.hasPrefix(path + "/")
            }) else { continue }
            // Pasted files, and the folders that dropped file promises land in. Never a link.
            guard let v = try? f.resourceValues(forKeys: keys), v.isSymbolicLink != true,
                  v.isRegularFile == true || v.isDirectory == true,
                  let m = v.contentModificationDate, now.timeIntervalSince(m) > keep else { continue }
            if (try? fm.removeItem(at: f)) != nil { removed += 1 }
        }
        return removed
    }

    private static var cleanedThisLaunch = false

    /// Once per launch, off the main thread.
    static func cleanUpOnce() {
        guard !cleanedThisLaunch, let protectedPathsProvider else { return }
        let protected = protectedPathsProvider().union(waiting.keys)
        cleanedThisLaunch = true
        DispatchQueue.global(qos: .utility).async {
            let n = cleanUp(protectedPaths: protected)
            if n > 0 { Log.write("reader mode: deleted \(n) pasted images older than a week") }
        }
    }
}

/// What a paste or a drop holds, as far as the message box is concerned.
enum ComposerPasteboard {
    struct Image: Equatable {
        var data: Data
        var type: NSPasteboard.PasteboardType
    }

    enum Content: Equatable {
        /// Files, from Finder (Cmd-C or a drag) or another app.
        case files([URL])
        /// Picture data with no file behind it: a screenshot copied to the clipboard, an image
        /// copied in a browser or Preview.
        case images([Image])
        /// Text, pasted as it always was. Rich text can carry pictures too, which come along
        /// as attachments.
        case text(String, images: [Image])
        /// A PDF with no file (copied from Preview with nothing else).
        case pdf(Data)
        case nothing
    }

    static func read(_ pb: NSPasteboard) -> Content {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { return .files(urls) }

        let text = pb.string(forType: .string)
        let meaningful = text.map(isMeaningfulText) ?? false
        if meaningful, let text {
            return .text(text, images: richTextImages(pb))
        }
        let images = (pb.pasteboardItems ?? []).compactMap(image(in:))
        if !images.isEmpty { return .images(images) }
        if let text, !text.isEmpty { return .text(text, images: []) }
        if let pdf = pb.data(forType: .pdf) { return .pdf(pdf) }
        return .nothing
    }

    /// Text worth pasting as text. A lone web address next to a picture (Safari's Copy Image)
    /// or nothing but the picture placeholder from rich text doesn't count.
    static func isMeaningfulText(_ s: String) -> Bool {
        let t = s.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if !t.contains(where: \.isWhitespace), let u = URL(string: t), let scheme = u.scheme?.lowercased(),
           ["http", "https", "data", "blob"].contains(scheme) {
            return false
        }
        return true
    }

    /// The best picture in one pasteboard item.
    static func image(in item: NSPasteboardItem) -> Image? {
        for t in AttachmentFormats.pasteboardImageTypes where item.types.contains(t) {
            if let d = item.data(forType: t), !d.isEmpty { return Image(data: d, type: t) }
        }
        // Any other picture type an app offers, except icons.
        for t in item.types {
            guard let ut = UTType(t.rawValue), ut.conforms(to: .image), !ut.conforms(to: .icns) else { continue }
            if let d = item.data(forType: t), !d.isEmpty { return Image(data: d, type: t) }
        }
        return nil
    }

    /// Pictures inside rich text (RTFD), like a note copied with an image in it.
    static func richTextImages(_ pb: NSPasteboard) -> [Image] {
        guard let data = pb.data(forType: .rtfd) ?? pb.data(forType: NSPasteboard.PasteboardType("com.apple.flat-rtfd")),
              let s = NSAttributedString(rtfd: data, documentAttributes: nil) else { return [] }
        var out: [Image] = []
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            guard let a = value as? NSTextAttachment, let w = a.fileWrapper, w.isRegularFile,
                  let d = w.regularFileContents, let name = w.preferredFilename ?? w.filename,
                  let ut = UTType(filenameExtension: (name as NSString).pathExtension), ut.conforms(to: .image) else { return }
            out.append(Image(data: d, type: NSPasteboard.PasteboardType(ut.identifier)))
        }
        return out
    }

    static func isImageType(_ t: NSPasteboard.PasteboardType) -> Bool {
        if AttachmentFormats.pasteboardImageTypes.contains(t) { return true }
        guard let ut = UTType(t.rawValue) else { return false }
        return ut.conforms(to: .image) && !ut.conforms(to: .icns)
    }

    /// Something on the pasteboard the box can paste: text, files or a picture. Looks at the
    /// types only, since menus ask often.
    static func hasContent(_ pb: NSPasteboard) -> Bool {
        let types = pb.types ?? []
        return types.contains { $0 == .string || $0 == .fileURL || $0 == .pdf || isImageType($0) }
    }

    /// A drop that should become attachments rather than text typed where it lands. Asked on
    /// every move of a drag, so it reads no picture data.
    static func dropHasAttachment(_ pb: NSPasteboard) -> Bool {
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        if pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) { return true }
        if let t = pb.string(forType: .string), isMeaningfulText(t) { return false }
        let types = pb.types ?? []
        if types.contains(where: isImageType) { return true }
        return types.contains(.pdf)
    }

    /// Takes a drop's files, file promises (from Photos or Mail, saved into the attachments
    /// folder) or picture data, and hands them over as they arrive.
    @discardableResult
    static func receiveDrop(_ info: NSDraggingInfo, deliver: @escaping (Content) -> Void) -> Bool {
        let pb = info.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            deliver(.files(urls))
            return true
        }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated
            for p in promises {
                let dir = PastedImages.newFolder()
                let placeholders = p.fileNames.map { dir.appendingPathComponent($0) }
                placeholders.forEach { PastedImages.beginPromise($0) }
                deliver(.files(placeholders))
                p.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: queue) { url, error in
                    DispatchQueue.main.async {
                        PastedImages.finishPromise(url, error: error.map { "File drop failed: \($0.localizedDescription). Drop the file again or remove this attachment." })
                    }
                }
            }
            return true
        }
        switch read(pb) {
        case .images, .pdf:
            deliver(read(pb))
            return true
        default:
            return false
        }
    }

    /// Everything the box can take from a drop or a paste.
    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .string, .pdf] + AttachmentFormats.pasteboardImageTypes
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
}

// MARK: - Chips

/// A small preview of a picture for its chip. Made off the main thread and kept, since a big
/// image can take a moment to decode.
enum AttachmentThumbnails {
    private static let cache = NSCache<NSURL, NSImage>()
    private static let queue = DispatchQueue(label: "hantuu.attachment-thumbnails", qos: .userInitiated)

    static func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    static func load(_ url: URL, pixels: Int = 72, done: @escaping (NSImage) -> Void) {
        if let img = cached(url) { return done(img) }
        queue.async {
            let img = thumbnail(url, pixels: pixels) ?? NSWorkspace.shared.icon(forFile: url.path)
            DispatchQueue.main.async {
                cache.setObject(img, forKey: url as NSURL)
                done(img)
            }
        }
    }

    static func thumbnail(_ url: URL, pixels: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

enum ChipStyle {
    static let height: CGFloat = 28
    static let gap: CGFloat = 6
    static let thumb: CGFloat = 20
    static let maxLabel: CGFloat = 180
    static let font = NSFont.systemFont(ofSize: 12)
    static let fill = Theme.ink(0.06, light: 0.045)
    static let fillHover = Theme.ink(0.09, light: 0.07)
    static let label = Theme.pair(dark: NSColor(white: 0.80, alpha: 1), light: NSColor(white: 0.26, alpha: 1))
    static let hairline = Theme.ink(0.08, light: 0.08)
    static let icon = Theme.pair(dark: NSColor(white: 1, alpha: 0.55), light: NSColor(white: 0, alpha: 0.5))
}

/// One attachment: a thumbnail or file icon, the name, and a small x to take it out.
final class AttachmentChip: NSView {
    private(set) var attachment: ComposerAttachment
    let retry = NSButton(title: "Retry", target: nil, action: nil)
    var onRetry: (() -> Void)?
    let remove = ChipRemoveButton()
    var onRemove: (() -> Void)?
    private var image: NSImage?
    /// Worked out once, since it asks the file system.
    private let picture: Bool
    private let symbol: String
    private var hovering = false { didSet { needsDisplay = true; remove.chipHovered = hovering } }

    init(_ attachment: ComposerAttachment) {
        self.attachment = attachment
        picture = attachment.isPicture
        symbol = picture ? "" : Self.symbol(for: attachment)
        super.init(frame: .zero)
        toolTip = attachment.pasted ? "Pasted image" : attachment.url.path
        addSubview(remove)
        retry.bezelStyle = .inline
        retry.font = .systemFont(ofSize: 11)
        retry.target = self
        retry.action = #selector(retryTapped)
        addSubview(retry)
        refreshState()
        if attachment.preparation == .preparing && PastedImages.isPending(attachment.url) {
            PastedImages.whenReady(attachment.url) { [weak self] in
                guard let self else { return }
                self.attachment.preparation = PastedImages.preparation(for: attachment.url)
                self.refreshState()
                self.superview?.needsLayout = true
            }
        }
        remove.target = self
        remove.action = #selector(removeTapped)
        remove.setAccessibilityLabel("Remove \(attachment.label)")
        if picture {
            image = AttachmentThumbnails.cached(attachment.url)
            if image == nil {
                let url = attachment.url
                // A picture still being converted gets its thumbnail once it's written.
                PastedImages.whenReady(url) { [weak self] in
                    AttachmentThumbnails.load(url) { img in
                        self?.image = img
                        self?.needsDisplay = true
                    }
                }
            }
        }
    }

    private var displayLabel: String { attachment.label + " | " + attachment.preparation.title }
    private func refreshState() {
        if case .failed(let reason) = attachment.preparation {
            retry.isHidden = false
            toolTip = attachment.url.path + "\n" + reason
        } else { retry.isHidden = true; toolTip = attachment.url.path + "\n" + attachment.preparation.title }
        needsDisplay = true
        needsLayout = true
    }
    @objc private func retryTapped() { onRetry?() }

    /// A plain symbol for a file that isn't a picture, in the label's grey, so a row of chips
    /// doesn't turn into a row of app icons.
    static func symbol(for a: ComposerAttachment) -> String {
        if a.isFolder { return "folder" }
        guard let t = UTType(filenameExtension: a.url.pathExtension) else { return "doc" }
        if t.conforms(to: .pdf) { return "doc.richtext" }
        if t.conforms(to: .spreadsheet) || t.conforms(to: .commaSeparatedText) || t.conforms(to: .tabSeparatedText) { return "tablecells" }
        if t.conforms(to: .movie) { return "film" }
        if t.conforms(to: .audio) { return "waveform" }
        if t.conforms(to: .archive) { return "doc.zipper" }
        if t.conforms(to: .sourceCode) || t.conforms(to: .script) || t.conforms(to: .json) { return "chevron.left.forwardslash.chevron.right" }
        if t.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static func labelWidth(_ text: String) -> CGFloat {
        let w = (text as NSString).size(withAttributes: [.font: ChipStyle.font]).width
        return min(ceil(w), ChipStyle.maxLabel)
    }

    /// 4 + thumbnail + 7 + name + 4 + x (16) + 4.
    var preferredWidth: CGFloat { 4 + ChipStyle.thumb + 7 + Self.labelWidth(displayLabel) + 4 + 16 + 4 + (retry.isHidden ? 0 : 40) }

    override func layout() {
        super.layout()
        retry.frame = NSRect(x: bounds.maxX - 62, y: (bounds.height - 20) / 2, width: 40, height: 20)
        remove.frame = NSRect(x: bounds.maxX - 20, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    // A double click opens the file in its usual app, the way Finder would.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        NSWorkspace.shared.open(attachment.url)
    }

    @objc private func removeTapped() { onRemove?() }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        (hovering ? ChipStyle.fillHover : ChipStyle.fill).setFill()
        bg.fill()

        let t = NSRect(x: 4, y: (bounds.height - ChipStyle.thumb) / 2, width: ChipStyle.thumb, height: ChipStyle.thumb)
        if !picture {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            if let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                // Resolved now, while this view's appearance is the current one.
                let tint = ChipStyle.icon.usingColorSpace(.sRGB) ?? .gray
                let tinted = NSImage(size: sym.size, flipped: false) { r in
                    sym.draw(in: r)
                    tint.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                let sz = sym.size
                tinted.draw(in: NSRect(x: t.midX - sz.width / 2, y: t.midY - sz.height / 2, width: sz.width, height: sz.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        } else if let image {
            // The picture fills a small rounded square, cropped to it.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: t, xRadius: 3.5, yRadius: 3.5).addClip()
            let s = image.size
            let scale = max(t.width / max(s.width, 1), t.height / max(s.height, 1))
            let d = NSSize(width: s.width * scale, height: s.height * scale)
            image.draw(in: NSRect(x: t.midX - d.width / 2, y: t.midY - d.height / 2, width: d.width, height: d.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
            ChipStyle.hairline.setStroke()
            let edge = NSBezierPath(roundedRect: t.insetBy(dx: 0.25, dy: 0.25), xRadius: 3.5, yRadius: 3.5)
            edge.lineWidth = 0.5
            edge.stroke()
        }

        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [.font: ChipStyle.font, .foregroundColor: ChipStyle.label, .paragraphStyle: p]
        let lw = min(Self.labelWidth(displayLabel), max(0, bounds.width - 55 - (retry.isHidden ? 0 : 40)))
        let lh = ceil(ChipStyle.font.ascender - ChipStyle.font.descender)
        (displayLabel as NSString).draw(with: NSRect(x: t.maxX + 7, y: (bounds.height - lh) / 2, width: lw, height: lh),
                                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Attachment \(attachment.label), \(attachment.preparation.title)" }
}

/// The x on a chip. Quiet until the pointer is over the chip.
final class ChipRemoveButton: NSControl {
    var chipHovered = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)), let action { sendAction(action, to: target) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.ink(0.1).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        let alpha: CGFloat = hovering ? 0.85 : (chipHovered ? 0.6 : 0.38)
        Theme.pair(dark: NSColor(white: 1, alpha: alpha), light: NSColor(white: 0, alpha: alpha * 0.9)).setStroke()
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let r: CGFloat = 3.2
        let x = NSBezierPath()
        x.lineWidth = 1.2
        x.lineCapStyle = .round
        x.move(to: NSPoint(x: c.x - r, y: c.y - r))
        x.line(to: NSPoint(x: c.x + r, y: c.y + r))
        x.move(to: NSPoint(x: c.x - r, y: c.y + r))
        x.line(to: NSPoint(x: c.x + r, y: c.y - r))
        x.stroke()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        guard let action else { return false }
        return sendAction(action, to: target)
    }
}

/// The row of chips at the top of the message box. Chips wrap onto more rows when there are
/// many; past three rows the strip scrolls.
final class AttachmentStrip: NSView {
    private(set) var chips: [AttachmentChip] = []
    var onRemove: ((ComposerAttachment.ID) -> Void)?
    var onRetry: ((ComposerAttachment.ID) -> Void)?
    static let maxRows = 3

    override var isFlipped: Bool { true }

    func show(_ attachments: [ComposerAttachment]) {
        guard attachments != chips.map(\.attachment) else { return }
        // Keep chips that are still there, so their thumbnails don't flicker.
        var keep: [ComposerAttachment.ID: AttachmentChip] = [:]
        for c in chips { keep[c.attachment.id] = c }
        var next: [AttachmentChip] = []
        for a in attachments {
            let old = keep.removeValue(forKey: a.id)
            let chip: AttachmentChip
            if let old, old.attachment == a { chip = old }
            else { old?.removeFromSuperview(); chip = AttachmentChip(a) }
            chip.onRemove = { [weak self] in self?.onRemove?(a.id) }
            chip.onRetry = { [weak self] in self?.onRetry?(a.id) }
            next.append(chip)
        }
        keep.values.forEach { $0.removeFromSuperview() }
        for c in next where c.superview !== self { addSubview(c) }
        chips = next
        needsLayout = true
    }

    /// Chip frames for a width: left to right, wrapping.
    func frames(width: CGFloat) -> [NSRect] {
        var out: [NSRect] = []
        var x: CGFloat = 0, y: CGFloat = 0
        for c in chips {
            let w = min(c.preferredWidth, max(width, 60))
            if x > 0 && x + w > width {
                x = 0
                y += ChipStyle.height + ChipStyle.gap
            }
            out.append(NSRect(x: x, y: y, width: w, height: ChipStyle.height))
            x += w + ChipStyle.gap
        }
        return out
    }

    /// The height of all rows for a width, before any cap.
    func contentHeight(width: CGFloat) -> CGFloat {
        guard let last = frames(width: width).last else { return 0 }
        return last.maxY
    }

    override func layout() {
        super.layout()
        for (c, f) in zip(chips, frames(width: bounds.width)) { c.frame = f }
    }
}
