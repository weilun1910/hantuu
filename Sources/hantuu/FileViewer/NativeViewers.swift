import AppKit
import AVFoundation
import AVKit
import PDFKit
import Quartz
import SwiftUI

/// A native viewer for one tab's file. The controller keeps one per open tab, so each keeps
/// its own zoom, page and playback position.
protocol FileViewerPane: NSView {
    /// The file changed on disk.
    func reload()
    /// The tab stopped being shown (stop playback).
    func didHide()
    /// The tab is going away.
    func close()
}

extension FileViewerPane {
    func didHide() {}
    func close() {}
}

// MARK: Images

/// Centres the document when it's smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return r }
        let f = doc.frame
        if r.width > f.width { r.origin.x = (f.width - r.width) / 2 }
        if r.height > f.height { r.origin.y = (f.height - r.height) / 2 }
        return r
    }
}

/// Images fit the panel (never blown up past their own size), pinch or Cmd-plus to zoom, and
/// double-click to switch between fitting and actual size. Animated GIFs play.
final class ImageViewer: NSView, FileViewerPane {
    let url: URL
    let scroll = NSScrollView()
    let imageView = NSImageView()
    private(set) var fitted = true
    private(set) var image: NSImage?
    var onFailure: (() -> Void)?
    static let margin: CGFloat = 20

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        scroll.contentView = CenteringClipView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 32
        scroll.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.imageFrameStyle = .none
        imageView.isEditable = false
        scroll.documentView = imageView
        addSubview(scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(userZoomed), name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
        load()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func load() {
        // Read the bytes fresh each time; NSImage(contentsOf:) can hand back a cached image.
        guard let data = try? Data(contentsOf: url), let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else {
            image = nil
            onFailure?()
            return
        }
        image = img
        imageView.image = img
        imageView.frame = NSRect(origin: .zero, size: img.size)
        needsLayout = true
    }

    var loaded: Bool { image != nil }

    func reload() {
        let wasFitted = fitted
        let mag = scroll.magnification
        load()
        if !wasFitted { scroll.magnification = mag }
    }

    @objc private func userZoomed() { fitted = false }

    var fitMagnification: CGFloat {
        guard let img = image else { return 1 }
        let w = max(1, bounds.width - Self.margin * 2), h = max(1, bounds.height - Self.margin * 2)
        return min(1, min(w / img.size.width, h / img.size.height))
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        if fitted { scroll.magnification = fitMagnification }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return super.mouseDown(with: event) }
        if fitted {
            fitted = false
            let p = scroll.contentView.convert(event.locationInWindow, from: nil)
            scroll.setMagnification(1, centeredAt: p)
        } else {
            fitted = true
            scroll.animator().magnification = fitMagnification
        }
    }

    override func magnify(with event: NSEvent) {
        fitted = false
        super.magnify(with: event)
    }
}

// MARK: PDFs

/// PDFKit's own view: continuous pages that scale to the panel's width, pinch to zoom, text
/// selection and copy, on the panel's colour so it follows light and dark.
final class PDFViewer: NSView, FileViewerPane {
    let url: URL
    let pdf = PDFView()
    var onFailure: (() -> Void)?

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        pdf.autoScales = true
        pdf.displayMode = .singlePageContinuous
        pdf.displaysPageBreaks = true
        pdf.pageBreakMargins = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        pdf.autoresizingMask = [.width, .height]
        addSubview(pdf)
        applyColours()
        load(keepPage: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    var loaded: Bool { pdf.document != nil }

    private func load(keepPage: Bool) {
        let index = keepPage ? pdf.currentPage.flatMap { pdf.document?.index(for: $0) } : nil
        guard let doc = PDFDocument(url: url), !doc.isLocked || doc.pageCount > 0 else {
            pdf.document = nil
            onFailure?()
            return
        }
        pdf.document = doc
        if let index, index < doc.pageCount, let page = doc.page(at: index) { pdf.go(to: page) }
    }

    func reload() { load(keepPage: true) }

    private func applyColours() {
        // PDFView takes a fixed colour, so resolve the panel's colour for this appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            pdf.backgroundColor = Theme.chrome.usingColorSpace(.sRGB) ?? Theme.chrome
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColours()
    }

    override func layout() {
        super.layout()
        pdf.frame = bounds
    }
}

// MARK: Video and audio

/// AVKit's player. A video sits at its own shape in the middle of the panel, so there are no
/// black bars on a light panel, with AVPlayerView's own controls over it. Audio gets its name
/// and a quiet row of controls in the app's style, since AVPlayerView's audio bar sits on a
/// black strip. Nothing plays until you press play, and switching tabs pauses it.
final class MediaViewer: NSView, FileViewerPane {
    let url: URL
    let audioOnly: Bool
    let player = AVPlayer()
    let playerView = AVPlayerView()
    let clock: PlayerClock
    private(set) var videoSize: CGSize?
    private(set) var ready = false
    var onFailure: (() -> Void)?
    private var audioHost: NSView?

    init(url: URL, audioOnly: Bool) {
        self.url = url
        self.audioOnly = audioOnly
        clock = PlayerClock(player: player)
        super.init(frame: .zero)
        if audioOnly {
            let host = ChromeHostingView(rootView: AudioPanel(name: url.lastPathComponent, detail: FileKinds.describe(url.path), clock: clock))
            addSubview(host)
            audioHost = host
        } else {
            playerView.player = player
            playerView.controlsStyle = .inline
            playerView.showsFullScreenToggleButton = true
            playerView.videoGravity = .resizeAspect
            playerView.allowsPictureInPicturePlayback = false
            addSubview(playerView)
        }
        load(at: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func load(at time: CMTime?) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard playable else { self.onFailure?(); return }
            if !self.audioOnly, let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let r = CGRect(origin: .zero, size: size).applying(transform)
                self.videoSize = CGSize(width: abs(r.width), height: abs(r.height))
            }
            if let d = try? await asset.load(.duration), d.isNumeric { self.clock.duration = d.seconds }
            if let time { await self.player.seek(to: time) }
            self.ready = true
            self.needsLayout = true
        }
    }

