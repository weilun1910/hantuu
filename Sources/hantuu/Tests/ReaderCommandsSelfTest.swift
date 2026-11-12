import AppKit

extension SelfTest {
    static func readerCommands(_ dir: URL) {
        readerCommandLogic()
        readerCommandMenuProbe()
        readerCommandDiscovery(dir.appendingPathComponent("reader-commands"))
        readerCommandKeys()
        readerCommandTranscripts()
    }

    private static func readerCommandLogic() {
        let metadata = CommandFrontmatter.parse("---\nname: review\ndescription: >-\n  Inspect the changes\n  and suggest fixes.\nargument-hint: '[path]'\nuser-invocable: false # internal\n---\nBody")
        check("commands: folded metadata, quotes and comments", metadata.fields["description"] == "Inspect the changes and suggest fixes." && metadata.fields["argument-hint"] == "[path]" && metadata.fields["user-invocable"] == "false" && metadata.body == "Body")
        check("commands: absent or unfinished metadata stays body", CommandFrontmatter.parse("# Heading\ntext").fields.isEmpty && CommandFrontmatter.parse("---\ndescription: broken").fields.isEmpty)
        let personal = ReaderCommand(name: "review", description: "Personal", source: "personal", precedence: 10)
        let project = ReaderCommand(name: "review", description: "Project", source: "project", precedence: 40)
        check("commands: project wins regardless of enumeration order", ReaderCommandLogic.merged([project, personal]) == [project] && ReaderCommandLogic.merged([personal, project]) == [project])
        let hidden = ReaderCommand(name: "internal", description: "Hidden", precedence: 20, userInvocable: false)
        check("commands: a session listing cannot reintroduce a hidden skill", ReaderCommandLogic.merged([hidden] + ReaderCommandCatalog.listing("- internal: Hidden")).isEmpty)
        let plugin = ReaderCommandCatalog.listing("- browser:inspect: Inspect a page\n- plain: A skill")
        check("commands: session listing preserves plugin namespaces", plugin.map(\.name) == ["browser:inspect", "plain"])

        func query(_ s: String, caret: Int? = nil, skills: Bool = false) -> ReaderCommandLogic.Query? {
            ReaderCommandLogic.query(s, selection: NSRange(location: caret ?? (s as NSString).length, length: 0), skills: skills)
        }
        check("commands: slash at start or after whitespace opens", query("/")?.text == "" && query(" \n /co")?.text == "co")
        check("commands: arguments and prose close the menu", query("/compact ") == nil && query("/compact focus") == nil && query("please /co") == nil)
        check("commands: selection and caret outside the token close it", query("/compact args", caret: 4) == nil && ReaderCommandLogic.query("/co", selection: NSRange(location: 0, length: 3), skills: false) == nil)
        check("commands: Codex skill mentions work inside prose", query("Use $rev", skills: true)?.sigil == "$" && query("Use $rev") == nil && query("Use $review ", skills: true) == nil)
        let names = ["my-compact", "context", "compact", "commit", "checkpoint"].map { ReaderCommand(name: $0, description: "Test") }
        let ranked = ReaderCommandLogic.ranked(names, query: query("/comp")!).map(\.name)
        check("commands: prefix ranks before substring", ranked.first == "compact" && ranked.last == "my-compact")
        check("commands: fuzzy letters keep their order", ReaderCommandLogic.ranked(names, query: query("/cpt")!).contains { $0.name == "compact" })
        let compact = ReaderCommand(name: "compact", description: "Summarize")
        check("commands: Return sends only an exact slash name", ReaderCommandLogic.shouldSend(query: query("/compact")!, selected: compact) && !ReaderCommandLogic.shouldSend(query: query("/comp")!, selected: compact))
        let now = Date()
        let menu = ScreenMenu(kind: .menu, line: "Choose")
        check("commands: automatic peek is scoped to a recent command", ReaderCommandLogic.autoPeek(sentAt: now.addingTimeInterval(-2), now: now, menu: menu) && !ReaderCommandLogic.autoPeek(sentAt: now.addingTimeInterval(-7), now: now, menu: menu) && !ReaderCommandLogic.autoPeek(sentAt: nil, now: now, menu: menu) && !ReaderCommandLogic.autoPeek(sentAt: now, now: now, menu: nil))
        check("commands: screen-only panels remain visible until dismissed", TerminalScreen.analyze("Help\nEsc to close").menu?.kind == .menu && TerminalScreen.analyze("Settings\nEsc to cancel").menu?.kind == .menu)
        for agent in ["claude", "codex"] {
            let model = ReaderCommandCatalog.builtins(agent: agent).first { $0.name == "model" }
            check("commands: \(agent) model picker only without arguments", model?.opensTerminal(arguments: "") == true && model?.opensTerminal(arguments: "example-model") == false)
            check("commands: \(agent) sends slash input without a bracketed paste", ComposerMessage.steps(text: "/compact", files: [], agentID: agent) == [.command("/compact"), .pressReturn])
        }
        check("commands: file-only messages keep their leading space", ComposerMessage.steps(text: nil, files: [.init(path: "/tmp/example.txt", image: false)], agentID: "claude") == [.paste(" /tmp/example.txt"), .pressReturn])
        check("commands: unknown names still reach the agent", ComposerMessage.steps(text: "/custom:name arg", files: [], agentID: "claude") == [.command("/custom:name arg"), .pressReturn])
        check("commands: absolute paths and multiline prose stay pastes", ComposerMessage.steps(text: "/tmp/example.txt", files: [], agentID: "codex") == [.paste("/tmp/example.txt"), .pressReturn] && ComposerMessage.steps(text: "/compact\njust an example", files: [], agentID: "codex").first == .paste("/compact\njust an example"))
    }

