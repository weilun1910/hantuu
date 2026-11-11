import AppKit
import SwiftUI

/// Put this inside a scroll view's content. It restores the offset once layout has room
/// for it and records user scrolling against the context that installed the observer.
struct PanelScrollMemory: NSViewRepresentable {
    let key: String
    let offset: Double
    let changed: (Double) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.configure(key: key, offset: offset, changed: changed)
    }

    final class Probe: NSView {
        private var key = ""
        private var target: CGFloat?
        private var changed: ((Double) -> Void)?
        private weak var scroll: NSScrollView?
        private var observer: NSObjectProtocol?
        private var applying = false
        private var restoreAttempts = 0
        private var retry: DispatchWorkItem?

        func configure(key: String, offset: Double, changed: @escaping (Double) -> Void) {
            if self.key != key {
                self.key = key
                retry?.cancel()
                retry = nil
                restoreAttempts = 0
                target = CGFloat(max(0, offset))
            }
            self.changed = changed
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        override func layout() { super.layout(); attach() }

        private func attach() {
            guard let scroll = enclosingScrollView else { return }
            if self.scroll !== scroll {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                self.scroll = scroll
                scroll.contentView.postsBoundsChangedNotifications = true
                observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                    object: scroll.contentView, queue: .main) { [weak self] _ in self?.scrolled() }
            }
            restore()
        }

        private func restore() {
            guard let target, let scroll, let doc = scroll.documentView,
                  window != nil, !isHiddenOrHasHiddenAncestor, !scroll.isHiddenOrHasHiddenAncestor else { return }
            let maximum = max(0, doc.bounds.height - scroll.contentView.bounds.height)
            // Lazy stacks may need another layout before they expose the saved position.
            // If the list has become shorter, eventually clamp to its new end.
            if maximum < target && restoreAttempts < 12 {
                guard retry == nil else { return }
                restoreAttempts += 1
                let work = DispatchWorkItem { [weak self] in
                    self?.retry = nil
                    self?.restore()
                }
                retry = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
                return
            }
            retry?.cancel()
            retry = nil
            applying = true
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: min(target, maximum)))
            scroll.reflectScrolledClipView(scroll.contentView)
            self.target = nil
            applying = false
        }

        private func scrolled() {
            guard !applying, let scroll, window != nil, !isHiddenOrHasHiddenAncestor,
                  !scroll.isHiddenOrHasHiddenAncestor else { return }
            if target != nil {
                restore()
                return
            }
            let value = Double(scroll.contentView.bounds.origin.y)
            let callback = changed
            // SwiftUI can emit a bounds change while updating its tree.
            DispatchQueue.main.async { callback?(value) }
        }

        deinit {
            retry?.cancel()
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

extension View {
    func rememberPanelScroll(_ review: ReviewCenter, files: Bool = false) -> some View {
        let key = review.panelContextKey + (files ? "|files" : "|changes")
        return background(PanelScrollMemory(key: key, offset: files ? review.filesScroll : review.changesScroll) { [weak review] value in
            guard let review, key == review.panelContextKey + (files ? "|files" : "|changes") else { return }
            if files {
                if review.filesScroll != value { review.filesScroll = value }
            } else if review.changesScroll != value { review.changesScroll = value }
        })
    }
}
