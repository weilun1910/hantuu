import AppKit
import SwiftUI
import WebKit

extension SelfTest {
    static func panelFeedback(_ dir: URL) {
        let c = ReviewComment(root: "/project", path: "file.swift", side: "new", start: 2, end: 2,
                              quoted: ["let value = 1"], body: "Use the supplied value", created: Date(timeIntervalSince1970: 1_700_000_000), revision: "base:diff")
        let encoded = try? JSONEncoder.hantuu.encode(c)
        let restored = encoded.flatMap { try? JSONDecoder.hantuu.decode(ReviewComment.self, from: $0) }
        check("panel feedback: revision and quote survive persistence", restored == c)
        let text = CommentMessage.build([c], folder: "/project")
        func line(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        let wrapped = "\n\n<pasted_content id=\"0141\">\n" + text + "\n</pasted_content id=\"0141\">\n"
        var pasteParser = ClaudeTranscriptParser()
        let pasted = pasteParser.parse(line: line(["type": "user", "uuid": "pasted-review",
            "message": ["role": "user", "content": wrapped]]))
        var pastePending = PendingReaderMessages()
        pastePending.enqueue(id: "review-paste", text: text, files: [], agentID: "claude", existing: [])
        check("panel feedback Claude: native pasted envelope preserves canonical review and receipt",
              pasted.first?.text == text && pastePending.reconcile(pasted).first?.replacesPendingID == "review-paste")
        let mismatched = wrapped.replacingOccurrences(of: "</pasted_content id=\"0141\">", with: "</pasted_content id=\"9999\">")
        check("panel feedback Claude: malformed and quoted envelopes stay visible",
              ClaudePastedContent.unwrap(mismatched).contains("<pasted_content") &&
              ClaudePastedContent.unwrap("Explain this: " + wrapped).contains("<pasted_content"))
        for agent in ["claude", "codex"] {
            var pending = PendingReaderMessages()
            var claude = ClaudeTranscriptParser()
            var codex = CodexTranscriptParser()
            func user(_ id: String) -> [ReaderEntry] {
                if agent == "claude" {
                    return claude.parse(line: line(["type": "attachment", "uuid": id, "attachment": [
                        "type": "queued_command", "prompt": text, "origin": ["kind": "human"],
                        "commandMode": "prompt", "source_uuid": "source-" + id]]))
                }
                let event = codex.parse(line: line(["type": "event_msg", "payload": ["type": "user_message", "message": text]]))
                let response = codex.parse(line: line(["type": "response_item", "payload": ["type": "message", "role": "user",
                    "content": [["type": "input_text", "text": text]]]]))
                return event + response
            }
            let old = user("old")
            check("panel feedback \(agent): actual provider shape parses once", old.count == 1 && old.first?.text == text)
            pending.enqueue(id: "review", text: text, files: [], agentID: agent, existing: old)
            check("panel feedback \(agent): old text cannot acknowledge", pending.reconcile(old).allSatisfy { $0.replacesPendingID == nil })
            let fresh = user("fresh")
            check("panel feedback \(agent): exact transcript acknowledgement", pending.reconcile(fresh).first?.replacesPendingID == "review")
            check("panel feedback \(agent): receipt consumes once", pending.reconcile(fresh).allSatisfy { $0.replacesPendingID == nil })

            // First discovery attaches the identity for the send already in progress.
            // A later switch must still discard the previous conversation's queue.
            let app = AppModel()
            let project = Project(path: dir.path)
            let chat = Chat(projectID: project.id, agentID: agent)
            chat.status = .ended
            app.projects = [project]; app.chats = [chat]
            app.transcriptLocations = TranscriptLocations(claude: dir, codex: dir)
            let firstPath = dir.appendingPathComponent("review-first-\(agent).jsonl")
            let nextPath = dir.appendingPathComponent("review-next-\(agent).jsonl")
            try? Data().write(to: firstPath); try? Data().write(to: nextPath)
            chat.pendingMessages.enqueue(id: "first-review", text: text, files: [], agentID: agent, existing: [])
            app.followSession(chat, session: .init(id: "11111111-1111-4111-8111-111111111111", path: firstPath.path), verifiedCodex: agent == "codex")
            check("panel feedback \(agent): first identity keeps the pending receipt", chat.pendingMessages.entries.count == 1)
            let receipt = chat.pendingMessages.reconcile(user("first-session-receipt"))
            check("panel feedback \(agent): first session acknowledges exactly once", receipt.first?.replacesPendingID == "first-review" && chat.pendingMessages.isEmpty)
            chat.pendingMessages.enqueue(id: "old-review", text: text, files: [], agentID: agent, existing: [])
            app.followSession(chat, session: .init(id: "22222222-2222-4222-8222-222222222222", path: nextPath.path), verifiedCodex: agent == "codex")
            check("panel feedback \(agent): another session drops old pending feedback", chat.pendingMessages.isEmpty)
            chat.follower?.stop()
        }
        let url = dir.appendingPathComponent("panel-feedback-fixture.json")
        let id = UUID()
        let batch = PanelFeedbackDelivery.Batch(id: "pending-review-test", chatID: id, comments: [c], text: text, state: .queued)
        let promoted = PanelFeedbackDelivery.Batch(id: "pending-review-promoted", chatID: id, comments: [c], text: text, state: .queued)
        if let data = try? JSONEncoder.hantuu.encode([batch, promoted]) { try? data.write(to: url) }
        let service = PanelFeedbackDelivery(url: url)
        check("panel feedback: restart retains unconfirmed batch", service.latest(for: id)?.state == .failed && service.latest(for: id)?.comments == [c])
        service.acknowledge(id: batch.id, chatID: UUID())
        check("panel feedback: wrong chat cannot acknowledge", service.latest(for: id)?.state == .failed)
        service.acknowledge(id: batch.id, chatID: id)
        check("panel feedback: matching receipt delivers", service.batches.first { $0.id == batch.id }?.state == .delivered)
        let receiptModel = AppModel()
        service.connect(receiptModel)
        var combined = ReaderEntry(id: "combined-user", kind: .user, text: text)
        combined.replacesPendingIDs = [promoted.id]
        receiptModel.readerAppend.send((UUID(), [combined]))
        check("panel feedback: batch receipt cannot acknowledge another chat", service.latest(for: id)?.state == .failed)
        receiptModel.readerAppend.send((id, [combined]))
        check("panel feedback: promoted batch receipt acknowledges its review", service.latest(for: id)?.state == .delivered)
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        check("panel feedback: receipts are owner-only", mode?.intValue == 0o600)
        panelFeedbackSnapshots(dir)
        panelFeedbackBarSnapshots(dir, comment: c)
    }

    private static func panelFeedbackSnapshots(_ dir: URL) {
        let page = DiffPage()
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -4000, width: 360, height: 520),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.view
        page.view.frame = NSRect(x: 0, y: 0, width: 360, height: 520)
        window.orderFrontRegardless()
        defer { page.close(); window.orderOut(nil); window.close() }
        let output = dir.appendingPathComponent("snapshots", isDirectory: true)
        Paths.ensure(output)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            page.show(panelFeedbackSnapshotPayload())
            let shown = waitUntil(5) { (js(page.page, "document.body.innerText.includes('Outdated')") as? Bool) == true }
            check("panel feedback snapshot \(name): outdated quote rendered", shown)
            let themed = waitUntil(3) {
                (js(page.page, "window.matchMedia('(prefers-color-scheme: dark)').matches") as? Bool) == (name == "dark")
            }
            check("panel feedback snapshot \(name): appearance applied", themed)
            _ = js(page.page, "document.querySelector('.line-comment').click(); document.querySelector('.cbox textarea').value = 'Keep this draft during refresh'; document.querySelector('.cbox textarea').dispatchEvent(new Event('input')); true")
            check("panel feedback snapshot \(name)", shown && themed && render(page.view, to: output.appendingPathComponent("panel-feedback-\(name).png")))
        }
    }

    private static func panelFeedbackBarSnapshots(_ dir: URL, comment: ReviewComment) {
        let previous = Paths.dataDir
        Paths.dataDir = dir.appendingPathComponent("panel-feedback-bar-data", isDirectory: true)
        defer { Paths.dataDir = previous }
        let app = AppModel()
        let project = Project(path: dir.path)
        let chat = Chat(projectID: project.id, agentID: "claude")
        app.projects = [project]; app.chats = [chat]; app.selectedChatID = chat.id
        var saved = ReviewSavedState()
        saved.comments[chat.id.uuidString] = [comment]
        saved.save()
        let review = ReviewCenter()
        review.fixtureMode = true
        review.configure(model: app)
        let host = NSHostingView(rootView: CommentBar().environmentObject(review).environmentObject(app))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -4000, width: 360, height: 90),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        check("panel feedback bar: fixture owns retained comment", waitUntil(3) { review.currentComments.count == 1 })
        let output = dir.appendingPathComponent("snapshots", isDirectory: true)
        Paths.ensure(output)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            check("panel feedback bar snapshot \(name)", render(host, to: output.appendingPathComponent("panel-feedback-bar-\(name).png")))
        }
    }

    /// Deterministic payload for the existing web snapshot harness. Includes an outdated quote.
    static func panelFeedbackSnapshotPayload() -> DiffPayload {
        DiffPayload(key: "feedback-fixture", path: "example.swift",
                    rows: [DiffRow(t: .context, o: 1, n: 1, s: "let value = 1")],
                    comments: [DiffPayload.Comment(id: "outdated", side: "new", start: 1, end: 1,
                        body: "Keep this review visible after edits", quoted: ["let value = 0"], revision: "previous")],
                    keepScroll: false, revision: "current", token: "fixture", chat: "fixture-chat")
    }
}
