import AppKit
import UniformTypeIdentifiers

extension SelfTest {
    /// Fixture-only: no provider process, real transcript, clipboard or account access.
    static func composerAttachmentTransport(_ dir: URL) {
        let folder = dir.appendingPathComponent("attachment-transport", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("opaque-live-fixture.png")
        let wroteImage = writeSolidImage(to: image, color: .blue, size: 128, type: .png)
        let pixel = (try? Data(contentsOf: image)).flatMap { NSBitmapImageRep(data: $0)?.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) }
        check("attachments: live image fixture is opaque blue rather than transparent black",
              wroteImage && pixel.map { $0.alphaComponent > 0.99 && $0.blueComponent > 0.99 && $0.redComponent < 0.01 } == true)
        let file = folder.appendingPathComponent("fixture.txt")
        try? Data("fixture".utf8).write(to: file)
        let attachment = ComposerAttachment(url: file, preparation: .failed("A fixture failure"))
        let encoded = try? JSONEncoder().encode(attachment)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(ComposerAttachment.self, from: $0) }
        check("attachments: stable identity and error survive persistence", decoded == attachment)
        ComposerAttachmentTransport.prepare([attachment], agentID: "claude") { updated, result in
            check("attachments: retry preserves identity", updated.first?.id == attachment.id)
            check("attachments: readable file becomes ready", updated.first?.preparation == .ready)
            check("attachments: file remains a local reference", (try? result.get()) == [.init(path: file.path, image: false)])
        }
        let missing = ComposerAttachment(url: folder.appendingPathComponent("missing.png"))
        ComposerAttachmentTransport.prepare([missing], agentID: "codex") { updated, result in
            if case .failure(let failure) = result {
                check("attachments: missing image identifies failed chip", failure.attachmentID == missing.id)
                if case .failed = updated[0].preparation { check("attachments: missing image remains recoverable", true) }
                else { check("attachments: missing image remains recoverable", false) }
            } else { check("attachments: missing image fails", false) }
        }
        for agent in ["claude", "codex"] {
            let command = "/review first line\nsecond line"
            let steps = ComposerMessage.steps(text: command, files: [.init(path: "/fixture.png", image: true)], agentID: agent)
            check("attachments: \(agent) multiline command precedes its image chip", steps == [.command(command), .paste(" "), .image("/fixture.png"), .pressReturn])
            check("attachments: \(agent) bare plan precedes multiple image chips",
                  ComposerMessage.steps(text: "/plan", files: [.init(path: "/first.png", image: true), .init(path: "/second.png", image: true)], agentID: agent) ==
                    [.command("/plan"), .paste(" "), .image("/first.png"), .image("/second.png"), .pressReturn])
        }
        check("attachments: transport keeps multiline command arguments", ComposerCommandTransport.invocation("/review first\nsecond")?.arguments == "first\nsecond")
        check("attachments: local absolute path is not a command token", ComposerCommandTransport.invocation("/tmp/picture.png") == nil)
        // Claude 2.1.322's local-jsx command route uses command XML plus preceding images.
        var claude = ClaudeTranscriptParser()
        let command = "/plan Inspect the fixture\nDo not change files."
        let source = "aW1hZ2U="
        let record: [String: Any] = ["type": "user", "uuid": "plan-image", "message": ["role": "user", "content": [
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": source]],
            ["type": "text", "text": "<command-name>/plan</command-name>\n<command-message>plan</command-message>\n<command-args>Inspect the fixture\nDo not change files. [Image #1]</command-args>"]
        ]]]
        let entries = claude.parse(line: try! JSONSerialization.data(withJSONObject: record))
        check("attachments: Claude native command image renders as a user message",
              entries.first?.kind == .user && entries.first?.text.hasPrefix(command) == true && entries.first?.images == ["data:image/png;base64,\(source)"])
        var pending = PendingReaderMessages()
        pending.enqueue(id: "pending-plan", text: command, files: [.init(path: image.path, image: true)], agentID: "claude", existing: [])
        let acknowledged = pending.reconcile(entries)
        let replayed = pending.reconcile(entries)
        check("attachments: Claude command image acknowledges its pending message once",
              acknowledged.first?.replacesPendingID == "pending-plan" && pending.isEmpty && replayed.first?.replacesPendingID == nil)
        var codex = CodexTranscriptParser()
        let codexRecord: [String: Any] = ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [
            ["type": "input_text", "text": "Inspect the fixture\nDo not change files. [Image #1]"],
            ["type": "input_image", "image_url": "data:image/png;base64,\(source)"]
        ]]]
        let codexEntries = codex.parse(line: try! JSONSerialization.data(withJSONObject: codexRecord))
        pending.enqueue(id: "codex-plan", text: command, files: [.init(path: image.path, image: true)], agentID: "codex", existing: [])
        check("attachments: Codex arguments-only plan receipt keeps its image and acknowledges",
              codexEntries.first?.images == ["data:image/png;base64,\(source)"] && pending.reconcile(codexEntries).first?.replacesPendingID == "codex-plan" && pending.isEmpty)
        let old = Date(timeIntervalSinceNow: -PastedImages.keep - 100)
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        check("attachments: cleanup retains persisted reference", PastedImages.cleanUp(in: folder, protectedPaths: [file.path]) == 0 && FileManager.default.fileExists(atPath: file.path))
        attachmentStateSnapshots(folder)
    }

    private static func attachmentStateSnapshots(_ folder: URL) {
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let strip = AttachmentStrip(frame: NSRect(x: 0, y: 0, width: 780, height: 40))
            strip.appearance = NSAppearance(named: appearance)
            strip.show([
                ComposerAttachment(url: folder.appendingPathComponent("Preparing.txt"), preparation: .preparing),
                ComposerAttachment(url: folder.appendingPathComponent("Ready.txt")),
                ComposerAttachment(url: folder.appendingPathComponent("Failed.txt"), preparation: .failed("File is unavailable. Retry or remove it.")),
            ])
            strip.layoutSubtreeIfNeeded()
            guard let bitmap = strip.bitmapImageRepForCachingDisplay(in: strip.bounds) else {
                check("attachments: \(name) snapshot allocates", false); continue
            }
            strip.cacheDisplay(in: strip.bounds, to: bitmap)
            let data = bitmap.representation(using: .png, properties: [:])
            try? data?.write(to: folder.appendingPathComponent("attachment-states-\(name).png"))
            check("attachments: \(name) failed chip exposes Retry", strip.chips.last?.retry.isHidden == false)
        }
    }
}
