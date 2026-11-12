import Foundation
import Combine

enum ChatHistoryScope: String, CaseIterable, Identifiable {
    case active = "Active", archived = "Archived", all = "All history"
    var id: String { rawValue }
}
enum ChatHistoryLocation: String, CaseIterable, Identifiable {
    case folder = "Current folder", repository = "Repository", all = "All projects"
    var id: String { rawValue }
}

/// A value snapshot. Worker code never holds a Chat or changes a provider file.
struct ChatHistoryRecord: Identifiable {
    var localChatID: UUID? = nil
    var agentID: String
    var sessionID: String? = nil
    var title: String
    var cwd: String
    var transcriptPath: String? = nil
    var branch: String? = nil
    var projectName: String? = nil
    var status = "Saved session"
    var archived = false
    var providerArchived = false
    var modifiedAt = Date.distantPast
    var identityVerified = false
    var issue: String? = nil
    var id: String { sessionID.map { agentID + ":" + $0.lowercased() } ?? "local:" + (localChatID?.uuidString ?? transcriptPath ?? title) }
    var metadata: String { [title, cwd, agentID, agentID == "claude" ? "Claude Code" : agentID.capitalized, projectName ?? "", branch ?? "", status].joined(separator: " ") }
}
struct ChatHistoryHit: Identifiable {
    var record: ChatHistoryRecord
    var entries: [ReaderEntry] = []
    var matchedMessageID: String? = nil
    var snippet = ""
    var id: String { record.id }
}
struct ChatHistoryResult {
    var hits: [ChatHistoryHit] = []
    var warnings: [String] = []
    var partial = false
}

/// The request token is also checked inside file loops, so old searches don't queue
/// minutes of work before the latest query can begin.
final class ChatHistoryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Serial-queue-confined, bounded in-memory index. Nothing is written to disk.
final class ChatHistoryIndex {
    struct Roots {
        var claude: URL = Paths.claudeProjects
        var codex: URL = Paths.codexSessions
        var codexArchive: URL = Paths.codexSessions.deletingLastPathComponent().appendingPathComponent("archived_sessions")
    }
    private struct Cached {
        var offset: UInt64 = 0
        var modified = Date.distantPast
        var claude = ClaudeTranscriptParser()
        var codex = CodexTranscriptParser()
        var entries: [ReaderEntry] = []
        var nativeID: String?
        var cwd: String?
        var title: String?
        var branch: String?
        var invalidIdentity = false
        var child = false
        var malformed = false
        var trimmed = false
        var incomplete = false
        var skippingLongLine = false
        var skippedLongLine = false
        var matchedEntry: ReaderEntry?
        var firstPrompt: String?
    }
    private var cache: [String: Cached] = [:]
    private var indexedQuery = ""
    var maxFiles = 500
    var maxBytesPerFile = 4 * 1024 * 1024
    var maxBytesPerPass = 32 * 1024 * 1024
    var maxEntries = 80

    static func deduplicate(_ records: [ChatHistoryRecord]) -> [ChatHistoryRecord] {
        var seen = Set<String>()
        // Registry identity always wins over the same native session discovered on disk.
        return records.sorted { ($0.localChatID != nil ? 0 : 1) < ($1.localChatID != nil ? 0 : 1) }
            .filter { seen.insert($0.id).inserted }
    }

