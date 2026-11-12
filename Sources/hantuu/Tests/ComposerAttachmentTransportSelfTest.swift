import AppKit
import ImageIO
import UniformTypeIdentifiers

extension SelfTest {
    /// Fixture-only: no provider process, real transcript, clipboard or account access.
    static func composerAttachmentTransport(_ dir: URL) {
        let folder = dir.appendingPathComponent("attachment-transport", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("opaque-live-fixture.png")
        let wroteImage = writeSolidImage(to: image, color: .blue, size: 128, type: .png)
        // NSBitmapImageRep can label this sRGB PNG as calibrated RGB.
        // Converting colorAt to sRGB then changes pure blue to (0.017, 0.198, 1).
        // Decode through ImageIO into an explicit RGBA sRGB buffer instead. At alpha 1
        // premultiplied and straight RGB are identical; a transparent pixel still fails.
        var pixel = [UInt8](repeating: 0, count: 4)
        let decodedPixel = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let source = CGImageSourceCreateWithURL(image as CFURL, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        check("attachments: live image fixture is opaque blue rather than transparent black",
              wroteImage && decodedPixel && Double(pixel[3]) / 255 > 0.99 && Double(pixel[2]) / 255 > 0.99 && Double(pixel[0]) / 255 < 0.01,
              "wrote=\(wroteImage), decoded=\(decodedPixel), sRGB premultiplied RGBA8=\(pixel)")
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
        // Real 2.1.322 /plan line shapes: command XML as a string, local output, then
        // a turnCompanion containing only an absolute source reference. No base64 block.
        func encodeRecord(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        let commandRecord: [String: Any] = ["type": "user", "uuid": "command", "promptId": "prompt", "sessionId": "session",
            "message": ["role": "user", "content": "<command-name>/plan</command-name>\n<command-message>plan</command-message>\n<command-args>Inspect the fixture\nDo not change files. [Image #1]</command-args>"]]
        let outputRecord: [String: Any] = ["type": "user", "uuid": "output", "parentUuid": "command", "promptId": "prompt", "sessionId": "session",
            "message": ["role": "user", "content": "<local-command-stdout>Enabled plan mode</local-command-stdout>"]]
        let companion: [String: Any] = ["type": "user", "uuid": "source", "parentUuid": "output", "promptId": "prompt", "sessionId": "session",
            "isMeta": true, "turnCompanion": true,
            "message": ["role": "user", "content": [["type": "text", "text": "[Image: source: \(image.path)]"]]]]
        var sourceParser = ClaudeTranscriptParser()
        let invocation = sourceParser.parse(line: encodeRecord(commandRecord))
        let output = sourceParser.parse(line: encodeRecord(outputRecord))
        let sourceEntry = sourceParser.parse(line: encodeRecord(companion))
        let merged = ReaderEntries.merging(invocation + output, sourceEntry)
        check("attachments: Claude source companion upgrades its original command without duplication",
              sourceEntry.first?.id == "command" && sourceEntry.first?.kind == .user && sourceEntry.first?.images == [image.path] &&
              merged.filter { $0.id == "command" }.count == 1 && merged.count == 2)
        pending.enqueue(id: "source-plan", text: command, files: [.init(path: image.path, image: true)], agentID: "claude", existing: [])
        pending.markSubmitted(id: "source-plan")
        _ = pending.reconcile(invocation + output)
        check("attachments: command marker alone never acknowledges a missing image", !pending.isEmpty)
        check("attachments: owned Claude source reference acknowledges the image command once",
              pending.reconcile(sourceEntry).first?.replacesPendingID == "source-plan" && pending.isEmpty &&
              pending.reconcile(sourceEntry).first?.replacesPendingID == nil)
        let receiptData = [commandRecord, outputRecord, companion].map { encodeRecord($0) + Data([10]) }.reduce(Data(), +)
        let sourceReceipt = LiveCheckRules.imageReceipt(receiptData, agent: "claude", token: "Inspect the fixture")
        check("attachments: diagnostic distinguishes source reference from native image block",
              sourceReceipt.count == 0 && sourceReceipt.sourceReferences == [image.path])
        for (field, value) in [("promptId", "another-prompt"), ("sessionId", "another-session"), ("parentUuid", "unrelated")] {
            var parser = ClaudeTranscriptParser()
            _ = parser.parse(line: encodeRecord(commandRecord))
            _ = parser.parse(line: encodeRecord(outputRecord))
            var wrong = companion
            wrong[field] = value
            check("attachments: source companion rejects wrong \(field)", parser.parse(line: encodeRecord(wrong)).isEmpty)
            if field == "sessionId" {
                let following: [String: Any] = ["type": "assistant", "uuid": "following", "sessionId": "session",
                    "message": ["content": [["type": "text", "text": "Original session answer"]]]]
                let followingEntries = parser.parse(line: encodeRecord(following))
                check("attachments: rejected source companion cannot change evidence session",
                      followingEntries.count == 1 && followingEntries.first?.kind == .assistant &&
                      followingEntries.first?.text == "Original session answer")
                var nextSession = following
                nextSession["sessionId"] = "real-next-session"
                check("attachments: a genuine subsequent session still emits its boundary",
                      parser.parse(line: encodeRecord(nextSession)).contains { $0.kind == .notice && $0.text == "Conversation changed" })
            }
        }
        var missingFlag = companion
        missingFlag.removeValue(forKey: "turnCompanion")
        var flagParser = ClaudeTranscriptParser()
        _ = flagParser.parse(line: encodeRecord(commandRecord))
        _ = flagParser.parse(line: encodeRecord(outputRecord))
        check("attachments: unrelated meta never supplies a command image", flagParser.parse(line: encodeRecord(missingFlag)).isEmpty)
        var endedParser = ClaudeTranscriptParser()
        _ = endedParser.parse(line: encodeRecord(commandRecord))
        _ = endedParser.parse(line: encodeRecord(outputRecord))
        _ = endedParser.parse(line: encodeRecord(["type": "assistant", "uuid": "answer", "message": ["content": [["type": "text", "text": "Done"]]]]))
        check("attachments: a later source cannot attach after the assistant answered", endedParser.parse(line: encodeRecord(companion)).isEmpty)
        check("attachments: command-image history recalls the command without native chips",
              ComposerPromptHistory.prompts(from: merged) == [command])
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