    private static func readerCommandMenuProbe() {
        let first = (0..<8).map { ReaderCommand(name: "item-\($0)", description: "Command \($0)") }
        var walk = CommandMenuTraversal()
        walk.observe(first)
        for _ in 0..<8 { walk.observe(first) }
        check("commands probe: identical text while highlighting does not end paging", !walk.finished)
        let second = (8..<18).map { ReaderCommand(name: "item-\($0)", description: "Command \($0)") }
        walk.observe(second)
        for _ in 0..<16 { walk.observe(second) }
        check("commands probe: paging retains both pages before stopping", walk.finished && walk.commands.count == 18 && !walk.capped)
        var capped = CommandMenuTraversal()
        for index in 0..<CommandMenuTraversal.limit {
            capped.observe([ReaderCommand(name: "item-\(index)", description: "Command")])
        }
        check("commands probe: a capped traversal cannot hide unseen commands", capped.capped && !capped.finished)
        let model = ReaderCommand(name: "model", description: "Fallback", argumentHint: "[model]", peek: .withoutArguments)
        let stale = ReaderCommand(name: "cost", description: "Old command")
        let skill = ReaderCommand(name: "helper", description: "Skill", sigil: "$")
        let rows = CommandMenuScreen.rows("❯ /model    Choose model\n  /anthropic-skills:deep-research  Research\n  /imessage:access  Access rules\n❯ /\nRead /tmp/example now")
        let merged = CommandMenuScreen.reconcile([model, stale, skill], observed: rows, complete: true)
        check("commands probe: runtime rows include account namespaces and omit input", Set(rows.map(\.name)) == ["model", "anthropic-skills:deep-research", "imessage:access"])
        check("commands probe: runtime gates remove stale slash rows but keep dollar skills", !merged.contains { $0.name == "cost" } && merged.contains { $0.token == "$helper" })
        check("commands probe: live descriptions preserve picker rules and hints", merged.first { $0.name == "model" }?.description == "Choose model" && merged.first { $0.name == "model" }?.argumentHint == "[model]" && merged.first { $0.name == "model" }?.peek == .withoutArguments)
        check("commands probe: partial observations add without filtering", CommandMenuScreen.reconcile([stale], observed: rows, complete: false).contains { $0.name == "cost" })
        let claudeNames = Set(ReaderCommandCatalog.builtins(agent: "claude").map(\.name))
        check("commands: Claude fallback drops four unobserved legacy entries", claudeNames.isDisjoint(with: ["agents", "cost", "review", "vim"]))
        check("commands: Claude fallback includes recent native entries", Set(["focus", "statusline", "terminal-setup", "upgrade", "usage-credits", "voice"]).isSubset(of: claudeNames))
        check("commands keys: slash and model use their own key identities", GhosttyInput.commandKey("/").code == 44 && GhosttyInput.commandKey("m").code == 46 && GhosttyInput.commandKey("m").unshifted == 109)
        check("commands keys: namespace punctuation preserves shifted base keys", GhosttyInput.commandKey(":").code == 41 && GhosttyInput.commandKey(":").unshifted == 59 && GhosttyInput.commandKey(":").shift && GhosttyInput.commandKey("_").code == 27)

        check("commands probe: an empty first line does not erase a multiline draft", !CommandMenuScreen.emptyInput("❯ \n  unfinished second line\n────────\n? for shortcuts", agent: "claude") && !CommandMenuScreen.emptyInput("› \n  unfinished second line\nGPT-6 low", agent: "codex"))
        for suggestion in ["fix lint errors", "fix typecheck errors", "how does <filepath> work?", "refactor src/main.swift",
                           "how do I log an error?", "edit src/main.swift to...", "write a test for src/main.swift", "create a util logging.py that..."] {
            let placeholder = "❯ Try \"\(suggestion)\"\n────────\n? for shortcuts"
            check("commands probe: Claude first-prompt suggestion is empty input", CommandMenuScreen.emptyInput(placeholder, agent: "claude"))
        }
        check("commands probe: arbitrary Try text and queue hints remain drafts",
              !CommandMenuScreen.emptyInput("❯ Try \"delete everything\"", agent: "claude") &&
              !CommandMenuScreen.emptyInput("❯ Press up to edit queued messages", agent: "claude"))
        let aliases = CommandMenuScreen.reconcile(ReaderCommandCatalog.builtins(agent: "codex"), observed: [
            ReaderCommand(name: "side", description: "Side chat"), ReaderCommand(name: "exit", description: "Exit")
        ], complete: true)
        let unfiltered = ReaderCommandLogic.ranked(aliases, query: .init(range: NSRange(location: 0, length: 1), sigil: "/", text: ""))
        let filtered = ReaderCommandLogic.ranked(aliases, query: .init(range: NSRange(location: 0, length: 3), sigil: "/", text: "bt"))
        check("commands: Codex aliases appear only while searching", !unfiltered.contains { $0.name == "btw" || $0.name == "quit" } && filtered.contains { $0.name == "btw" })
        check("commands: Codex popup omits commands it always hides", !ReaderCommandCatalog.builtins(agent: "codex").contains { $0.name == "apps" || $0.name == "debug-config" })

        for agent in ["claude", "codex"] {
            let marker = agent == "claude" ? "❯" : "›"
            let empty = marker + " \n? for shortcuts"
            check("commands probe: \(agent) recognizes only its input row", CommandMenuScreen.emptyInput(empty, agent: agent) && CommandMenuScreen.input(marker + " /\n/model  Choose model", agent: agent) == "/" && !CommandMenuScreen.emptyInput(marker + " unfinished draft", agent: agent))
            var screen = empty
            var keys: [String] = []
            var allowed = false
            let probe = CommandMenuProbe(agent: agent, io: .init(screen: { screen }, allowed: { allowed },
                slash: { keys.append("/") }, down: { keys.append("Down") }, escape: { keys.append("Esc") },
                backspace: { keys.append("Backspace") })) { _, _ in }
            check("commands probe: \(agent) refuses a visible or busy terminal lease", !probe.start() && keys.isEmpty)
            allowed = true
            let cancelled = CommandMenuProbe(agent: agent, io: .init(screen: { screen }, allowed: { allowed },
                slash: { keys.append("/") }, down: { keys.append("Down") }, escape: { keys.append("Esc") },
                backspace: { keys.append("Backspace") })) { _, _ in }
            let started = cancelled.start()
            cancelled.cancel()
            check("commands probe: \(agent) cancellation before redraw clears its own queued slash", started && keys == ["/", "Esc", "Backspace"])
            keys.removeAll()
            screen = marker + " draft"
            let draftProbe = CommandMenuProbe(agent: agent, io: .init(screen: { screen }, allowed: { true },
                slash: { keys.append("/") }, down: { keys.append("Down") }, escape: { keys.append("Esc") },
                backspace: { keys.append("Backspace") })) { _, _ in }
            check("commands probe: \(agent) leaves existing terminal drafts untouched", !draftProbe.start() && keys.isEmpty)
        }
        // A simulated CLI has eight visible rows and keeps the text unchanged while
        // selection moves inside that window. No real agent or home folder is involved.
        var position = 0
        var draft = ""
        let available = (0..<20).map { "command-\($0)" }
        var completed: [ReaderCommand]?
        var complete = false
        var cleanups = 0
        let simulated = CommandMenuProbe(agent: "codex", io: .init(screen: {
            let start = min(max(0, position - 7), available.count - 8)
            let rows = draft == "/" ? available[start..<(start + 8)].map { "/\($0)  Description" }.joined(separator: "\n") : ""
            return rows + "\n› " + draft + "\n? for shortcuts"
        }, allowed: { true }, slash: { draft = "/" }, down: { position = (position + 1) % available.count },
            escape: { cleanups += 1 }, backspace: { draft = "" })) { rows, full in
                completed = rows
                complete = full
            }
        let running = simulated.start()
        let finished = waitUntil(8) { completed != nil }
        check("commands probe: an asynchronous full scan restores the input before publishing", running && finished && complete && draft.isEmpty && cleanups == 1 && Set(completed?.map(\.name) ?? []) == Set(available))
        check("commands probe: trust, update, approval and active turns cannot be scanned", ["Do you trust this folder?", "Update available", "Would you like to run this command?", "esc to interrupt"].allSatisfy { !CommandMenuScreen.safe($0) })
    }