    /// A git common-directory key includes linked worktrees without invoking git.
    static func repositoryKey(_ path: String) -> String? {
        var folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        for _ in 0..<64 {
            let git = folder.appendingPathComponent(".git")
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &directory) {
                var gitDir = git
                if !directory.boolValue {
                    guard let data = try? String(contentsOf: git, encoding: .utf8), data.hasPrefix("gitdir: ") else { return nil }
                    let target = data.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
                    gitDir = URL(fileURLWithPath: target, relativeTo: folder).standardizedFileURL
                }
                let common = gitDir.appendingPathComponent("commondir")
                if let data = try? String(contentsOf: common, encoding: .utf8) {
                    gitDir = URL(fileURLWithPath: data.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitDir).standardizedFileURL
                }
                return gitDir.resolvingSymlinksInPath().path
            }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }; folder = parent
        }
        return nil
    }

    func search(records: [ChatHistoryRecord], query: String, scope: ChatHistoryScope,
                location: ChatHistoryLocation, folder: String?, includeNative: Bool,
                fullText: Bool, roots: Roots = Roots(), cancellation: ChatHistoryCancellation = ChatHistoryCancellation()) -> ChatHistoryResult {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedQuery != indexedQuery { cache.removeAll(); indexedQuery = normalizedQuery }
        let registryIDs = Set(records.map(\.id))
        func inScope(_ record: ChatHistoryRecord) -> Bool {
            scope == .all || (scope == .archived ? record.archived : !record.archived)
        }
        var result = ChatHistoryResult()
        var candidates = Self.deduplicate(records).filter(inScope).sorted { $0.modifiedAt > $1.modifiedAt }
        let fileLimit = fullText || includeNative ? maxFiles : Int.max
        var bytesRemaining = maxBytesPerPass
        let folderKey = folder.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let repoKey = location == .repository ? folder.flatMap(Self.repositoryKey) : nil
        if location == .repository && repoKey == nil { result.warnings.append("The current folder has no available Git repository.") }
        if includeNative {
            for (agent, root, archived) in [("claude", roots.claude, false), ("codex", roots.codex, false), ("codex", roots.codexArchive, true)] {
                guard !cancellation.cancelled else { return result }
                var failed = false
                guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return true }) else { continue }
                var visited = 0
                for case let url as URL in files {
                    if cancellation.cancelled { return result }
                    visited += 1
                    if visited > maxFiles * 20 || candidates.count >= maxFiles { result.partial = true; break }
                    if url.pathComponents.contains("subagents") { files.skipDescendants(); continue }
                    if agent == "claude" {
                        let relative = url.path.dropFirst(root.path.count).split(separator: "/")
                        if relative.count > 2 { files.skipDescendants(); continue }
                        guard relative.count == 2, UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
                    }
                    guard url.pathExtension == "jsonl", agent != "codex" || url.lastPathComponent.hasPrefix("rollout-") else { continue }
                    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    candidates.append(ChatHistoryRecord(agentID: agent, title: url.deletingPathExtension().lastPathComponent, cwd: "", transcriptPath: url.path, archived: archived, providerArchived: archived, modifiedAt: values.contentModificationDate ?? .distantPast))
                }
                if failed { result.warnings.append("Some \(agent) history folders could not be read.") }
            }
        }
        var codexTitles: [String: String] = [:]
        if includeNative {
            let hints = Self.codexTitles(at: roots.codex.deletingLastPathComponent().appendingPathComponent("session_index.jsonl"))
            codexTitles = hints.titles
            if hints.partial { result.warnings.append("Only the latest 2 MB of Codex title changes were read.") }
        }
        var indexed: [ChatHistoryHit] = []
        for original in candidates.prefix(fileLimit) {
            if cancellation.cancelled { return result }
            var record = original, entries: [ReaderEntry] = []
            var retainedMatch: ReaderEntry?
            if (fullText || record.localChatID == nil), let path = record.transcriptPath,
               record.agentID == "claude" || record.agentID == "codex" {
                do {
                    let value = try read(path: path, agent: record.agentID, remaining: &bytesRemaining, cancellation: cancellation)
                    if value.child && record.localChatID == nil { continue }
                    entries = value.entries
                    retainedMatch = value.matchedEntry
                    if let match = retainedMatch {
                        if let position = entries.firstIndex(where: { $0.id == match.id }) {
                            if !entries[position].text.localizedCaseInsensitiveContains(indexedQuery) { entries[position] = match }
                        } else { entries.insert(match, at: 0) }
                    }
                    if let id = value.nativeID, UUID(uuidString: id) != nil, !value.invalidIdentity {
                        if let expected = record.sessionID, expected.lowercased() != id.lowercased() {
                            record.issue = "Transcript identity does not match the saved session."; entries = []; retainedMatch = nil
                        } else if record.localChatID == nil && record.agentID == "claude" && URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased() != id.lowercased() {
                            record.issue = "Transcript filename does not match its native session identity."
                        } else {
                            record.sessionID = id; record.identityVerified = true
                            if record.localChatID == nil {
                                record.cwd = value.cwd ?? ""
                                record.title = (record.agentID == "codex" ? codexTitles[id.lowercased()] : nil) ?? value.title ?? value.firstPrompt ?? record.title
                                record.branch = value.branch
                            }
                        }
                    } else {
                        record.issue = "Session identity could not be verified. This transcript cannot be resumed."
                    }
                    if value.incomplete || value.skippedLongLine { result.partial = true }
                    if value.skippedLongLine { record.issue = record.issue ?? "Some oversized transcript records were skipped." }
                    if value.malformed { record.issue = record.issue ?? "Some transcript lines could not be read." }
                } catch {
                    record.issue = "Transcript unavailable: \(error.localizedDescription)"
                }
            }
            if record.localChatID == nil {
                // A native file never resurrects an archived registry entry in Active.
                if registryIDs.contains(record.id) { continue }
                var isDirectory: ObjCBool = false
                if record.cwd.isEmpty { record.issue = record.issue ?? "Working folder is missing from session metadata." }
                else if !FileManager.default.fileExists(atPath: record.cwd, isDirectory: &isDirectory) || !isDirectory.boolValue {
                    record.issue = record.issue ?? "The working folder is unavailable. Preview remains readable."
                }
            }
            if scope == .active && record.archived || scope == .archived && !record.archived { continue }
            switch location {
            case .all: break
            case .folder:
                guard let folderKey, URL(fileURLWithPath: record.cwd).standardizedFileURL.path == folderKey else { continue }
            case .repository:
                guard let repoKey, Self.repositoryKey(record.cwd) == repoKey else { continue }
            }
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let match = q.isEmpty ? nil : retainedMatch ?? entries.first { $0.text.localizedCaseInsensitiveContains(q) }
            guard q.isEmpty || record.metadata.localizedCaseInsensitiveContains(q) || match != nil else { continue }
            let snippet = match.map { Self.snippet($0.text, query: q) } ?? ""
            indexed.append(ChatHistoryHit(record: record, entries: entries, matchedMessageID: match?.id, snippet: snippet))
        }
        var seen = Set<String>()
        result.hits = indexed.sorted {
            if ($0.record.localChatID != nil) != ($1.record.localChatID != nil) { return $0.record.localChatID != nil }
            return $0.record.modifiedAt > $1.record.modifiedAt
        }.filter { seen.insert($0.id).inserted }
        if candidates.count > fileLimit || bytesRemaining <= 0 { result.partial = true }
        if cache.count > maxFiles { cache = cache.filter { key, _ in candidates.prefix(maxFiles).contains { $0.transcriptPath == key } } }
        return result
    }

    /// Codex's append-only title hints contain no authoritative cwd or transcript identity.
    /// Bound the read and keep the last complete row for each UUID.
    static func codexTitles(at url: URL) -> (titles: [String: String], partial: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([:], false) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let limit: UInt64 = 2 * 1024 * 1024
        let start = size > limit ? size - limit : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Int(limit)) else { return ([:], false) }
        var lines = data.split(separator: 10, omittingEmptySubsequences: false).dropLast()
        if start > 0 { lines = lines.dropFirst() }
        var titles: [String: String] = [:]
        for line in lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let id = obj["id"] as? String, UUID(uuidString: id) != nil,
                  let title = obj["thread_name"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            titles[id.lowercased()] = String(title.prefix(200))
        }
        return (titles, start > 0)
    }

    /// Revalidate the selected native identity from the file before import. Call on a worker.
    static func verify(_ record: ChatHistoryRecord) -> Bool {
        guard ["claude", "codex"].contains(record.agentID), record.identityVerified, let expected = record.sessionID, UUID(uuidString: expected) != nil,
              let path = record.transcriptPath, !record.cwd.isEmpty else { return false }
        let index = ChatHistoryIndex()
        var budget = index.maxBytesPerFile
        guard let value = try? index.read(path: path, agent: record.agentID, remaining: &budget, cancellation: ChatHistoryCancellation()) else { return false }
        return value.nativeID?.lowercased() == expected.lowercased() && !value.invalidIdentity && !value.child && value.cwd == record.cwd
    }

    static func snippet(_ text: String, query: String) -> String {
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return String(text.prefix(180)) }
        let start = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "...") + text[start..<end].replacingOccurrences(of: "\n", with: " ") + (end == text.endIndex ? "" : "...")
    }

    private func read(path: String, agent: String, remaining: inout Int, cancellation: ChatHistoryCancellation) throws -> Cached {
        let url = URL(fileURLWithPath: path)
        let stat = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard stat.isRegularFile == true, stat.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
        let size = UInt64(stat.fileSize ?? 0), modified = stat.contentModificationDate ?? .distantPast
        var value = cache[path] ?? Cached()
        if size < value.offset || (size == value.offset && modified != value.modified) { value = Cached() }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        try handle.seek(toOffset: value.offset)
        let allowance = min(maxBytesPerFile, max(0, remaining))
        var data = try handle.read(upToCount: allowance) ?? Data()
        remaining -= data.count
        var consumed = 0
        if value.skippingLongLine {
            if let newline = data.firstIndex(of: 10) {
                let skipped = data.distance(from: data.startIndex, to: newline) + 1
                consumed += skipped; data = Data(data.dropFirst(skipped)); value.skippingLongLine = false
                if agent == "claude" { _ = value.claude.parse(line: Data()) } else { _ = value.codex.parse(line: Data()) }
            } else {
                value.offset += UInt64(data.count); value.incomplete = value.offset < size
                value.modified = modified; cache[path] = value; return value
            }
        }
        // Only complete JSONL records advance the cursor. An in-flight last line is retried.
        for line in data.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
            if cancellation.cancelled { break }
            consumed += line.count + 1
            guard !line.isEmpty else { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { value.malformed = true; continue }
            var identity: String?
            if agent == "codex", obj["type"] as? String == "session_meta", let payload = obj["payload"] as? [String: Any] {
                identity = payload["id"] as? String
                value.cwd = payload["cwd"] as? String
                let source = payload["source"] as? [String: Any]
                value.child = payload["parent_thread_id"] != nil || source?["subagent"] != nil || ["subagent", "guardian_review"].contains(payload["thread_source"] as? String ?? "")
                value.branch = (payload["git"] as? [String: Any])?["branch"] as? String
            } else if agent == "claude" {
                identity = obj["sessionId"] as? String
                if let cwd = obj["cwd"] as? String { value.cwd = cwd }
                if let branch = obj["gitBranch"] as? String { value.branch = branch }
                if obj["type"] as? String == "custom-title" { value.title = obj["customTitle"] as? String }
                if obj["isSidechain"] as? Bool == true { value.child = true }
            }
            if let identity, !identity.isEmpty {
                if let previous = value.nativeID, previous != identity { value.invalidIdentity = true }
                value.nativeID = identity
            }
            let parsed = agent == "claude" ? value.claude.parse(line: Data(line)) : value.codex.parse(line: Data(line))
            for var entry in parsed {
                if entry.kind == .user && value.firstPrompt == nil { value.firstPrompt = String(entry.text.prefix(100)) }
                if !indexedQuery.isEmpty && value.matchedEntry == nil && entry.text.localizedCaseInsensitiveContains(indexedQuery) {
                    var matched = entry
                    matched.text = Self.snippet(entry.text, query: indexedQuery)
                    matched.detail = nil; matched.images = []; matched.files = []; matched.links = []
                    value.matchedEntry = matched
                }
                entry.text = String(entry.text.prefix(2_000)); entry.detail = nil; entry.images = []; entry.files = []; entry.links = []
                if let existing = value.entries.firstIndex(where: { $0.id == entry.id }) { value.entries[existing] = entry } else { value.entries.append(entry) }
            }
            if value.entries.count > maxEntries { value.entries.removeFirst(value.entries.count - maxEntries); value.trimmed = true }
        }
        if consumed == 0 && data.count == maxBytesPerFile {
            // A single oversized record cannot pin the scan forever. Skip it across
            // bounded passes, then resume parsing at the next complete JSONL record.
            consumed = data.count; value.skippingLongLine = true; value.skippedLongLine = true
        }
        value.offset += UInt64(consumed)
        value.modified = modified
        value.incomplete = value.offset < size
        cache[path] = value
        return value
    }
}

final class ChatHistoryStore: ObservableObject {
    @Published var result = ChatHistoryResult()
    @Published var loading = false
    private let queue = DispatchQueue(label: "hantuu.history-index", qos: .userInitiated)
    private let index = ChatHistoryIndex()
    private var token: ChatHistoryCancellation?
    func cancel() { token?.cancel(); token = nil; loading = false }
    func search(records: [ChatHistoryRecord], query: String, scope: ChatHistoryScope, location: ChatHistoryLocation, folder: String?, native: Bool, fullText: Bool) {
        token?.cancel()
        let next = ChatHistoryCancellation(); token = next; loading = true
        queue.async { [weak self] in
            guard let self, !next.cancelled else { return }
            let result = self.index.search(records: records, query: query, scope: scope, location: location, folder: folder, includeNative: native, fullText: fullText, cancellation: next)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token === next, !next.cancelled else { return }
                self.result = result; self.loading = false
            }
        }
    }
}
