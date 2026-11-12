import Foundation

extension SelfTest {
    /// Local value fixtures only. Does not launch a terminal, provider or application.
    static func composerParity(_ dir: URL) {
        check("submission: ready footer permits ordinary input",
              ReaderSubmissionGuard.refusal(screen: "? for shortcuts", waiting: false, command: nil) == nil)
        check("submission: structured wait wins over a command suggestion",
              ReaderSubmissionGuard.refusal(screen: "/model  Choose a model\nenter to select", waiting: true, command: "/model") != nil)
        check("submission: trust prompt blocks command input",
              ReaderSubmissionGuard.refusal(screen: "/model  Choose a model\nDo you trust this folder?\nenter to confirm", waiting: false, command: "/model") != nil)
        check("submission: generic picker blocks ordinary text",
              ReaderSubmissionGuard.refusal(screen: "Select a model\nenter to select", waiting: false, command: nil) != nil)
        check("submission: update prompt blocks a command",
              ReaderSubmissionGuard.refusal(screen: "Update available\n/model  Choose model\nenter to select", waiting: false, command: "/model") != nil)

        let shortcuts = ReaderModeMenuTarget.composerItems()
        check("parity: message focus shortcut is Command-L", shortcuts.first?.keyEquivalent == "l" && shortcuts.first?.keyEquivalentModifierMask == [.command])
        check("parity: attachment shortcut is Option-Command-A and leaves Archive unchanged", shortcuts.last?.keyEquivalent == "a" && shortcuts.last?.keyEquivalentModifierMask == [.command, .option])

        var saved = SavedChat(id: UUID(), projectID: UUID(), agentID: "claude", sessionID: nil,
                              title: "Recovery fixture", firstPrompt: nil, transcriptPath: nil,
                              createdAt: Date(), worktree: nil, pinnedAt: nil)
        saved.userTitle = "Retained title"
        saved.archivedAt = Date(timeIntervalSince1970: 10)
        saved.manualUnread = true
        saved.seenSessionID = "fixture-session"
        saved.requestedWorktree = true
        saved.resumeOnRetry = true
        if let encoded = try? JSONEncoder().encode(saved),
           var object = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] {
            object["pendingMessages"] = ["invalid": true]
            let malformed = try? JSONSerialization.data(withJSONObject: object)
            let decoded = malformed.flatMap { try? JSONDecoder().decode(SavedChat.self, from: $0) }
            check("parity: malformed optional recovery keeps its chat", decoded?.id == saved.id && decoded?.pendingMessages == nil)
            check("parity: pending recovery decoder retains build7 sidebar metadata",
                  decoded?.userTitle == saved.userTitle && decoded?.archivedAt == saved.archivedAt && decoded?.manualUnread == true &&
                  decoded?.seenSessionID == saved.seenSessionID && decoded?.requestedWorktree == true && decoded?.resumeOnRetry == true)
            object.removeValue(forKey: "pendingMessages")
            let legacy = try? JSONSerialization.data(withJSONObject: object)
            check("parity: older state loads without recovery field", legacy.flatMap { try? JSONDecoder().decode(SavedChat.self, from: $0) }?.id == saved.id)
        } else { check("parity: saved chat fixture encodes", false) }

        func drains(_ blocked: String? = nil) -> Bool {
            var screen = TerminalScreen.State(ready: true, busy: blocked == "busy", menu: nil)
            if blocked == "menu" { screen.menu = ScreenMenu(kind: .menu, line: "Select a model") }
            if blocked == "starting" { screen.ready = false }
            return ReaderQueueDrain.canStart(screen: screen, activity: blocked == "working" ? .working : .idle,
                waiting: blocked == "permission", turnActive: blocked == "active-turn", identityWaiting: blocked == "identity",
                paused: blocked == "paused", inputNeedsReview: blocked == "partial-input", editing: blocked == "editing",
                transportBusy: blocked == "transport")
        }
        check("background queue: ready boundary does not require a selected chat", drains())
        for reason in ["busy", "menu", "starting", "working", "permission", "active-turn", "identity", "paused", "partial-input", "editing", "transport"] {
            check("background queue: retains the \(reason) guard", !drains(reason))
        }
        var firstIdentity = PendingReaderMessages()
        firstIdentity.enqueue(id: "first", text: "First send", files: [], agentID: "codex", existing: [], stage: .typing)
        firstIdentity.adoptInitialSession("verified-first-session")
        check("parity: first session discovery binds pending transport without pausing it",
              firstIdentity.recovery(id: "first")?.sessionID == "verified-first-session" && !firstIdentity.queuePaused && firstIdentity.stage(id: "first") == .typing)
        firstIdentity.replacedSession()
        firstIdentity.adoptInitialSession("replacement")
        check("parity: replacement cannot rebind old input to the new session",
              firstIdentity.recovery(id: "first")?.sessionID == "verified-first-session" && firstIdentity.stage(id: "first") == .failed && firstIdentity.queuePaused)

        var replacedBatch = PendingReaderMessages()
        for id in ["one", "two"] {
            replacedBatch.enqueue(id: id, text: id, files: [], agentID: "codex", existing: [], sessionID: "old-session")
            replacedBatch.markSubmitted(id: id)
        }
        replacedBatch.sendNowEnabled = true
        _ = replacedBatch.requestDelivery(id: "one")
        replacedBatch.replacedSession()
        let wrongBatch = replacedBatch.reconcile([ReaderEntry(id: "new-session-batch", kind: .user, text: "one\ntwo")])
        check("parity: replacement cannot acknowledge an old promoted batch",
              replacedBatch.entries.count == 2 && wrongBatch.first?.replacesPendingIDs == nil && wrongBatch.first?.replacesPendingID == nil)

