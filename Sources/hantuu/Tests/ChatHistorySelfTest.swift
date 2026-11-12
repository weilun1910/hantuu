import AppKit
import SwiftUI

extension SelfTest {
    static func chatHistory(_ dir: URL) {
        let root = dir.appendingPathComponent("chat-history", isDirectory: true)
        Paths.ensure(root)
        let claudeRoot = root.appendingPathComponent("claude/projects", isDirectory: true)
        let codexRoot = root.appendingPathComponent("codex/sessions", isDirectory: true)
        let archiveRoot = root.appendingPathComponent("codex/archived_sessions", isDirectory: true)
        [claudeRoot, codexRoot, archiveRoot].forEach { Paths.ensure($0) }
        let roots = ChatHistoryIndex.Roots(claude: claudeRoot, codex: codexRoot, codexArchive: archiveRoot)
        let claudeProject = claudeRoot.appendingPathComponent("-fixture-project", isDirectory: true)
        Paths.ensure(claudeProject)
        let claude = claudeProject.appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl")
        let codex = codexRoot.appendingPathComponent("rollout-fixture-22222222-2222-4222-8222-222222222222.jsonl")
        let archived = archiveRoot.appendingPathComponent("rollout-fixture-33333333-3333-4333-8333-333333333333.jsonl")
        func line(_ object: [String: Any]) -> Data {
            var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            data.append(10); return data
        }
        var claudeData = line(["type": "user", "sessionId": "11111111-1111-4111-8111-111111111111", "cwd": root.path, "gitBranch": "feature/history", "uuid": "user-one", "message": ["role": "user", "content": "Find the amber lighthouse"]])
        claudeData.append(line(["type": "assistant", "sessionId": "11111111-1111-4111-8111-111111111111", "uuid": "assistant-one", "message": ["role": "assistant", "content": [["type": "text", "text": "The amber lighthouse is ready."]]]]))
        claudeData.append(line(["type": "custom-title", "sessionId": "11111111-1111-4111-8111-111111111111", "customTitle": "Lighthouse review"]))
        try? claudeData.write(to: claude)
        var codexData = line(["type": "session_meta", "payload": ["id": "22222222-2222-4222-8222-222222222222", "cwd": root.path, "source": "cli", "git": ["branch": "main"]]])
        codexData.append(line(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Review the violet observatory"]]]]))
        try? codexData.write(to: codex)
        var archiveData = line(["type": "session_meta", "payload": ["id": "33333333-3333-4333-8333-333333333333", "cwd": root.path, "source": "cli"]])
        archiveData.append(line(["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Archived observatory report"]]]]))
        try? archiveData.write(to: archived)
        let titleHints = codexRoot.deletingLastPathComponent().appendingPathComponent("session_index.jsonl")
        var hints = line(["id": "22222222-2222-4222-8222-222222222222", "thread_name": "Old name", "updated_at": "2026-11-10T10:00:00Z"])
        hints.append(line(["id": "22222222-2222-4222-8222-222222222222", "thread_name": "Observatory review", "updated_at": "2026-11-11T10:00:00Z"]))
        try? hints.write(to: titleHints)
        let index = ChatHistoryIndex()
        func search(_ query: String = "", scope: ChatHistoryScope = .all, records: [ChatHistoryRecord] = [], native: Bool = true) -> ChatHistoryResult {
            index.search(records: records, query: query, scope: scope, location: .all, folder: root.path, includeNative: native, fullText: true, roots: roots)
        }
        let all = search()
        check("history: native Claude and Codex identities", Set(all.hits.compactMap { $0.record.sessionID }) == Set(["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333"]))
        check("history: Claude custom title and branch", all.hits.first { $0.record.agentID == "claude" }?.record.title == "Lighthouse review" && all.hits.first { $0.record.agentID == "claude" }?.record.branch == "feature/history")
        check("history: newest Codex title hint wins", all.hits.first { $0.record.agentID == "codex" && !$0.record.archived }?.record.title == "Observatory review")
        let amber = search("amber lighthouse")
        check("history: visible-text match has snippet and message anchor", amber.hits.count == 1 && amber.hits[0].matchedMessageID == "user-one" && amber.hits[0].snippet.contains("amber lighthouse"))
        check("history: Codex input text is searchable", search("violet").hits.count == 1)
        check("history: native archive is explicit", search(scope: .archived).hits.count == 1 && search(scope: .archived).hits[0].record.providerArchived)
        check("history: opt-out never enumerates native roots", search(native: false).hits.isEmpty)
        var local = ChatHistoryRecord(localChatID: UUID(), agentID: "claude", sessionID: "11111111-1111-4111-8111-111111111111", title: "My local title", cwd: root.path, transcriptPath: claude.path)
        let dedup = search(records: [local])
        check("history: provider identity dedup prefers local registry", dedup.hits.count == 3 && dedup.hits.first { $0.record.sessionID == "11111111-1111-4111-8111-111111111111" }?.record.title == "My local title")
        local.archived = true
        check("history: native discovery cannot resurrect a local archive in Active", search(scope: .active, records: [local]).hits.allSatisfy { $0.record.sessionID != local.sessionID })
        check("history: archived scope keeps the local record over native history", search(scope: .archived, records: [local]).hits.contains { $0.record.localChatID == local.localChatID })
        local.archived = false
        local.sessionID = "44444444-4444-4444-8444-444444444444"
        let mismatch = search(records: [local], native: false)
        check("history: wrong saved identity is not adopted", mismatch.hits.first?.record.identityVerified == false && mismatch.hits.first?.record.sessionID == "44444444-4444-4444-8444-444444444444" && mismatch.hits.first?.entries.isEmpty == true)
        if let verified = amber.hits.first?.record { check("history: revalidation checks identity and cwd", ChatHistoryIndex.verify(verified)) }
        let append = line(["type": "assistant", "sessionId": "11111111-1111-4111-8111-111111111111", "uuid": "later", "message": ["role": "assistant", "content": [["type": "text", "text": "Incremental telescope update"]]]])
        if let h = try? FileHandle(forWritingTo: claude) { try? h.seekToEnd(); try? h.write(contentsOf: append); try? h.close() }
        check("history: appended messages are indexed without duplication", search("telescope").hits.first?.matchedMessageID == "later" && search("lighthouse").hits.first?.entries.filter { $0.id == "user-one" }.count == 1)
        let cancellation = ChatHistoryCancellation(); cancellation.cancel()
        let cancelled = index.search(records: [local], query: "", scope: .all, location: .all, folder: nil, includeNative: true, fullText: true, roots: roots, cancellation: cancellation)
        check("history: cancelled work stops before file scanning", cancelled.hits.isEmpty)
        let bounded = ChatHistoryIndex(); bounded.maxFiles = 1
        check("history: bounded scan reports partial", bounded.search(records: [], query: "", scope: .all, location: .all, folder: nil, includeNative: true, fullText: true, roots: roots).partial)
        let unavailable = ChatHistoryRecord(localChatID: UUID(), agentID: "claude", title: "Missing", cwd: root.path, transcriptPath: root.appendingPathComponent("missing.jsonl").path)
        check("history: unavailable file has explicit error", search(records: [unavailable], native: false).hits.first?.record.issue != nil)
        let longTranscript = root.appendingPathComponent("long.jsonl")
        var longData = line(["type": "session_meta", "payload": ["id": "55555555-5555-4555-8555-555555555555", "cwd": root.path]])
        for n in 0..<120 {
            longData.append(line(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": n == 0 ? "early message needle" : "Later message \(n)"]]]]))
        }
        try? longData.write(to: longTranscript)
        let longRecord = ChatHistoryRecord(localChatID: UUID(), agentID: "codex", sessionID: "55555555-5555-4555-8555-555555555555", title: "Long transcript", cwd: root.path, transcriptPath: longTranscript.path)
        let longIndex = ChatHistoryIndex(); longIndex.maxBytesPerFile = 512
        var longResult = ChatHistoryResult()
        for _ in 0..<100 {
            longResult = longIndex.search(records: [longRecord], query: "early message needle", scope: .all, location: .all, folder: nil, includeNative: false, fullText: true)
            if !longResult.partial { break }
        }
        check("history: incremental search retains matches before preview tail", !longResult.partial && longResult.hits.first?.snippet.contains("early message needle") == true && longResult.hits.first?.entries.count == 81)
        let giant = root.appendingPathComponent("giant.jsonl")
        var giantData = line(["type": "session_meta", "payload": ["id": "66666666-6666-4666-8666-666666666666", "cwd": root.path]])
        giantData.append(line(["type": "ignored", "payload": String(repeating: "x", count: 1800)]))
        giantData.append(line(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "After oversized line"]]]]))
        try? giantData.write(to: giant)
        let giantIndex = ChatHistoryIndex(); giantIndex.maxBytesPerFile = 512
        let giantRecord = ChatHistoryRecord(localChatID: UUID(), agentID: "codex", title: "Giant", cwd: root.path, transcriptPath: giant.path)
        var giantResult = ChatHistoryResult()
        for _ in 0..<10 { giantResult = giantIndex.search(records: [giantRecord], query: "After oversized", scope: .all, location: .all, folder: nil, includeNative: false, fullText: true) }
        check("history: oversized record advances with explicit partial warning", giantResult.partial && giantResult.hits.first?.snippet.contains("After oversized") == true && giantResult.hits.first?.record.issue?.contains("oversized") == true)
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        let checkout = root.appendingPathComponent("linked", isDirectory: true)
        let gitDir = repository.appendingPathComponent(".git", isDirectory: true)
        let worktreeGit = gitDir.appendingPathComponent("worktrees/linked", isDirectory: true)
        Paths.ensure(worktreeGit); Paths.ensure(checkout)
        try? ("gitdir: " + worktreeGit.path + "\n").write(to: checkout.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try? "../..\n".write(to: worktreeGit.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        check("history: repository scope joins linked worktrees", ChatHistoryIndex.repositoryKey(repository.path) == ChatHistoryIndex.repositoryKey(checkout.path))
        let repoRecords = [ChatHistoryRecord(localChatID: UUID(), agentID: "other", title: "Main", cwd: repository.path), ChatHistoryRecord(localChatID: UUID(), agentID: "other", title: "Linked", cwd: checkout.path), ChatHistoryRecord(localChatID: UUID(), agentID: "other", title: "Outside", cwd: root.path)]
        check("history: folder scope stays exact", index.search(records: repoRecords, query: "", scope: .all, location: .folder, folder: repository.path, includeNative: false, fullText: false).hits.count == 1)
        check("history: repository scope includes only shared repo", index.search(records: repoRecords, query: "", scope: .all, location: .repository, folder: repository.path, includeNative: false, fullText: false).hits.count == 2)
        let largeRegistry = (0..<550).map { n in
            ChatHistoryRecord(localChatID: UUID(), agentID: "other", title: "Registry \(n)", cwd: root.path)
        }
        check("history: metadata switcher is not truncated by transcript budget", index.search(records: largeRegistry, query: "", scope: .active, location: .all, folder: nil, includeNative: false, fullText: false).hits.count == 550)
        let store = ChatHistoryStore()
        store.search(records: repoRecords, query: "Main", scope: .all, location: .all, folder: nil, native: false, fullText: false)
        store.search(records: repoRecords, query: "Linked", scope: .all, location: .all, folder: nil, native: false, fullText: false)
        check("history: superseded asynchronous result cannot replace newest query", waitUntil(3) { !store.loading } && store.result.hits.count == 1 && store.result.hits.first?.record.title == "Linked")
        store.cancel()
        check("history: provider fixtures unchanged by indexing", (try? Data(contentsOf: codex)) == codexData && (try? Data(contentsOf: archived)) == archiveData && (try? Data(contentsOf: claude)) == claudeData + append)
        if let hit = amber.hits.first {
            let window = makeWindow()
            defer { window.orderOut(nil) }
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let host = NSHostingView(rootView: VStack(spacing: 0) {
                    ChatHistoryHeader(query: .constant("amber lighthouse"), scope: .constant(.all), location: .constant(.all), fullHistory: .constant(true), native: .constant(true), loading: false, onClose: {}, onSubmit: {})
                    Divider()
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("1 result").font(.caption).foregroundStyle(.secondary)
                            ChatHistoryRow(hit: hit)
                            Spacer()
                        }.padding(20).frame(width: 320)
                        Divider()
                        ChatHistoryPreview(hit: hit)
                    }
                    Divider()
                    HStack { Text("Preview is read-only.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Open read-only") {}; Button("Resume saved session") {} }.padding(16)
                }.frame(width: 940, height: 620).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
                host.sizingOptions = []
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 940, height: 620)
                window.contentView = host
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                check("history: \(name) preview snapshot", render(host, to: root.appendingPathComponent("history-\(name).png")))
                for loading in [false, true] {
                    let empty = NSHostingView(rootView: VStack(spacing: 0) {
                        ChatHistoryHeader(query: .constant("unmatched phrase"), scope: .constant(.archived), location: .constant(.folder), fullHistory: .constant(true), native: .constant(false), loading: loading, onClose: {}, onSubmit: {})
                        Divider(); ChatHistoryEmpty(loading: loading)
                    }.frame(width: 940, height: 620).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
                    empty.sizingOptions = []; empty.appearance = host.appearance
                    empty.frame = host.frame; window.contentView = empty
                    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                    check("history: \(name) \(loading ? "loading" : "empty") snapshot", render(empty, to: root.appendingPathComponent("history-\(name)-\(loading ? "loading" : "empty").png")))
                }
            }
        }
    }
}