    private static func readerCommandDiscovery(_ root: URL) {
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        func write(_ relative: String, _ text: String) {
            let url = root.appendingPathComponent(relative)
            Paths.ensure(url.deletingLastPathComponent())
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        write("home/.claude/commands/team/check.md", "---\ndescription: Check team code\nargument-hint: '[path]'\n---\nInstructions")
        write("home/.claude/commands/review.md", "Personal review")
        write("project/.claude/commands/review.md", "Project review")
        write("home/.claude/skills/internal/SKILL.md", "---\nname: internal\ndescription: Private\nuser-invocable: false\n---\nBody")
        write("project/.claude/skills/folder/SKILL.md", "---\nname: named-skill\ndescription: Named differently\n---\nBody")
        write("home/.claude/settings.json", #"{"enabledPlugins":{"demo@market":true,"disabled@market":false}}"#)
        let pluginPath = root.appendingPathComponent("plugin").path
        let registry: [String: Any] = ["version": 2, "plugins": ["demo@market": [["scope": "user", "installPath": pluginPath]], "disabled@market": [["scope": "user", "installPath": pluginPath]]]]
        if let data = try? JSONSerialization.data(withJSONObject: registry), let s = String(data: data, encoding: .utf8) { write("home/.claude/plugins/installed_plugins.json", s) }
        write("plugin/commands/action.md", "Plugin action")
        write("plugin/skills/tool/SKILL.md", "---\nname: tool\ndescription: Plugin skill\n---\nBody")
        let context = ReaderCommandCatalog.Context(agent: "claude", folder: project.path, transcript: nil)
        let catalog = ReaderCommandCatalog.read(context, home: home, session: ReaderCommandCatalog.listing("- internal: Hidden\n- session-only: Available here"))
        check("commands: discovery uses fixture home and project precedence", catalog.first { $0.name == "review" }?.description == "Project review")
        check("commands: subfolders become namespaces and hints survive", catalog.first { $0.name == "team:check" }?.argumentHint == "[path]")
        check("commands: named skills, session skills and hidden skills", catalog.contains { $0.name == "named-skill" } && catalog.contains { $0.name == "session-only" } && !catalog.contains { $0.name == "internal" })
        check("commands: only enabled plugin commands and skills appear", catalog.contains { $0.name == "demo:action" } && catalog.contains { $0.name == "demo:tool" } && !catalog.contains { $0.name.hasPrefix("disabled:") })
        write("plugin/.claude-plugin/plugin.json", #"{"commands":["./extra/custom.md"],"skills":["./extra-skill"]}"#)
        write("plugin/extra/custom.md", "Manifest command")
        write("plugin/extra-skill/SKILL.md", "---\nname: extra\ndescription: Extra skill\n---\nBody")
        let manifest = ReaderCommandCatalog.read(context, home: home)
        check("commands: plugin manifests replace commands and extend skills", manifest.contains { $0.name == "demo:custom" } && !manifest.contains { $0.name == "demo:action" } && manifest.contains { $0.name == "demo:tool" } && manifest.contains { $0.name == "demo:extra" })
        write("project/.claude/settings.local.json", #"{"enabledPlugins":{"demo@market":false}}"#)
        check("commands: project settings can disable a personal plugin", !ReaderCommandCatalog.read(context, home: home).contains { $0.name.hasPrefix("demo:") })
        write("home/.codex/prompts/fix.md", "---\ndescription: Fix errors\n---\nBody")
        write("home/.codex/prompts/nested/skip.md", "Not a top-level prompt")
        write("home/.codex/skills/.system/helper/SKILL.md", "---\nname: helper\ndescription: Help\n---\nBody")
        let codex = ReaderCommandCatalog.read(.init(agent: "codex", folder: project.path), home: home)
        check("commands: Codex prompts and bundled dollar skills", codex.contains { $0.token == "/prompts:fix" } && codex.contains { $0.token == "$helper" } && !codex.contains { $0.name == "prompts:nested:skip" })
        let transcript = root.appendingPathComponent("listing.jsonl")
        write("listing.jsonl", #"{"type":"attachment","attachment":{"type":"skill_listing","content":"- one: First"}}"# + "\n")
        let tail = SkillListingTail()
        check("commands: skill listing comes from a transcript fixture", tail.read(transcript).map(\.name) == ["one"])
        if let handle = try? FileHandle(forWritingTo: transcript) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(#"{"type":"attachment","attachment":{"type":"skill_listing","content":"- two: Second"}}"#.utf8))
            try? handle.close()
        }
        check("commands: incomplete transcript records wait for newline", tail.read(transcript).map(\.name) == ["one"])
        if let handle = try? FileHandle(forWritingTo: transcript) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data("\n".utf8)); try? handle.close()
        }
        check("commands: listing tail appends without losing earlier skills", tail.read(transcript).map(\.name) == ["one", "two"])
        write("listing.jsonl", #"{"type":"attachment","attachment":{"type":"skill_listing","content":"- reset: New"}}"# + "\n")
        check("commands: replacement transcripts reset the listing", tail.read(transcript).map(\.name) == ["reset"])
        let loader = ReaderCommandCatalog(home: home)
        var delivered = false
        var onMain = false
        loader.load(context) { _ in delivered = true; onMain = Thread.isMainThread }
        check("commands: catalogue returns asynchronously on main", waitUntil(3) { delivered } && onMain)
        write("other/.claude/commands/review.md", "Other project review")
        var otherCommands: [ReaderCommand]?
        var codexCommands: [ReaderCommand]?
        loader.load(.init(agent: "claude", folder: root.appendingPathComponent("other").path, transcript: nil)) { otherCommands = $0 }
        loader.load(.init(agent: "codex", folder: project.path, transcript: nil)) { codexCommands = $0 }
        check("commands: cached catalogues stay separate by agent and folder", waitUntil(3) { otherCommands != nil && codexCommands != nil } && otherCommands?.first { $0.name == "review" }?.description == "Other project review" && codexCommands?.contains { $0.token == "$helper" } == true && codexCommands?.contains { $0.name == "team:check" } == false)
    }

    private static func readerCommandKeys() {
        let window = makeWindow()
        let text = ComposerTextView.make()
        text.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
        let menu = CommandMenu(frame: NSRect(x: 0, y: 70, width: 400, height: 252))
        window.contentView?.addSubview(text)
        window.contentView?.addSubview(menu)
        defer { text.removeFromSuperview(); menu.removeFromSuperview() }
        text.commandCatalog = ReaderCommandCatalog.builtins(agent: "claude")
        text.onCommandMenuChange = { menu.show(text.commandSuggestions, selection: text.commandSelection) }
        var stopped = 0, sent = 0
        text.onEscape = { stopped += 1; return true }
        text.onSend = { sent += 1 }
        window.makeFirstResponder(text)
        text.insertTyped("/co")
        check("commands UI: typing /co shows compact above a real text view", text.commandMenuVisible && !menu.isHidden && text.commandSuggestions.contains { $0.token == "/compact" })
        if let event = keyEvent(53, "\u{1b}", window: window) { text.keyDown(with: event) }
        check("commands UI: Esc closes the list without stopping", !text.commandMenuVisible && menu.isHidden && stopped == 0)
        text.commandCatalog = ReaderCommandCatalog.builtins(agent: "claude")
        check("commands UI: a catalogue refresh respects dismissed text", !text.commandMenuVisible)
        text.insertTyped("m")
        check("commands UI: editing reopens the list", text.commandMenuVisible)
        if let event = keyEvent(48, "\t", window: window) { text.keyDown(with: event) }
        check("commands UI: Tab completes with a space", text.string == "/compact " && !text.commandMenuVisible && sent == 0)
        text.text = "/comp"
        text.setSelectedRange(NSRange(location: 5, length: 0))
        if let event = keyEvent(36, "\r", window: window) { text.keyDown(with: event) }
        check("commands UI: partial Return completes rather than sends", text.string == "/compact " && sent == 0)
        text.text = "/compact"
        text.setSelectedRange(NSRange(location: 8, length: 0))
        if let event = keyEvent(36, "\r", window: window) { text.keyDown(with: event) }
        check("commands UI: exact Return sends", sent == 1 && !text.commandMenuVisible)
        text.text = "/c"
        text.setSelectedRange(NSRange(location: 2, length: 0))
        if let event = keyEvent(125, "", window: window) { text.keyDown(with: event) }
        check("commands UI: Down moves the highlight", text.commandSelection == 1)
        if let event = keyEvent(126, "", window: window) { text.keyDown(with: event) }
        check("commands UI: Up moves the highlight back", text.commandSelection == 0)
        text.cancelOperation(nil)
        check("commands UI: responder Esc also takes precedence over Stop", !text.commandMenuVisible && stopped == 0)
        text.cancelOperation(nil)
        check("commands UI: ordinary Esc still reaches Stop", stopped == 1)
        text.onCommandMenuChange = nil
    }

    private static func readerCommandTranscripts() {
        var claude = ClaudeTranscriptParser()
        let lines = [
            #"{"type":"user","message":{"content":"<command-message>compact</command-message><command-name>/compact</command-name><command-args>focus</command-args>"}}"#,
            #"{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual"}}"#,
            #"{"type":"user","isCompactSummary":true,"isMeta":true,"message":{"content":"LONG PRIVATE SUMMARY"}}"#,
            #"{"type":"user","message":{"content":"<local-command-stdout>Set model to example-model</local-command-stdout>"}}"#,
            #"{"type":"user","message":{"content":"<command-name>/clear</command-name><command-args></command-args>"}}"#,
        ]
        let entries = lines.flatMap { claude.parse(line: Data($0.utf8)) }
        check("commands reader: Claude command, output and clear are notices", entries.count == 4 && entries.allSatisfy { $0.kind == .notice } && entries.contains { $0.text == "Ran /compact focus" } && entries.contains { $0.text == "Set model to example-model" } && entries.contains { $0.text == "Ran /clear" })
        check("commands reader: one Claude compaction notice hides the summary", entries.filter { $0.text == "Conversation compacted" }.count == 1 && !entries.contains { $0.text.contains("PRIVATE") })
        var codex = CodexTranscriptParser()
        let codexLines = [
            #"{"type":"turn_context","payload":{"model":"first"}}"#,
            #"{"type":"compacted","payload":{"message":"LONG PRIVATE SUMMARY","replacement_history":[{"role":"user","content":"PRIVATE"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"context_compacted"}}"#,
            #"{"type":"turn_context","payload":{"model":"second"}}"#,
        ]
        let result = codexLines.flatMap { codex.parse(line: Data($0.utf8)) }
        check("commands reader: Codex compaction hides replacement history", result.filter { $0.text == "Conversation compacted" }.count == 1 && !result.contains { $0.text.contains("PRIVATE") })
        check("commands reader: observed Codex model changes are notices", result.contains { $0.kind == .notice && $0.text == "Model changed to second" } && result.count == 2)
    }
}
