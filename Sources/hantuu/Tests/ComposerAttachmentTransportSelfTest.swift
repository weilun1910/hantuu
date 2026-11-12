import AppKit

extension SelfTest {
    /// Fixture-only: no provider process, real transcript, clipboard or account access.
    static func composerAttachmentTransport(_ dir: URL) {
        let folder = dir.appendingPathComponent("attachment-transport", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
            check("attachments: \(agent) image and multiline retain literal command", steps == [.image("/fixture.png"), .command(command), .pressReturn])
        }
        check("attachments: transport keeps multiline command arguments", ComposerCommandTransport.invocation("/review first\nsecond")?.arguments == "first\nsecond")
        check("attachments: local absolute path is not a command token", ComposerCommandTransport.invocation("/tmp/picture.png") == nil)
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