    func reload() {
        let time = player.currentTime()
        player.pause()
        ready = false
        load(at: time)
    }

    func didHide() { player.pause() }
    func close() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        clock.stop()
    }

    /// Where the video sits: its own shape, as large as fits with a margin.
    var videoFrame: NSRect {
        let inset = bounds.insetBy(dx: 16, dy: 16)
        guard let s = videoSize, s.width > 0, s.height > 0 else { return inset }
        let scale = min(inset.width / s.width, inset.height / s.height)
        let w = s.width * scale, h = s.height * scale
        return NSRect(x: inset.midX - w / 2, y: inset.midY - h / 2, width: w, height: h).integral
    }

    override func layout() {
        super.layout()
        if let audioHost { audioHost.frame = bounds } else { playerView.frame = videoFrame }
    }
}

/// The player's time, for the audio controls.
final class PlayerClock: ObservableObject {
    let player: AVPlayer
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    private var observer: Any?
    private var rateObserver: NSKeyValueObservation?

    init(player: AVPlayer) {
        self.player = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            self?.time = t.seconds.isFinite ? t.seconds : 0
        }
        rateObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async { self?.playing = p.timeControlStatus != .paused }
        }
    }

    func stop() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        rateObserver = nil
    }

    func toggle() {
        if player.timeControlStatus == .paused {
            if duration > 0 && time >= duration - 0.05 { player.seek(to: .zero) }
            player.play()
        } else {
            player.pause()
        }
    }

    func seek(_ seconds: Double) {
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    static func format(_ s: Double) -> String {
        let t = Int(max(0, s.isFinite ? s : 0).rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

private struct AudioPanel: View {
    let name: String
    let detail: String
    @ObservedObject var clock: PlayerClock

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "waveform").font(.system(size: 26, weight: .light)).foregroundStyle(Color.hTertiary)
                .padding(.bottom, 14)
            Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.hText).lineLimit(1).truncationMode(.middle)
            Text(detail).font(.system(size: 11.5)).foregroundStyle(Color.hTertiary).padding(.top, 3)
            HStack(spacing: 10) {
                Button(action: clock.toggle) {
                    Image(systemName: clock.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.hText)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.hInk(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(clock.playing ? "Pause" : "Play")
                Text(PlayerClock.format(clock.time))
                    .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Color.hSecondary)
                    .frame(minWidth: 34, alignment: .trailing)
                Slider(value: Binding(get: { min(clock.time, max(clock.duration, 0.01)) }, set: { clock.seek($0) }),
                       in: 0...max(clock.duration, 0.01))
                    .controlSize(.small)
                    .tint(Color.hSecondary)
                Text(PlayerClock.format(clock.duration))
                    .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Color.hTertiary)
                    .frame(minWidth: 34, alignment: .leading)
            }
            .frame(maxWidth: 420)
            .padding(.top, 22)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Everything else Quick Look can show

/// Quick Look's own preview, the same one Finder shows with Space: Office and iWork documents,
/// RTF, 3D models, fonts and more, with nothing for hantuu to keep up to date.
final class QuickLookViewer: NSView, FileViewerPane {
    let url: URL
    let preview: QLPreviewView

    init(url: URL) {
        self.url = url
        preview = QLPreviewView(frame: .zero, style: .normal)
        super.init(frame: .zero)
        preview.shouldCloseWithWindow = false
        preview.autostarts = false
        preview.previewItem = url as NSURL
        preview.autoresizingMask = [.width, .height]
        addSubview(preview)
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload() { preview.refreshPreviewItem() }
    func close() { preview.close() }

    override func layout() {
        super.layout()
        preview.frame = bounds
    }
}

// MARK: Nothing can preview it

/// A quiet note in the middle of the panel, with the file's own icon and two ways out.
final class FallbackViewer: NSView, FileViewerPane {
    let url: URL
    private let host: NSView

    init(url: URL, reason: String? = nil) {
        self.url = url
        host = ChromeHostingView(rootView: FallbackNote(path: url.path, reason: reason))
        super.init(frame: .zero)
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload() {}

    override func layout() {
        super.layout()
        host.frame = bounds
    }
}

struct FallbackNote: View {
    let path: String
    var reason: String?

    var body: some View {
        let app = FileKinds.defaultApp(for: path)
        VStack(spacing: 0) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 48, height: 48)
                .padding(.bottom, 12)
            Text((path as NSString).lastPathComponent)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.hText)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(FileKinds.describe(path))
                .font(.system(size: 11.5))
                .foregroundStyle(Color.hTertiary)
                .padding(.top, 3)
            Text(reason ?? "hantuu can't show this kind of file.")
                .font(.system(size: 12))
                .foregroundStyle(Color.hSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
            HStack(spacing: 8) {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    .buttonStyle(BarButtonStyle(prominent: false))
                if let app {
                    Button("Open with \(app.name)") { FileViewerActions.openWithDefaultApp(path) }
                        .buttonStyle(BarButtonStyle(prominent: true))
                }
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.hChrome)
    }
}

enum FileViewerActions {
    static func openWithDefaultApp(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
