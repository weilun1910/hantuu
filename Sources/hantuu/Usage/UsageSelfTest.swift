import AppKit
import SwiftUI

/// Self test for the usage rings: parsing both agents' limits, picking windows and the newest
/// reading, the words in the tooltip, the colours, Claude's status line run for real through
/// /bin/sh, the engine end to end, and offscreen snapshots of the footer. Every fixture is
/// made up and lives in the throwaway workdir.
extension SelfTest {
    static func usage(_ dir: URL) {
        let work = dir.appendingPathComponent("usage", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        Paths.ensure(work)
        usageParsing()
        usageWords()
        usageCodexFiles(work)
        usageClaudeStatusLine(work)
        usageEngine(work)
        usageSnapshots(dir)
    }

    static func codexLine(_ ts: String, _ rateLimits: String, type: String = "token_count") -> String {
        #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"\#(type)","info":null,"rate_limits":\#(rateLimits)}}"#
    }

    static func codexLimits(_ primary: String?, _ secondary: String?, id: String = "codex") -> String {
        #"{"limit_id":"\#(id)","limit_name":null,"primary":\#(primary ?? "null"),"secondary":\#(secondary ?? "null"),"credits":null,"plan_type":"plus","rate_limit_reached_type":null}"#
    }

    static func win(_ used: Double, _ minutes: Int, _ resets: Int = 1_794_419_611) -> String {
        #"{"used_percent":\#(used),"window_minutes":\#(minutes),"resets_at":\#(resets)}"#
    }

    // MARK: Parsing

    static func usageParsing() {
        let ts = "2026-11-11T16:35:59.338Z"
        let weeklyOnly = CodexUsage.parse(line: Data(codexLine(ts, codexLimits(win(27, 10080), nil)).utf8))?.reading
        check("usage: Codex weekly-only limits", weeklyOnly?.weekly?.usedPercent == 27 && weeklyOnly?.fiveHour == nil
              && weeklyOnly?.windows.count == 1 && weeklyOnly?.ringWindow == weeklyOnly?.weekly && weeklyOnly?.plan == "plus"
              && weeklyOnly?.weekly?.resetsAt == Date(timeIntervalSince1970: 1_794_419_611)
              && weeklyOnly?.observedAt == CodexUsage.date(ts), "\(String(describing: weeklyOnly))")

        let both = CodexUsage.parse(line: Data(codexLine(ts, codexLimits(win(60, 300), win(12.5, 10080))).utf8))?.reading
        check("usage: Codex 5-hour and weekly limits", both?.fiveHour?.usedPercent == 60 && both?.weekly?.usedPercent == 12.5
              && both?.ringWindow?.minutes == 10080 && both?.otherWindows.map(\.minutes) == [300], "\(String(describing: both))")

        let swapped = CodexUsage.parse(line: Data(codexLine(ts, codexLimits(win(12.5, 10080), win(60, 300))).utf8))?.reading
        check("usage: windows are picked by length, not by primary or secondary",
              swapped?.weekly?.usedPercent == 12.5 && swapped?.fiveHour?.usedPercent == 60 && swapped?.ringWindow?.usedPercent == 12.5)

        let shortOnly = CodexUsage.parse(line: Data(codexLine(ts, codexLimits(win(30, 300), nil)).utf8))?.reading
        check("usage: with no weekly window the ring shows the longest one", shortOnly?.weekly == nil && shortOnly?.ringWindow?.minutes == 300)

        let none = [
            codexLine(ts, "null"),
            codexLine(ts, codexLimits(nil, nil)),
            #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{}}}}"#,
            codexLine(ts, codexLimits(win(27, 10080), nil), type: "agent_message"),
            #"{"timestamp":"\#(ts)","type":"response_item","payload":{"type":"message","content":"token_count rate_limits"}}"#,
            "not json token_count rate_limits",
        ]
        check("usage: no limits in a line means no reading", none.allSatisfy { CodexUsage.parse(line: Data($0.utf8)) == nil })

        let older = #"{"primary":{"used_percent":5,"window_minutes":300,"resets_in_seconds":600},"secondary":null}"#
        let o = CodexUsage.parse(line: Data(codexLine(ts, older).utf8))?.reading
        check("usage: an older Codex's resets_in_seconds counts from the event's time",
              o?.fiveHour?.resetsAt == CodexUsage.date(ts)?.addingTimeInterval(600))

        let at = Date(timeIntervalSince1970: 1_794_000_000)
        let rl: [String: Any] = ["five_hour": ["used_percentage": 41.5, "resets_at": 1_794_010_000],
                                 "seven_day": ["used_percentage": 18, "resets_at": 1_794_400_000]]
        let c = ClaudeUsage.reading(rateLimits: rl, observedAt: at)
        check("usage: Claude five_hour and seven_day", c?.fiveHour?.usedPercent == 41.5 && c?.weekly?.usedPercent == 18
              && c?.weekly?.minutes == 10080 && c?.fiveHour?.minutes == 300 && c?.observedAt == at
              && c?.weekly?.resetsAt == Date(timeIntervalSince1970: 1_794_400_000), "\(String(describing: c))")
        let c7 = ClaudeUsage.reading(rateLimits: ["five_hour": NSNull(), "seven_day": ["used_percentage": 3, "resets_at": 1_794_400_000]], observedAt: at)
        check("usage: Claude weekly only", c7?.windows.count == 1 && c7?.ringWindow?.isWeekly == true)
        check("usage: Claude without limits (an API key, a gateway spend limit only)",
              ClaudeUsage.reading(rateLimits: [String: Any](), observedAt: at) == nil
              && ClaudeUsage.reading(rateLimits: ["spend_limit": ["used_percentage": 50]], observedAt: at) == nil
              && ClaudeUsage.reading(rateLimits: nil, observedAt: at) == nil)
        let file = ClaudeUsage.parse(file: Data("{\"seven_day\":{\"used_percentage\":9,\"resets_at\":1}}\n/tmp/t.jsonl\n".utf8))
        check("usage: Claude's saved file holds the limits and the transcript path",
              file?.transcript == "/tmp/t.jsonl" && ClaudeUsage.reading(rateLimits: file?.rateLimits, observedAt: at)?.weekly?.usedPercent == 9)
    }

    // MARK: Words and colours

    static func usageWords() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let en = Locale(identifier: "en_US")
        // Wednesday 11 November 2026, noon.
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))!
        let sat = cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 9, minute: 13))!
        let thu = cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 13))!
        func reset(_ d: Date) -> String? { UsageFormat.reset(d, now: now, calendar: cal, locale: en) }
        check("usage: a weekly reset days away names the day", reset(sat) == "resets Sat 9:13 AM", "\(reset(sat) ?? "nil")")
        check("usage: a reset tomorrow says tomorrow", reset(thu) == "resets tomorrow 1:00 PM", "\(reset(thu) ?? "nil")")
        check("usage: a reset within a day counts down", reset(now.addingTimeInterval(7800)) == "resets in 2h 10m"
              && reset(now.addingTimeInterval(1500)) == "resets in 25m" && reset(now.addingTimeInterval(3600)) == "resets in 1h")
        check("usage: a reset that already happened", reset(now.addingTimeInterval(-1500)) == "reset 25m ago")

        check("usage: ages", UsageFormat.age(30) == "just now" && UsageFormat.age(300) == "5m ago"
              && UsageFormat.age(3 * 3600 + 200) == "3h ago" && UsageFormat.age(3 * 86400) == "3d ago")
        check("usage: percent left rounds down, so 100% means untouched",
              UsageFormat.percent(73) == "73%" && UsageFormat.percent(99.6) == "99%" && UsageFormat.percent(100) == "100%"
              && UsageFormat.percent(-20) == "0%")

        func tip(_ s: UsageSource, _ r: UsageReading?) -> String { UsageFormat.tooltip(s, r, now: now, calendar: cal, locale: en) }
        let fresh = UsageReading(windows: [UsageWindow(usedPercent: 27, minutes: 10080, resetsAt: sat)], observedAt: now.addingTimeInterval(-120))
        check("usage: tooltip for a fresh weekly reading", tip(.codex, fresh) == "Codex: 73% of weekly left, resets Sat 9:13 AM", tip(.codex, fresh))
        var two = fresh
        two.windows.append(UsageWindow(usedPercent: 60, minutes: 300, resetsAt: now.addingTimeInterval(7800)))
        check("usage: tooltip adds the 5-hour window", tip(.claude, two) == "Claude Code: 73% of weekly left, resets Sat 9:13 AM\n5-hour: 40% left, resets in 2h 10m", tip(.claude, two))
        var stale = two
        stale.observedAt = now.addingTimeInterval(-3 * 3600 - 60)
        check("usage: a stale reading says how old it is", tip(.claude, stale).hasSuffix("\nAs of 3h ago"), tip(.claude, stale))
        var justStale = fresh
        justStale.observedAt = now.addingTimeInterval(-UsageFormat.staleAfter + 30)
        check("usage: a recent reading doesn't", !tip(.codex, justStale).contains("As of"))
        let resetSince = UsageReading(windows: [UsageWindow(usedPercent: 91, minutes: 10080, resetsAt: now.addingTimeInterval(-7200))],
                                      observedAt: now.addingTimeInterval(-86400))
        check("usage: a window that reset since the reading starts over",
              resetSince.ringWindow?.leftPercent(at: now) == 100 && tip(.codex, resetSince) == "Codex: 100% of weekly left, reset 2h ago\nAs of 24h ago", tip(.codex, resetSince))
        check("usage: no reading says why", tip(.claude, nil).hasPrefix("Claude Code: No reading yet.") && tip(.codex, nil).hasPrefix("Codex: No reading yet."))
        let offTip = UsageFormat.tooltip(.claude, nil, now: now, off: true)
        check("usage: Claude turned off says how to turn it on", offTip.hasPrefix("Claude Code: Off.") && offTip.contains("Settings")
              && UsageFormat.tooltip(.claude, fresh, now: now, off: true, calendar: cal, locale: en).hasPrefix("Claude Code: 73% of weekly left"))
        let ring = UsageReading(windows: [UsageWindow(usedPercent: 10, minutes: 1440, resetsAt: nil)], observedAt: now)
        check("usage: other window lengths get a plain name", tip(.codex, ring) == "Codex: 90% of 1-day left")

        check("usage: colour thresholds",
              UsageLevel.of(leftPercent: 100) == .normal && UsageLevel.of(leftPercent: 15) == .normal
              && UsageLevel.of(leftPercent: 14.9) == .low && UsageLevel.of(leftPercent: 5) == .low
              && UsageLevel.of(leftPercent: 4.9) == .critical && UsageLevel.of(leftPercent: 0) == .critical
              && UsageLevel.of(leftPercent: nil) == .unknown)
        check("usage: rings only for agents hantuu can read", UsageSource(agentID: "claude") == .claude && UsageSource(agentID: "codex") == .codex
              && UsageSource(agentID: "gemini") == nil && UsageSource.claude.glyph != UsageSource.codex.glyph)
    }

    // MARK: Codex rollouts on disk

    static func usageCodexFiles(_ work: URL) {
        let fm = FileManager.default
        let sessions = work.appendingPathComponent("sessions", isDirectory: true)
        let now = Date()
        let cal = Calendar.current
        func folder(_ daysBack: Int) -> URL {
            let d = cal.date(byAdding: .day, value: -daysBack, to: now)!
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let u = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!), isDirectory: true)
            Paths.ensure(u)
            return u
        }
        func write(_ url: URL, _ lines: [String], modified: Date) {
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        let filler = #"{"timestamp":"2026-11-11T10:00:00.000Z","type":"response_item","payload":{"type":"message","content":[{"type":"output_text","text":"hello"}]}}"#

        // Today: two snapshots, the later one wins.
        let a = folder(0).appendingPathComponent("rollout-a.jsonl")
        write(a, [#"{"timestamp":"2026-11-11T09:00:00.000Z","type":"session_meta","payload":{"id":"a"}}"#,
                  codexLine("2026-11-11T09:01:00.000Z", codexLimits(win(20, 10080), nil)),
                  filler,
                  codexLine("2026-11-11T09:05:00.000Z", codexLimits(win(27, 10080), nil)),
                  filler], modified: now.addingTimeInterval(-600))
        check("usage: the last snapshot in a rollout wins", CodexUsage.latest(in: a)?.weekly?.usedPercent == 27)

        // Yesterday's folder, written to more recently, but with an older snapshot.
        let b = folder(1).appendingPathComponent("rollout-b.jsonl")
        write(b, [codexLine("2026-11-11T08:00:00.000Z", codexLimits(win(15, 10080), nil)), filler], modified: now.addingTimeInterval(-60))
        // A month-old folder, out of the scan, unless a chat is following it.
        let c = folder(40).appendingPathComponent("rollout-c.jsonl")
        write(c, [codexLine("2026-11-11T09:30:00.000Z", codexLimits(win(33, 10080), nil))], modified: now.addingTimeInterval(-30))

        let found = CodexUsage.candidates(sessions: sessions, extra: [], now: now).map(\.url.lastPathComponent)
        check("usage: recent date folders are scanned, newest write first", found == ["rollout-b.jsonl", "rollout-a.jsonl"], "\(found)")
        let withChat = CodexUsage.candidates(sessions: sessions, extra: [c.path], now: now).map(\.url.lastPathComponent)
        check("usage: a chat's own rollout in an older folder is included", withChat.first == "rollout-c.jsonl" && withChat.count == 3, "\(withChat)")
        let engine = UsageCenter()
        engine.codexSessions = sessions
        engine.claudeDir = work.appendingPathComponent("none", isDirectory: true)
        engine.refresh()
        _ = waitUntil(3) { engine.reading(for: .codex) != nil }
        check("usage: the newest snapshot across rollouts wins, not the newest file", engine.reading(for: .codex)?.weekly?.usedPercent == 27,
              "\(String(describing: engine.reading(for: .codex)))")

        // A long tool output after the last token_count: found in the larger tail.
        let big = work.appendingPathComponent("rollout-big.jsonl")
        let long = #"{"timestamp":"2026-11-11T10:00:00.000Z","type":"response_item","payload":{"type":"function_call_output","output":""# + String(repeating: "x", count: 600 << 10) + #""}}"#
        write(big, [codexLine("2026-11-11T09:59:00.000Z", codexLimits(win(44, 10080), nil)), long, filler], modified: now)
        check("usage: a snapshot behind 600 KB of tool output is still found", CodexUsage.latest(in: big)?.weekly?.usedPercent == 44)
        let none = work.appendingPathComponent("rollout-none.jsonl")
        write(none, [filler, codexLine("2026-11-11T09:59:00.000Z", "null")], modified: now)
        check("usage: a rollout without limits has no reading", CodexUsage.latest(in: none) == nil)

        // Codex's main limit wins over another one it reports later.
        let mixed = work.appendingPathComponent("rollout-mixed.jsonl")
        write(mixed, [codexLine("2026-11-11T09:00:00.000Z", codexLimits(win(27, 10080), nil)),
                      codexLine("2026-11-11T09:01:00.000Z", codexLimits(win(80, 10080), nil, id: "codex_other"))], modified: now)
        check("usage: the main codex limit wins over another limit id", CodexUsage.latest(in: mixed)?.weekly?.usedPercent == 27)
        let onlyOther = work.appendingPathComponent("rollout-other.jsonl")
        write(onlyOther, [codexLine("2026-11-11T09:01:00.000Z", codexLimits(win(80, 10080), nil, id: "codex_other"))], modified: now)
        check("usage: another limit id is used when it's the only one", CodexUsage.latest(in: onlyOther)?.weekly?.usedPercent == 80)
    }

    // MARK: Claude's status line, run for real

    static func usageClaudeStatusLine(_ work: URL) {
        let fm = FileManager.default
        func settingsKeys(_ json: String) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]) ?? [:] }
        let on = settingsKeys(AgentHooks.claudeSettingsJSON(statusLine: true))
        let sl = on["statusLine"] as? [String: Any]
        check("usage: when it's on, Claude's --settings adds the status line next to the hooks",
              on["hooks"] != nil && sl?["type"] as? String == "command" && sl?["command"] as? String == ClaudeUsage.statusLineCommand)
        check("usage: when it's off, there's no status line, so Claude keeps its footer hints",
              settingsKeys(AgentHooks.claudeSettingsJSON(statusLine: false)).keys.sorted() == ["hooks"])
        let lowered = AgentHooks.claudeSettingsJSON(statusLine: true).lowercased()
        check("usage: the status line decides nothing and adds no bypass", !["permissiondecision", "\"decision\"", "\"allow\"", "\"deny\"", "continue", "dangerously", "bypass", "never"].contains { lowered.contains($0) })

        // Off by default, saved in the data folder.
        let settingsFile = Paths.dataDir.appendingPathComponent("usage-settings.json")
        try? fm.removeItem(at: settingsFile)
        let fresh = UsageSettings()
        check("usage: Claude's status line is off by default", fresh.claudeStatusLine == false)
        fresh.claudeStatusLine = true
        check("usage: the setting is saved", UsageSettings().claudeStatusLine == true)
        fresh.claudeStatusLine = false
        check("usage: and turned off again", UsageSettings().claudeStatusLine == false)

        // On automatically for someone with a status line of their own (read, never written).
        let ownDir = work.appendingPathComponent("own", isDirectory: true)
        Paths.ensure(ownDir)
        let withLine = ownDir.appendingPathComponent("with.json"), without = ownDir.appendingPathComponent("without.json")
        try? #"{"model":"opus","statusLine":{"type":"command","command":"~/.claude/line.sh","padding":0}}"#.write(to: withLine, atomically: true, encoding: .utf8)
        try? #"{"model":"opus","hooks":{}}"#.write(to: without, atomically: true, encoding: .utf8)
        check("usage: a status line of the user's own is noticed", ClaudeUsage.hasOwnStatusLine(withLine)
              && !ClaudeUsage.hasOwnStatusLine(without) && !ClaudeUsage.hasOwnStatusLine(ownDir.appendingPathComponent("missing.json")))
        let env = AgentHooks.environment(for: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        check("usage: each chat gets its own HANTUU_USAGE file",
              env[ClaudeUsage.envKey]?.hasSuffix("/usage/claude-11111111-2222-3333-4444-555555555555.json") == true && env[AgentHooks.envKey] != nil)

        let project = work.appendingPathComponent("project", isDirectory: true)
        let config = work.appendingPathComponent("claude-config", isDirectory: true)
        Paths.ensure(project.appendingPathComponent(".claude", isDirectory: true))
        Paths.ensure(config)
        let out = work.appendingPathComponent("claude-usage", isDirectory: true)
        Paths.ensure(out)
        let file = out.appendingPathComponent("claude-test.json")
        let transcript = work.appendingPathComponent("t r.jsonl")
        try? "{}\n".write(to: transcript, atomically: true, encoding: .utf8)

        func input(limits: Bool) -> Data {
            var o: [String: Any] = ["session_id": "s", "transcript_path": transcript.path, "cwd": project.path,
                                    "model": ["id": "claude-x", "display_name": "Opus"],
                                    "workspace": ["current_dir": project.path, "project_dir": project.path],
                                    "context_window": ["current_usage": NSNull(), "used_percentage": NSNull()]]
            if limits {
                o["rate_limits"] = ["five_hour": ["used_percentage": 41.5, "resets_at": 1_794_010_000],
                                    "seven_day": ["used_percentage": 18, "resets_at": 1_794_400_000]]
            }
            return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
        }
        func settings(_ command: String) -> Data {
            (try? JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": command]])) ?? Data()
        }
        let baseEnv = ["HANTUU_USAGE": file.path, "CLAUDE_CONFIG_DIR": config.path]
        let script = ClaudeUsage.statusLineCommand

        let (code, printed) = sh(script, stdin: input(limits: true), env: baseEnv)
        let saved = (try? Data(contentsOf: file)).flatMap(ClaudeUsage.parse(file:))
        let r = ClaudeUsage.reading(rateLimits: saved?.rateLimits, observedAt: Date())
        check("usage: the status line saves Claude's limits and prints nothing of its own",
              code == 0 && printed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && saved?.transcript == transcript.path && r?.weekly?.usedPercent == 18 && r?.fiveHour?.usedPercent == 41.5,
              "code=\(code) printed=\(printed) saved=\(String(describing: saved))")
        let leftovers = ((try? fm.contentsOfDirectory(atPath: out.path)) ?? []).filter { $0 != "claude-test.json" }
        check("usage: the file is swapped in whole, with no temporary files left", leftovers.isEmpty, "\(leftovers)")

        // The user's own status line still runs, with the same JSON, and its output is shown.
        try? settings("printf 'user:'; /usr/bin/plutil -extract model.display_name raw -o - -").write(to: config.appendingPathComponent("settings.json"))
        let (_, user) = sh(script, stdin: input(limits: true), env: baseEnv)
        check("usage: the user's own status line runs and gets the same JSON", user.trimmingCharacters(in: .whitespacesAndNewlines) == "user:Opus", user)
        try? settings("printf project").write(to: project.appendingPathComponent(".claude/settings.json"))
        let (_, proj) = sh(script, stdin: input(limits: true), env: baseEnv)
        check("usage: a project's status line wins over the user's", proj == "project", proj)
        try? settings("printf local").write(to: project.appendingPathComponent(".claude/settings.local.json"))
        let (_, local) = sh(script, stdin: input(limits: true), env: baseEnv)
        check("usage: settings.local.json wins over the project's", local == "local", local)

        try? fm.removeItem(at: file)
        let (_, noLimits) = sh(script, stdin: input(limits: false), env: baseEnv)
        check("usage: without rate_limits nothing is saved and the user's line still shows", !fm.fileExists(atPath: file.path) && noLimits == "local")
        let (_, noEnv) = sh(script, stdin: input(limits: true), env: ["HANTUU_USAGE": "", "CLAUDE_CONFIG_DIR": config.path])
        check("usage: outside hantuu (no HANTUU_USAGE) it only runs the user's line", !fm.fileExists(atPath: file.path) && noEnv == "local")
        let (failCode, _) = sh(script, stdin: Data("not json".utf8), env: ["HANTUU_USAGE": file.path, "CLAUDE_CONFIG_DIR": work.appendingPathComponent("empty").path])
        check("usage: input it can't read is ignored quietly", failCode == 0 && !fm.fileExists(atPath: file.path))

        // The newest saved reading wins. A redraw rewrites the file without anything new from
        // the server, so the transcript's last write caps how new a reading is.
        let dir = work.appendingPathComponent("claude-latest", isDirectory: true)
        Paths.ensure(dir)
        let now = Date()
        let oldTranscript = work.appendingPathComponent("old.jsonl")
        try? "{}\n".write(to: oldTranscript, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: oldTranscript.path)
        let f1 = dir.appendingPathComponent("claude-1.json"), f2 = dir.appendingPathComponent("claude-2.json"), f3 = dir.appendingPathComponent("claude-3.json")
        try? "{\"seven_day\":{\"used_percentage\":50,\"resets_at\":1794400000}}\n\(oldTranscript.path)\n".write(to: f1, atomically: true, encoding: .utf8)
        try? "{\"seven_day\":{\"used_percentage\":22,\"resets_at\":1794400000}}\n\n".write(to: f2, atomically: true, encoding: .utf8)
        try? "{\"seven_day\":{\"used_percentage\":90,\"resets_at\":1794400000}}\n\n".write(to: f3, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: f1.path)
        try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: f2.path)
        try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-9 * 86400)], ofItemAtPath: f3.path)
        let best = ClaudeUsage.latest(in: dir, now: now, prune: true)
        check("usage: the newest Claude reading wins, judged by the transcript", best?.weekly?.usedPercent == 22
              && abs((best?.observedAt.timeIntervalSince(now) ?? 0) + 600) < 2, "\(String(describing: best))")
        check("usage: readings older than eight days are cleared", !fm.fileExists(atPath: f3.path) && fm.fileExists(atPath: f1.path))
    }

    // MARK: The engine

    static func usageEngine(_ work: URL) {
        let sessions = work.appendingPathComponent("engine-sessions", isDirectory: true)
        let claudeDir = work.appendingPathComponent("engine-claude", isDirectory: true)
        let old = work.appendingPathComponent("engine-old", isDirectory: true)
        Paths.ensure(sessions)
        Paths.ensure(claudeDir)
        Paths.ensure(old)
        // A Codex chat following a rollout outside the date folders, as after `codex resume`.
        let rollout = old.appendingPathComponent("rollout-resumed.jsonl")
        try? (codexLine("2026-11-11T09:00:00.000Z", codexLimits(win(60, 300), win(27, 10080))) + "\n").write(to: rollout, atomically: true, encoding: .utf8)
        try? "{\"seven_day\":{\"used_percentage\":18,\"resets_at\":1794400000}}\n\n".write(to: claudeDir.appendingPathComponent("claude-x.json"), atomically: true, encoding: .utf8)

        let model = AppModel()
        let p = Project(path: work.path)
        model.projects = [p]
        let chat = Chat(projectID: p.id, agentID: "codex")
        chat.transcriptPath = rollout.path
        let engine = UsageCenter()
        engine.codexSessions = sessions
        engine.claudeDir = claudeDir
        engine.start(model: model)
        model.chats = [chat]
        engine.refresh()
        let both = waitUntil(3) { engine.reading(for: .codex) != nil && engine.reading(for: .claude) != nil }
        check("usage: the engine reads both agents", both && engine.reading(for: .codex)?.weekly?.usedPercent == 27
              && engine.reading(for: .codex)?.fiveHour?.usedPercent == 60 && engine.reading(for: .claude)?.weekly?.usedPercent == 18)

        // A turn ends: the new snapshot shows long before the 20 second poll.
        let h = try? FileHandle(forWritingTo: rollout)
        _ = try? h?.seekToEnd()
        h?.write(Data((codexLine("2026-11-11T09:10:00.000Z", codexLimits(win(70, 300), win(31, 10080))) + "\n").utf8))
        try? h?.close()
        chat.activity = .working
        chat.activity = .doneUnseen
        let picked = waitUntil(4) { engine.reading(for: .codex)?.weekly?.usedPercent == 31 }
        check("usage: a turn ending refreshes the rings", picked, "\(String(describing: engine.reading(for: .codex)))")

        // A reading that disappears from disk is still the last one known.
        try? FileManager.default.removeItem(at: claudeDir.appendingPathComponent("claude-x.json"))
        engine.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        check("usage: the last reading stays when its file goes", engine.reading(for: .claude)?.weekly?.usedPercent == 18)
        engine.stop()
    }

    // MARK: Snapshots

    static func usageSnapshots(_ dir: URL) {
        let out = dir.deletingLastPathComponent().appendingPathComponent("snapshots", isDirectory: true)
        Paths.ensure(out)
        Theme.configure(from: GhosttyApp.shared)
        let model = AppModel()
        model.agents = [AgentCatalog.definition("claude"), AgentCatalog.definition("codex")]
        let hantuu = Project(path: "/Users/test/hantuu")
        model.projects = [hantuu]
        let c1 = Chat(projectID: hantuu.id, agentID: "claude")
        c1.terminalTitle = "Usage rings in the footer"
        c1.activity = .working
        c1.activityDetail = "Running Bash: swift build"
        let c2 = Chat(projectID: hantuu.id, agentID: "codex")
        c2.terminalTitle = "Rename the screenshots"
        c2.activity = .idle
        model.chats = [c1, c2]
        model.selectedChatID = c1.id

        let now = Date()
        func reading(weeklyUsed: Double, fiveHourUsed: Double? = nil, age: TimeInterval = 60) -> UsageReading {
            var w = [UsageWindow(usedPercent: weeklyUsed, minutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400 + 4000))]
            if let f = fiveHourUsed { w.append(UsageWindow(usedPercent: f, minutes: 300, resetsAt: now.addingTimeInterval(7800))) }
            return UsageReading(windows: w, observedAt: now.addingTimeInterval(-age))
        }
        let healthy: [UsageSource: UsageReading] = [.claude: reading(weeklyUsed: 18, fiveHourUsed: 60), .codex: reading(weeklyUsed: 27)]
        let low: [UsageSource: UsageReading] = [.claude: reading(weeklyUsed: 88, fiveHourUsed: 95), .codex: reading(weeklyUsed: 97.5, age: 4 * 3600)]
        let unknown: [UsageSource: UsageReading] = [.codex: reading(weeklyUsed: 27)]
        let center = UsageCenter.shared

        let w = makeWindow()
        func render<V: View>(_ view: V, size: NSSize, name: String, dark: Bool, scale: CGFloat = 1) -> Bool {
            let content = AnyView(view.environmentObject(model).environment(\.colorScheme, dark ? .dark : .light))
            let root: AnyView = scale == 1 ? content
                : AnyView(content.frame(width: size.width / scale, height: size.height / scale).scaleEffect(scale, anchor: .topLeading)
                    .frame(width: size.width, height: size.height, alignment: .topLeading))
            let host = NSHostingView(rootView: root)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: size)
            w.contentView?.addSubview(host)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            defer { host.removeFromSuperview() }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return false }
            return (try? png.write(to: out.appendingPathComponent(name))) != nil
        }
        func footer() -> some View { SidebarFooter().background(Color.hChrome) }
        let footerSize = NSSize(width: 260, height: 38), narrow = NSSize(width: 200, height: 38)

        var ok = true
        center.preview(healthy, now: now)
        ok = render(footer(), size: footerSize, name: "usage-footer-dark.png", dark: true) && ok
        ok = render(footer(), size: footerSize, name: "usage-footer-light.png", dark: false) && ok
        ok = render(footer(), size: narrow, name: "usage-footer-narrow-dark.png", dark: true) && ok
        ok = render(footer(), size: narrow, name: "usage-footer-narrow-light.png", dark: false) && ok
        ok = render(SidebarView(), size: NSSize(width: 200, height: 300), name: "usage-sidebar-narrow-dark.png", dark: true) && ok
        ok = render(SidebarView(), size: NSSize(width: 200, height: 300), name: "usage-sidebar-narrow-light.png", dark: false) && ok
        center.preview(low, now: now)
        ok = render(footer(), size: footerSize, name: "usage-footer-low-dark.png", dark: true) && ok
        ok = render(footer(), size: footerSize, name: "usage-footer-low-light.png", dark: false) && ok
        center.preview(unknown, now: now)
        ok = render(footer(), size: footerSize, name: "usage-footer-unknown-dark.png", dark: true) && ok
        ok = render(footer(), size: footerSize, name: "usage-footer-unknown-light.png", dark: false) && ok

        // Up close, every level side by side.
        let levels: [(String, Double?)] = [("Cl", 100), ("Co", 73), ("Cl", 40), ("Co", 12), ("Cl", 3), ("Co", nil)]
        func strip() -> some View {
            HStack(spacing: 8) {
                ForEach(levels.indices, id: \.self) { i in UsageRing(glyph: levels[i].0, left: levels[i].1, tooltip: "") }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.hChrome)
        }
        ok = render(strip(), size: NSSize(width: 640, height: 112), name: "usage-rings-zoom-dark.png", dark: true, scale: 4) && ok
        ok = render(strip(), size: NSSize(width: 640, height: 112), name: "usage-rings-zoom-light.png", dark: false, scale: 4) && ok
        let settingsForm = Form { UsageSettingsSection() }.formStyle(.grouped)
        ok = render(settingsForm, size: NSSize(width: 520, height: 170), name: "usage-settings-dark.png", dark: true) && ok
        ok = render(settingsForm, size: NSSize(width: 520, height: 170), name: "usage-settings-light.png", dark: false) && ok
        check("snapshot: usage footer (light and dark, healthy, low, unknown, narrow) written to \(out.path)", ok)

        // The footer fits the sidebar's 200 pt minimum. Content that doesn't fit is centred and
        // spills past both edges, so compare where the drawing starts and ends with a wide
        // footer: the gear keeps its distance from the right edge and the rings stay inside
        // the footer's own 8 pt padding.
        center.preview(healthy, now: now)
        func inkBounds(width: CGFloat, dark: Bool) -> (left: CGFloat, right: CGFloat)? {
            let host = NSHostingView(rootView: AnyView(footer().environmentObject(model).environment(\.colorScheme, dark ? .dark : .light)))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 38)
            w.contentView?.addSubview(host)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            defer { host.removeFromSuperview() }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let bg = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else { return nil }
            var minX = Int.max, maxX = -1
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent) + abs(c.blueComponent - bg.blueComponent) > 0.06 {
                        minX = min(minX, x); maxX = max(maxX, x)
                    }
                }
            }
            guard maxX >= 0 else { return nil }
            let s = CGFloat(rep.pixelsWide) / width
            return (CGFloat(minX) / s, width - CGFloat(maxX + 1) / s)
        }
        var fits = true
        var detail = ""
        for dark in [true, false] {
            guard let wide = inkBounds(width: 320, dark: dark), let tight = inkBounds(width: 200, dark: dark) else { fits = false; continue }
            detail += "\(dark ? "dark" : "light"): wide \(wide), at 200 \(tight). "
            fits = fits && tight.left >= 8 && abs(tight.right - wide.right) < 0.75
        }
        check("usage: the footer with two rings fits a 200 pt sidebar", fits, detail)
        print("      \(detail)")

        // The tooltips, for reading next to the snapshots.
        var tips: [String] = []
        for (label, set) in [("healthy", healthy), ("low", low), ("unknown", unknown)] {
            for s in UsageSource.allCases { tips.append("[\(label)] " + UsageFormat.tooltip(s, set[s], now: now)) }
        }
        tips.append("[claude off] " + UsageFormat.tooltip(.claude, nil, now: now, off: true))
        try? tips.joined(separator: "\n\n").write(to: out.appendingPathComponent("usage-tooltips.txt"), atomically: true, encoding: .utf8)
        center.preview([:], now: Date())
    }
}
