import Foundation

struct NativeSideChat: Identifiable, Equatable {
    var id: String
    var parent: String
    var url: URL
    var title: String { "Attached conversation " + String(id.suffix(8)) }

    static func read(_ url: URL) -> NativeSideChat? {
        guard let object = AgentWorkTracker.firstLine(url), object["type"] as? String == "session_meta",
              let meta = object["payload"] as? [String: Any], meta["attached_thread"] as? Bool == true,
              let id = meta["id"] as? String, let parent = meta["forked_from_id"] as? String else { return nil }
        return NativeSideChat(id: id, parent: parent, url: url)
    }
}

/// Runs on the panel's worker queue. It inspects only rollout metadata, never auth/config.
final class NativeSideChatIndex {
    let root: URL
    private var known: Set<URL> = []
    private var attached: [URL: NativeSideChat] = [:]
    init(root: URL = Paths.codexSessions) { self.root = root }

    func scan(parent: String) -> [NativeSideChat] {
        let fm = FileManager.default
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var present: Set<URL> = []
        for case let url as URL in iterator {
            guard url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            present.insert(url)
            guard !known.contains(url) else { continue }
            if let item = NativeSideChat.read(url) { attached[url] = item }
            // A file may be discovered before its first complete line is written.
            if AgentWorkTracker.firstLine(url) != nil { known.insert(url) }
        }
        known.formIntersection(present)
        attached = attached.filter { present.contains($0.key) }
        return attached.values.filter { $0.parent.lowercased() == parent.lowercased() }.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }
}
