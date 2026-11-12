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
        }
        let url = dir.appendingPathComponent("panel-feedback-fixture.json")
        let id = UUID()
        let batch = PanelFeedbackDelivery.Batch(id: "pending-review-test", chatID: id, comments: [c], text: text, state: .queued)
        if let data = try? JSONEncoder.hantuu.encode([batch]) { try? data.write(to: url) }
        let service = PanelFeedbackDelivery(url: url)
        check("panel feedback: restart retains unconfirmed batch", service.latest(for: id)?.state == .failed && service.latest(for: id)?.comments == [c])
        service.acknowledge(id: batch.id, chatID: UUID())
        check("panel feedback: wrong chat cannot acknowledge", service.latest(for: id)?.state == .failed)
        service.acknowledge(id: batch.id, chatID: id)
        check("panel feedback: matching receipt delivers", service.latest(for: id)?.state == .delivered)
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
