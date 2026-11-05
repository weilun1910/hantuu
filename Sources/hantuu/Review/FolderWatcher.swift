import CoreServices
import Foundation

/// Watches a folder tree with FSEvents and calls back once things settle: after a quiet
/// moment, or at most every couple of seconds while files keep changing (a long build).
/// Churn that never changes what Changes or Files shows (git's object store, build caches)
/// is ignored.
final class FolderWatcher {
    let path: String
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private var pending: DispatchWorkItem?
    private var firstPending: Date?
    private let quiet: TimeInterval
    private let maxWait: TimeInterval

    static let ignored = ["/.git/objects/", "/.git/logs/", "/node_modules/", "/.build/", "/.hantuu/"]

    init(path: String, quiet: TimeInterval = 0.35, maxWait: TimeInterval = 2.0, onChange: @escaping () -> Void) {
        self.path = path
        self.quiet = quiet
        self.maxWait = maxWait
        self.onChange = onChange
    }

    deinit { stop() }

    static func isRelevant(_ p: String) -> Bool {
        if p.hasSuffix(".git/index.lock") || p.hasSuffix("/.DS_Store") { return false }
        return !ignored.contains { p.contains($0) }
    }

    func start() {
        guard stream == nil else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            if list.prefix(count).contains(where: FolderWatcher.isRelevant) { me.schedule() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        pending?.cancel()
        pending = nil
        firstPending = nil
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    private func schedule() {
        let now = Date()
        if firstPending == nil { firstPending = now }
        pending?.cancel()
        let waited = now.timeIntervalSince(firstPending ?? now)
        let delay = waited >= maxWait ? 0 : min(quiet, maxWait - waited)
        let w = DispatchWorkItem { [weak self] in
            self?.firstPending = nil
            self?.onChange()
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}
