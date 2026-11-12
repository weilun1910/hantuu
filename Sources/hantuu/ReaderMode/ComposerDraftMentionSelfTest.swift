import AppKit

extension SelfTest {
    /// Scratch-only fixtures. Registration belongs to the reader-mode test coordinator.
    static func composerDraftMention(_ dir: URL) {
        let root = dir.appendingPathComponent("draft-mention-fixtures", isDirectory: true)
        Paths.ensure(root)
        let file = root.appendingPathComponent("composer-drafts.json")
        let chat = UUID(), other = UUID()
        let attachmentURL = root.appendingPathComponent("notes 'quoted'.md")
        try? "fixture".write(to: attachmentURL, atomically: true, encoding: .utf8)
        let attachment = ComposerAttachment(url: attachmentURL, preparation: .preparing)
        let draft = ComposerDraft(text: "hello\nworld", selection: NSRange(location: 3, length: 2), attachments: [attachment])
        let store = ComposerDraftStore(url: file)
        store.save(draft, chatID: chat)
        store.save(ComposerDraft(text: "aside", selection: NSRange(location: 99, length: 99), attachments: []), chatID: chat, scope: "side")
        do { try store.flush() } catch { check("draft: atomic flush succeeds", false, error.localizedDescription) }
        let loaded = ComposerDraftStore(url: file)
        check("draft: scoped persistence retains text and caret", loaded.draft(chatID: chat) == draft && loaded.draft(chatID: other) == nil)
        check("draft: Side caret is clamped independently", loaded.draft(chatID: chat, scope: "side")?.clampedSelection == NSRange(location: 5, length: 0))
        check("draft: attachment paths survive cleanup", loaded.referencedAttachmentPaths.contains(attachmentURL.path))
        if let state = loaded.draft(chatID: chat)?.restoredAttachments().first?.preparation, case .failed = state {
            check("draft: interrupted preparation becomes actionable failure", true)
        } else { check("draft: interrupted preparation becomes actionable failure", false) }
        let emoji = ComposerDraft(text: "👻x", selection: NSRange(location: 1, length: 0), attachments: [])
        check("draft: caret never splits a surrogate pair", emoji.clampedSelection.location == 0)

        var recall = ComposerPromptRecall()
        let history = ["first", "second"]
        check("recall: Up preserves multiline navigation", recall.move(older: true, text: "draft\nline", selection: NSRange(location: 7, length: 0), history: history) == nil)
        let previous = recall.move(older: true, text: "draft", selection: NSRange(location: 2, length: 0), history: history)
        check("recall: Up retrieves most recent human prompt", previous?.0 == "second")
        let restored = recall.move(older: false, text: "second", selection: NSRange(location: 6, length: 0), history: history)
        check("recall: Down restores original draft and caret", restored?.0 == "draft" && restored?.1 == NSRange(location: 2, length: 0))
        var claude = ClaudeTranscriptParser(scope: .chat)
        var codex = CodexTranscriptParser()
        let claudeLines = [
            #"{"type":"user","uuid":"human","message":{"role":"user","content":"human question"}}"#,
            #"{"type":"user","uuid":"tool","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"not a prompt"}]}}"#,
            #"{"type":"user","uuid":"child","isSidechain":true,"message":{"role":"user","content":"child question"}}"#,
            #"{"type":"user","uuid":"meta","isMeta":true,"message":{"role":"user","content":"system injection"}}"#,
        ]
        let claudeEntries = claudeLines.flatMap { claude.parse(line: Data($0.utf8)) }
        let codexLines = [
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"human question"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"system","content":[{"type":"input_text","text":"system injection"}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"t","output":"tool result"}}"#,
        ]
        let codexEntries = codexLines.flatMap { codex.parse(line: Data($0.utf8)) }
        check("recall: Claude filters tool, meta and sidechain entries", ComposerPromptHistory.prompts(from: claudeEntries) == ["human question"])
        check("recall: Codex filters system and tool entries", ComposerPromptHistory.prompts(from: codexEntries) == ["human question"])
        for (provider, text) in [("claude", "[Image #1] inspect the fixture"), ("codex", "inspect the fixture\n[Image 1]")] {
            let entry = ReaderEntry(id: provider, kind: .user, text: text, images: ["/fixture.png"])
            check("recall: \(provider) recalls human text without attachment chip markers",
                  ComposerPromptHistory.prompts(from: [entry]) == ["inspect the fixture"])
        }
        check("recall: literal image marker without an attachment remains human text",
              ComposerPromptHistory.prompts(from: [ReaderEntry(id: "literal", kind: .user, text: "Explain [Image #1]")]) == ["Explain [Image #1]"])
        check("recall: image-only sends do not become empty history rows",
              ComposerPromptHistory.prompts(from: [ReaderEntry(id: "image", kind: .user, text: "[Image #1]", images: ["/fixture.png"]) ]).isEmpty)