        for images in [false, true] {
            var plan = PendingReaderMessages()
            let files: [ComposerMessage.OutgoingFile] = images ? [.init(path: dir.appendingPathComponent("plan.png").path, image: true)] : []
            plan.enqueue(id: "plan", text: "/plan First line\nSecond line", files: files, agentID: "codex", existing: [])
            plan.markSubmitted(id: "plan")
            let entry = ReaderEntry(id: "plan-native", kind: .user,
                                    text: images ? "[Image #1] First line\nSecond line" : "First line\nSecond line",
                                    images: images ? ["data:image/png;base64,fixture"] : [])
            check("parity: Codex inline Plan acknowledges args-only transcript, images=\(images)", plan.reconcile([entry]).first?.replacesPendingID == "plan" && plan.isEmpty)
        }

        for provider in ["claude", "codex"] {
            var pending = PendingReaderMessages()
            let attachment = ComposerAttachment(url: dir.appendingPathComponent("original.tiff"), preparation: .failed("Fixture error"), preparedURL: dir.appendingPathComponent("converted.png"))
            pending.enqueue(id: "waiting", text: "Same prompt", files: [], agentID: provider, existing: [], stage: .waiting, attachments: [attachment], sessionID: "session-fixture")
            pending.enqueue(id: "typing", text: "Partial input", files: [], agentID: provider, existing: [], stage: .typing)
            pending.enqueue(id: "sent", text: "Already submitted", files: [], agentID: provider, existing: [])
            pending.markSubmitted(id: "sent")
            check("parity: \(provider) promotion discloses existing agent queue scope", pending.entries.first(where: { $0.id == "waiting" })?.pendingActions?.first == "sendWithQueue")
            _ = pending.reconcile([ReaderEntry(id: "coincidental", kind: .user, text: "Same prompt")])
            check("parity: \(provider) local waiting message cannot be acknowledged", pending.stage(id: "waiting") == .waiting)
            pending.hold(reason: "Interrupted fixture")
            check("parity: \(provider) interruption holds unsent and submitted work distinctly", pending.queuePaused && pending.stage(id: "waiting") == .waiting && pending.stage(id: "typing") == .failed && pending.stage(id: "sent") == .unconfirmed)
            let data = try? JSONEncoder().encode(pending)
            var restored = data.flatMap { try? JSONDecoder().decode(PendingReaderMessages.self, from: $0) } ?? PendingReaderMessages()
            restored.recoverAfterLaunch()
            check("parity: \(provider) relaunch preserves attachment identity, errors and target", restored.recovery(id: "waiting")?.attachments == [attachment] && restored.recovery(id: "waiting")?.sessionID == "session-fixture")
            check("parity: \(provider) relaunch never makes held work replayable", restored.queuePaused && restored.stage(id: "sent") == .unconfirmed && restored.stage(id: "typing") == .failed)
            let acknowledged = restored.reconcile([ReaderEntry(id: "accepted", kind: .user, text: "Already submitted")])
            check("parity: \(provider) late acknowledgement resolves uncertainty", acknowledged.first?.replacesPendingID == "sent" && restored.stage(id: "sent") == nil)
            restored.markSubmitted(id: "waiting")
            _ = restored.reconcile([ReaderEntry(id: "coincidental", kind: .user, text: "Same prompt")])
            check("parity: \(provider) pre-submission history cannot acknowledge a later send", restored.stage(id: "waiting") != nil)
            check("parity: \(provider) cleanup protects prepared attachment references", restored.referencedAttachmentPaths.contains(attachment.preparedURL!.path))

            var replay = PendingReaderMessages()
            let oldInterruption = ReaderEntry(id: "old-interruption", kind: .notice, text: "Interrupted")
            replay.enqueue(id: "after-interruption", text: "New turn", files: [], agentID: provider, existing: [oldInterruption], stage: .waiting)
            _ = replay.reconcile([oldInterruption])
            check("parity: \(provider) historical interruption cannot pause new work", !replay.queuePaused && replay.stage(id: "after-interruption") == .waiting)

            var timed = PendingReaderMessages()
            timed.enqueue(id: "timeout", text: "A response", files: [], agentID: provider, existing: [])
            timed.markSubmitted(id: "timeout")
            check("parity: \(provider) acknowledgement deadline creates recoverable uncertainty", timed.expire(now: Date().addingTimeInterval(31)) && timed.stage(id: "timeout") == .unconfirmed && timed.recovery(id: "timeout")?.text == "A response")
            check("parity: \(provider) repeated timeout is stable", !timed.expire(now: Date().addingTimeInterval(60)))

            var order = PendingReaderMessages()
            for id in ["one", "two", "three"] { order.enqueue(id: id, text: id, files: [], agentID: provider, existing: [], stage: .waiting) }
            order.move(id: "three", offset: -1)
            check("parity: \(provider) waiting reorder preserves content", order.entries.map(\.id) == ["one", "three", "two"] && order.recovery(id: "three")?.text == "three")
            order.remove(id: "three")
            check("parity: \(provider) explicit removal keeps neighboring work", order.entries.map(\.id) == ["one", "two"])
        }
    }
}
