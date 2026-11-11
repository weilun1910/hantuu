import Darwin
import Foundation

/// Watches one open file for changes on disk, however they happen: written in place, replaced
/// by an atomic save (a new file renamed over it, which is how most agents and editors write),
/// deleted, or deleted and made again. It watches the file itself and its folder, which sees
/// the renames, and calls back once things settle: after a short quiet moment, or at least
/// once a second while something keeps writing (a log an agent appends to).
final class FileWatch {
    let path: String
    private let onChange: () -> Void
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var watchedInode: UInt64?
    private var pending: DispatchWorkItem?
    private var firstPending: Date?
    private let settle: TimeInterval
    private let maxWait: TimeInterval

    init(path: String, settle: TimeInterval = 0.12, maxWait: TimeInterval = 1.0, onChange: @escaping () -> Void) {
        self.path = path
        self.settle = settle
        self.maxWait = maxWait
        self.onChange = onChange
        armDirectory()
        armFile()
    }

    deinit { stop() }

    func stop() {
        pending?.cancel()
        pending = nil
        firstPending = nil
        fileSource?.cancel()
        fileSource = nil
        dirSource?.cancel()
        dirSource = nil
    }

    private static func source(_ path: String, _ mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        s.setCancelHandler { close(fd) }
        return s
    }

    private func armDirectory() {
        let dir = (path as NSString).deletingLastPathComponent
        guard let s = Self.source(dir, [.write, .rename, .delete]) else { return }
        s.setEventHandler { [weak self] in self?.schedule() }
        s.resume()
        dirSource = s
    }

    /// Watches the file that's at the path now. A new inode (after an atomic save) gets a new
    /// source; the old one would only ever report the replaced file.
    private func armFile() {
        let inode = FileFingerprint.of(path)?.inode
        guard inode != watchedInode || fileSource == nil else { return }
        fileSource?.cancel()
        fileSource = nil
        watchedInode = inode
        guard inode != nil, let s = Self.source(path, [.write, .extend, .attrib, .delete, .rename, .revoke, .link]) else { return }
        s.setEventHandler { [weak self] in self?.schedule() }
        s.resume()
        fileSource = s
    }

    private func schedule() {
        let now = Date()
        if firstPending == nil { firstPending = now }
        let waited = now.timeIntervalSince(firstPending ?? now)
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.firstPending = nil
            self.armFile()
            self.onChange()
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, min(settle, maxWait - waited)), execute: w)
    }
}
