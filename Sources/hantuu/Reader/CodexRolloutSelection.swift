import Foundation

/// Process ownership identifies a resumed rollout even before Codex writes its next turn.
/// If the process retains several main threads, a newly started turn disambiguates them.
final class CodexRolloutSelection {
    private struct Observed {
        let meta: CodexTranscriptParser.SessionMeta
        let tail: LineTail
        var latestStart: Date?
    }

    private let since: Date
    private var files: [String: Observed] = [:]
    private var rejected: [String: Date] = [:]

    init(since: Date = Date()) { self.since = since }

    func select(paths: [URL], currentPath: String?) -> HookLineParser.Session? {
        let open = Set(paths.map(\.path))
        files = files.filter { open.contains($0.key) }
        rejected = rejected.filter { open.contains($0.key) }
        for url in paths {
            if files[url.path] == nil {
                if let at = rejected[url.path], Date().timeIntervalSince(at) < 10 { continue }
                guard let meta = CodexTranscriptParser.readMeta(url) else {
                    rejected[url.path] = Date()
                    continue
                }
                rejected[url.path] = nil
                files[url.path] = Observed(meta: meta, tail: LineTail(url: url, from: .lastBytes(256 * 1024)))
            }
            guard var file = files[url.path] else { continue }
            for line in file.tail.read(limit: 256 * 1024) {
                guard let start = Self.turnStart(line), start >= since else { continue }
                file.latestStart = max(file.latestStart ?? start, start)
            }
            files[url.path] = file
        }
        if files.count == 1, let (path, file) = files.first {
            return HookLineParser.Session(id: file.meta.id, path: path)
        }
        let active = files.compactMap { path, file -> (String, Observed, Date)? in
            file.latestStart.map { (path, file, $0) }
        }.sorted { $0.2 > $1.2 }
        if let first = active.first, active.count == 1 || first.2 > active[1].2 {
            return HookLineParser.Session(id: first.1.meta.id, path: first.0)
        }
        // Titles, creation dates and the original cwd do not establish which thread was chosen.
        return nil
    }

    static func turnStart(_ line: Data) -> Date? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let timestamp = object["timestamp"] as? String else { return nil }
        let kind = object["type"] as? String
        guard (kind == "event_msg" && ["task_started", "thread_settings_applied"].contains(payload["type"] as? String ?? ""))
                || kind == "turn_context" else { return nil }
        return CodexTranscriptParser.parseDate(timestamp)
    }
}