        check("mention: email addresses never open picker", ComposerMentionQuery.parse("x@y", selection: NSRange(location: 3, length: 0)) == nil)
        let query = ComposerMentionQuery.parse("look @Source rest", selection: NSRange(location: 9, length: 0))
        check("mention: token under caret preserves surrounding prose", query?.search == "Sou" && query?.range == NSRange(location: 5, length: 7))
        let outside = root.appendingPathComponent("escape")
        try? FileManager.default.createSymbolicLink(atPath: outside.path, withDestinationPath: root.deletingLastPathComponent().path)
        let items = ComposerMentionSearch.candidates(paths: [attachmentURL.lastPathComponent, "../outside", "/absolute", "escape/composer-drafts.json"], root: root, query: "")
        check("mention: outside paths and symlink escape are excluded", items.count == 1 && items.first?.relativePath == attachmentURL.lastPathComponent)
        check("mention: apostrophes are shell quoted", items.first?.insertion == "'./notes '\\''quoted'\\''.md' ")
        let ignoredDirectory = root.appendingPathComponent("node_modules", isDirectory: true)
        Paths.ensure(ignoredDirectory)
        try? "ignored dependency".write(to: ignoredDirectory.appendingPathComponent("module.js"), atomically: true, encoding: .utf8)
        let plain = ComposerMentionSearch.plainFolderPaths(root: root)
        check("mention: non-Git discovery skips dependencies and symlinks", plain.contains(attachmentURL.lastPathComponent) && !plain.contains(where: { $0.hasPrefix("node_modules/") || $0.hasPrefix("escape/") }))
        // Exercise Git ignore rules in a fixture repository, with no network or hooks.
        func git(_ args: [String]) -> Bool {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", root.path] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
        }
        if git(["init", "-q"]) {
            try? "ignored.txt\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            try? "private fixture".write(to: root.appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)
            let matches = try? ComposerMentionSearch.items(root: root, query: "ignored")
            check("mention: Git ignores apply to untracked files", matches?.isEmpty == true)
        } else { check("mention: scratch Git setup succeeds", false) }
    }

    static func composerMentionSnapshots(_ dir: URL) {
        Paths.ensure(dir)
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
            let menu = ComposerMentionMenu(frame: NSRect(x: 0, y: 0, width: 520, height: 152))
            menu.appearance = NSAppearance(named: appearance)
            menu.show(items: [.init(relativePath: "Sources/hantuu/ReaderMode", isDirectory: true), .init(relativePath: "Sources/hantuu/ReaderMode/Composer.swift", isDirectory: false), .init(relativePath: "notes/Research notes.md", isDirectory: false)], selection: 1, status: nil)
            check("mention: \(name) snapshot renders", render(menu, to: dir.appendingPathComponent("composer-mentions-\(name).png")))
            menu.show(items: [], selection: 0, status: "No matching files")
            check("mention: \(name) empty state renders", render(menu, to: dir.appendingPathComponent("composer-mentions-empty-\(name).png")))
        }
    }
}
