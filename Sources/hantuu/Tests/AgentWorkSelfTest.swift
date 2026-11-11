import AppKit
import SwiftUI

/// Self test for subagents and background tasks: reading them from Claude Code transcripts
/// (and the subagents folder next to them) and from Codex rollouts, the rules that decide
/// what still counts as running, the sidebar status they hold up, and snapshots of the
/// Overview cards. Every fixture is synthetic and lives in the throwaway workdir.
extension SelfTest {
    static func agentWork(_ dir: URL) {
        let base = dir.appendingPathComponent("agent-work", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        Paths.ensure(base)
        let fx = WorkFixture.make(base, now: Date())
        agentWorkClaudeParsing(fx)
        agentWorkCodexParsing()
        agentWorkTracker(fx)
        agentWorkCodexTracker(base)
        agentWorkRules(fx)
        agentWorkWatch(fx)
        agentWorkReducer()
        agentWorkEngine(fx)
        agentWorkSnapshots(dir, fx)
        if let probe = ProcessInfo.processInfo.environment["HANTUU_WORK_PROBE"], !probe.isEmpty {
            for p in probe.split(separator: ":") { agentWorkProbe(URL(fileURLWithPath: String(p))) }
        }
    }

    /// HANTUU_WORK_PROBE=<transcripts or rollouts, colon separated>: prints what the Overview and the sidebar would
    /// show for a real session. Only reads; checks nothing.
    static func agentWorkProbe(_ url: URL) {
        let kind: TranscriptKind = url.lastPathComponent.hasPrefix("rollout-") ? .codex : .claude
        let started = Date()
        let quick = WorkFollower(url: url, kind: kind).poll()
        let quickTime = Date().timeIntervalSince(started)
        let t2 = Date()
        let base = InsightsFollower(url: url, kind: kind).poll().work
        let fullTime = Date().timeIntervalSince(t2)
        let start = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
        let work = AgentWorkTracker().update(base, transcript: url, kind: kind, processStart: start)
        print(String(format: "probe: %@ quick %.2fs, full %.2fs, agree: %@", url.lastPathComponent, quickTime, fullTime, quick == base ? "yes" : "no"))
        for a in work.subagents {
            print("probe agent: [\(a.state.rawValue)] \(a.parentID == nil ? "" : "  ")\(a.title) | \(WorkText.meta(type: a.type, model: a.model) ?? "-") | step: \(a.step ?? "-") | report: \(WorkText.firstLine(a.result) ?? "-")")
        }
        for t in work.tasks {
            print("probe task: [\(t.state.rawValue)] \(t.kind.rawValue) \(t.title) | exit \(t.exitCode.map(String.init) ?? "-") | output \(t.outputFile.map { FileManager.default.fileExists(atPath: $0) ? "exists" : "gone" } ?? "-") | event \(t.lastEvent ?? "-")")
        }
        var settled = quick
        BackgroundRules.settle(&settled, transcript: url, processStart: start)
        print("probe sidebar: \(BackgroundSummary.of(settled).detail)")
    }

    // MARK: Fixture

    /// A Claude Code session that started five agents, three background commands and a
    /// monitor, with a subagents folder like the one Claude Code writes next to it.
    struct WorkFixture {
        let transcript: URL
        let subagents: URL
        let tasks: URL
        let now: Date
        let processStart: Date

        static let a1 = "toolu_A1", a2 = "toolu_A2", a3 = "toolu_A3", a4 = "toolu_A4", a5 = "toolu_A5"

        static func line(_ o: [String: Any]) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }

        static let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        static func write(_ url: URL, _ lines: [String]) {
            Paths.ensure(url.deletingLastPathComponent())
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }

        static func append(_ url: URL, _ lines: [String]) {
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            h.seekToEndOfFile()
            h.write(Data(lines.map { $0 + "\n" }.joined().utf8))
            try? h.close()
        }

        static func setModified(_ url: URL, _ date: Date) {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }

        func t(_ secondsAgo: TimeInterval) -> String { Self.iso.string(from: now.addingTimeInterval(-secondsAgo)) }

        func use(_ id: String, _ name: String, _ input: [String: Any], at ago: TimeInterval) -> String {
            Self.line(["type": "assistant", "isSidechain": false, "timestamp": t(ago),
                       "message": ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
        }

        func result(_ id: String, _ content: Any, _ tur: [String: Any]?, at ago: TimeInterval, error: Bool = false) -> String {
            var item: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": content]
            if error { item["is_error"] = true }
            var o: [String: Any] = ["type": "user", "isSidechain": false, "timestamp": t(ago), "message": ["role": "user", "content": [item]]]
            if let tur { o["toolUseResult"] = tur }
            return Self.line(o)
        }

        func launched(_ id: String, agent: String, at ago: TimeInterval) -> String {
            result(id, [["type": "text", "text": "Async agent launched successfully.\nagentId: \(agent) (internal ID - do not mention to user.)"]],
                   ["isAsync": true, "status": "async_launched", "agentId": agent, "resolvedModel": "claude-opus-5-5"], at: ago)
        }

        func background(_ id: String, task: String, at ago: TimeInterval) -> String {
            let out = tasks.appendingPathComponent("\(task).output").path
            return result(id, "Command running in background with ID: \(task). Output is being written to: \(out). You will be notified when it completes.",
                          ["stdout": "", "stderr": "", "interrupted": false, "backgroundTaskId": task], at: ago)
        }

        static func note(_ task: String, toolUse: String?, status: String?, summary: String, result: String? = nil,
                         event: String? = nil, durationMs: Int? = nil, output: String? = nil) -> String {
            var s = "<task-notification>\n<task-id>\(task)</task-id>\n"
            if let toolUse { s += "<tool-use-id>\(toolUse)</tool-use-id>\n" }
            if let output { s += "<output-file>\(output)</output-file>\n" }
            if let status { s += "<status>\(status)</status>\n" }
            s += "<summary>\(summary)</summary>\n"
            if let event { s += "<event>\(event)</event>\n" }
            if let result { s += "<result>\(result)</result>\n" }
            if let durationMs { s += "<usage><subagent_tokens>1200</subagent_tokens><tool_uses>9</tool_uses><duration_ms>\(durationMs)</duration_ms></usage>\n" }
            return s + "</task-notification>"
        }

        func queued(_ text: String, at ago: TimeInterval) -> String {
            Self.line(["type": "queue-operation", "operation": "enqueue", "timestamp": t(ago), "content": text])
        }

        func attachment(_ text: String, at ago: TimeInterval) -> String {
            Self.line(["type": "attachment", "isSidechain": false, "timestamp": t(ago),
                       "attachment": ["type": "queued_command", "prompt": text, "commandMode": "task-notification"]])
        }

        static func make(_ base: URL, now: Date) -> WorkFixture {
            let transcript = base.appendingPathComponent("1f2e3d4c-0000-4000-8000-00000000c1a0.jsonl")
            let folder = transcript.deletingPathExtension()
            let fx = WorkFixture(transcript: transcript, subagents: folder.appendingPathComponent("subagents"),
                                 tasks: base.appendingPathComponent("tasks"), now: now, processStart: now.addingTimeInterval(-3600))
            let handback = "This agent's report was delivered to you as a message from \"aaa333\" (its SubagentHandback call). Read it there; it is not repeated here.\n"
            var lines: [String] = [
                line(["type": "user", "isSidechain": false, "timestamp": fx.t(3000), "message": ["role": "user", "content": "Fix the reader and the sidebar"]]),
                fx.use(a1, "Agent", ["description": "Research agent terminal security", "subagent_type": "general-purpose", "model": "opus",
                                     "run_in_background": "true", "prompt": "Find out how cmux and other agent terminals keep transcripts private.\n\nReport what each one does."], at: 2900),
                fx.launched(a1, agent: "aaa111", at: 2899),
                fx.use(a2, "Agent", ["description": "Build subagents and tasks in Overview", "model": "opus", "run_in_background": true,
                                     "prompt": "Show the chat's subagents and background tasks in the Overview tab, live."], at: 1500),
                fx.launched(a2, agent: "aaa222", at: 1499),
                fx.use(a3, "Agent", ["description": "Fix pasting media in reader composer", "subagent_type": "general-purpose", "model": "sonnet",
                                     "run_in_background": true, "prompt": "Pasting an image into the reader's message box does nothing. Make it attach the image."], at: 1400),
                fx.launched(a3, agent: "aaa333", at: 1399),
                fx.use(a4, "Agent", ["description": "Check the README links", "subagent_type": "web-fetch", "model": "haiku",
                                     "prompt": "Fetch each link in README.md and say which ones fail."], at: 1300),
                fx.result(a4, [["type": "text", "text": "  " + handback], ["type": "text", "text": "[Harness note, not part of the agent's report: nothing saved.]"]],
                          ["status": "completed", "agentId": "aaa444", "agentType": "web-fetch", "resolvedModel": "claude-haiku-5-5", "totalDurationMs": 26000,
                           "handbackReport": ["text": "All **12 links** resolve.\n\n- `docs/screenshots/reader-mode.jpg`\n- `LICENSE`"]], at: 1270),
                fx.use(a5, "Agent", ["description": "Draft release notes", "model": "opus", "run_in_background": true, "prompt": "Draft notes for v2.1."], at: 1200),
                fx.launched(a5, agent: "aaa555", at: 1199),
                fx.use("toolu_B1", "Bash", ["command": "./scripts/selftest.sh", "description": "Build and run the hantuu self test", "run_in_background": true], at: 600),
                fx.background("toolu_B1", task: "bb1", at: 599),
                fx.use("toolu_B2", "Bash", ["command": "npm run dev", "run_in_background": true], at: 2700),
                fx.background("toolu_B2", task: "bb2", at: 2699),
                fx.use("toolu_B3", "Bash", ["command": "swift test --filter ReaderTests", "description": "Run the reader tests", "run_in_background": true], at: 1000),
                fx.background("toolu_B3", task: "bb3", at: 999),
                fx.use("toolu_M1", "Monitor", ["description": "Watch the build log for errors", "command": "tail -f build.log | grep --line-buffered error", "timeout_ms": 900000], at: 500),
                fx.result("toolu_M1", "Monitor started (task mm1, expires in 15m unless the source ends first). You will be notified on each event.",
                          ["taskId": "mm1", "timeoutMs": 900000, "persistent": false], at: 499),
                fx.use("toolu_G", "Bash", ["command": "git status", "description": "Show working tree status"], at: 400),
                fx.result("toolu_G", "On branch main\nnothing to commit", ["stdout": "On branch main", "stderr": "", "interrupted": false], at: 399),
            ]
            let a3done = note("aaa333", toolUse: a3, status: "completed", summary: "Agent \"Fix pasting media in reader composer\" finished", result: handback, durationMs: 600_000)
            lines += [
                fx.queued(a3done, at: 800),
                fx.attachment(a3done, at: 800),
                fx.queued(note("aaa555", toolUse: a5, status: "failed", summary: "Agent \"Draft release notes\" failed", result: "API Error: 529 Overloaded"), at: 700),
                line(["type": "user", "isSidechain": false, "timestamp": fx.t(300), "message": ["role": "user", "content":
                    note("bb3", toolUse: "toolu_B3", status: "failed", summary: "Background command \"Run the reader tests\" failed with exit code 1",
                         output: fx.tasks.appendingPathComponent("bb3.output").path)]]),
                fx.queued(note("aaa111", toolUse: a1, status: "completed", summary: "Agent \"Research agent terminal security\" is waiting on its own background work"), at: 200),
                fx.queued(note("mm1", toolUse: nil, status: nil, summary: "Monitor event: \"Watch the build log for errors\"", event: "error: expected '}' in Parser.swift"), at: 100),
                // A subagent's own background command: the session-wide queue carries its notification too.
                fx.queued(note("bsub9", toolUse: "toolu_SUB", status: "completed", summary: "Background command \"Build in the subagent\" completed (exit code 0)"), at: 90),
                // Delivered to this chat's agent, from before a resume: shown, though its start isn't in this transcript.
                fx.attachment(note("aold1", toolUse: "toolu_OLD", status: "stopped", summary: "Background agent \"Map the old code\" didn't finish before the previous session ended"), at: 2990),
                // Claude Code keeps request copies with every result in them again. They're not news.
                line(["type": "api-request-blob", "message": ["role": "user", "content":
                    note("bb1", toolUse: "toolu_B1", status: "completed", summary: "Background command \"Build and run the hantuu self test\" completed (exit code 0)")]]),
            ]
            write(transcript, lines)

            // The subagents folder.
            func meta(_ id: String, _ o: [String: Any]) {
                let url = fx.subagents.appendingPathComponent("agent-\(id).meta.json")
                Paths.ensure(fx.subagents)
                try? JSONSerialization.data(withJSONObject: o).write(to: url)
            }
            func sub(_ id: String, _ lines: [[String: Any]]) {
                write(fx.subagents.appendingPathComponent("agent-\(id).jsonl"), lines.map { o in
                    var o = o
                    o["isSidechain"] = true
                    o["agentId"] = id
                    o["cwd"] = "/Users/test/hantuu"
                    return line(o)
                })
            }
            func prompt(_ text: String, _ ago: TimeInterval) -> [String: Any] {
                ["parentUuid": NSNull(), "type": "user", "timestamp": fx.t(ago), "message": ["role": "user", "content": text]]
            }
            func tool(_ name: String, _ input: [String: Any], _ ago: TimeInterval) -> [String: Any] {
                ["type": "assistant", "timestamp": fx.t(ago), "message": ["role": "assistant", "stop_reason": "tool_use",
                                                                         "content": [["type": "tool_use", "id": "t\(ago)", "name": name, "input": input]]]]
            }
            func say(_ text: String, _ ago: TimeInterval) -> [String: Any] {
                ["type": "assistant", "timestamp": fx.t(ago), "message": ["role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": text]]]]
            }
            meta("aaa111", ["agentType": "general-purpose", "description": "Research agent terminal security", "toolUseId": a1, "spawnDepth": 1,
                            "requestShape": "background", "model": "opus", "finished": true])
            sub("aaa111", [prompt("Find out how cmux and other agent terminals keep transcripts private.", 2900),
                           tool("Agent", ["description": "Research Warp and iTerm2", "prompt": "Read their docs."], 2600),
                           say("Three research agents are still running.", 2500)])
            meta("nnn001", ["agentType": "general-purpose", "description": "Research Warp and iTerm2", "toolUseId": "toolu_N1", "parentAgentId": "aaa111",
                            "spawnDepth": 2, "requestShape": "background", "model": "sonnet"])
            sub("nnn001", [prompt("Read Warp's and iTerm2's docs on what they store.", 2600),
                           tool("WebFetch", ["url": "https://www.warp.dev/privacy", "prompt": "What is stored?"], 30)])
            meta("aaa222", ["agentType": "general-purpose", "description": "Build subagents and tasks in Overview", "toolUseId": a2, "spawnDepth": 1,
                            "requestShape": "background", "model": "opus"])
            sub("aaa222", [prompt("Show the chat's subagents and background tasks in the Overview tab, live.", 1500),
                           tool("Read", ["file_path": "/Users/test/hantuu/Sources/hantuu/Review/OverviewView.swift"], 900),
                           tool("Bash", ["command": "swift build -c debug", "description": "Build"], 20)])
            meta("aaa333", ["agentType": "general-purpose", "description": "Fix pasting media in reader composer", "toolUseId": a3, "spawnDepth": 1,
                            "requestShape": "background", "model": "sonnet", "finished": true])
            sub("aaa333", [prompt("Pasting an image into the reader's message box does nothing. Make it attach the image.", 1400),
                           tool("Edit", ["file_path": "/Users/test/hantuu/Sources/hantuu/ReaderMode/Composer.swift"], 1000),
                           tool("SubagentHandback", ["message": "Pasting now works for images and PDFs.\n\n## What changed\n- `Composer.swift` reads image data from the pasteboard\n- Files go through the same path as drops\n\nThe self test passes **421 of 421**."], 801)])

            // Background output files: fresh, quiet for 40 minutes, and finished.
            Paths.ensure(fx.tasks)
            for (name, ago) in [("bb1", 5.0), ("bb2", 2400.0), ("bb3", 300.0)] {
                let url = fx.tasks.appendingPathComponent("\(name).output")
                try? "output of \(name)\n".write(to: url, atomically: true, encoding: .utf8)
                setModified(url, now.addingTimeInterval(-ago))
            }
            return fx
        }
    }

    // MARK: Claude Code

    static func agentWorkClaudeParsing(_ fx: WorkFixture) {
        let notes = TaskNotification.parse("a " + WorkFixture.note("b1", toolUse: "u1", status: "failed", summary: "Background command \"x\" failed with exit code 2")
                                           + " b " + WorkFixture.note("a9", toolUse: "u2", status: "killed", summary: "Agent \"Map the repo\" was stopped by Claude", durationMs: 4500))
        check("work: two task notifications in one message", notes.count == 2 && notes[0].exitCode == 2 && notes[0].state == .failed
              && notes[1].state == .stopped && notes[1].isAgent && notes[1].durationMs == 4500 && notes[1].quotedName == "Map the repo", "\(notes)")
        check("work: waiting on its own agents is not finished",
              TaskNotification.parse(WorkFixture.note("a1", toolUse: nil, status: "completed", summary: "Agent \"x\" is waiting on its own background work")).first?.state == .waiting)

        var parser = ClaudeWorkParser()
        let data = (try? String(contentsOf: fx.transcript, encoding: .utf8)) ?? ""
        for l in data.split(separator: "\n") {
            if let o = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any] { parser.consume(o) }
        }
        let w = parser.work
        let byID = Dictionary(uniqueKeysWithValues: w.subagents.map { ($0.id, $0) })
        check("work: five agents from the Agent tool, in launch order, and one from before a resume", w.subagents.map(\.id) == [WorkFixture.a1, WorkFixture.a2, WorkFixture.a3, WorkFixture.a4, WorkFixture.a5, "toolu_OLD"]
              && w.subagents.last?.state == .stopped && w.subagents.last?.title == "Map the old code", "\(w.subagents.map(\.id))")
        check("work: a subagent's own task in the session queue isn't the chat's", !w.tasks.contains { $0.taskID == "bsub9" })
        let a1 = byID[WorkFixture.a1], a3 = byID[WorkFixture.a3], a4 = byID[WorkFixture.a4], a5 = byID[WorkFixture.a5]
        check("work: a background agent with its description, type, model, prompt and id", a1?.title == "Research agent terminal security" && a1?.type == "general-purpose"
              && a1?.model == "opus" && a1?.background == true && a1?.agentID == "aaa111" && a1?.prompt?.hasPrefix("Find out how cmux") == true, "\(String(describing: a1))")
        check("work: an agent waiting on its own agents reads as waiting", a1?.state == .waiting)
        check("work: a background agent's notification finishes it, once, with its duration", a3?.state == .done && a3?.duration == 600
              && a3?.endedAt.map { abs($0.timeIntervalSince(fx.now.addingTimeInterval(-800))) < 1 } == true && a3?.result == nil, "\(String(describing: a3))")
        check("work: a foreground agent's report comes from its handback", a4?.state == .done && a4?.result?.contains("12 links") == true
              && a4?.duration == 26 && a4?.agentID == "aaa444" && a4?.background == false, "\(String(describing: a4))")
        check("work: a failed agent keeps its error", a5?.state == .failed && a5?.result == "API Error: 529 Overloaded")

        let tasks = Dictionary(uniqueKeysWithValues: w.tasks.map { ($0.taskID ?? $0.id, $0) })
        check("work: background commands and a monitor, not foreground commands", w.tasks.count == 4 && tasks["bb1"] != nil && tasks["mm1"]?.kind == .monitor && !w.tasks.contains { $0.command == "git status" },
              "\(w.tasks.map { $0.taskID ?? $0.id })")
        check("work: a background command's description, command and output file", tasks["bb1"]?.title == "Build and run the hantuu self test" && tasks["bb1"]?.command == "./scripts/selftest.sh"
              && tasks["bb1"]?.outputFile == fx.tasks.appendingPathComponent("bb1.output").path && tasks["bb1"]?.state == .running, "\(String(describing: tasks["bb1"]))")
        check("work: request copies in the transcript don't finish anything", tasks["bb1"]?.state == .running)
        check("work: a command without a description is named by its command", tasks["bb2"]?.title == "npm run dev")
        check("work: a failed command keeps its exit code", tasks["bb3"]?.state == .failed && tasks["bb3"]?.exitCode == 1)
        check("work: a monitor's latest event", tasks["mm1"]?.lastEvent?.contains("expected '}'") == true && tasks["mm1"]?.state == .running)

        // SendMessage resumes a finished agent; TaskStop stops a command.
        var more = parser
        for l in [fx.use("toolu_S1", "SendMessage", ["to": "aaa333", "message": "Also handle drag and drop."], at: 50),
                  fx.result("toolu_S1", [["type": "text", "text": "{\"success\":true,\"message\":\"Resuming agent aaa333\"}"]], ["success": true, "resumedAgentId": "aaa333"], at: 49),
                  fx.use("toolu_K1", "TaskStop", ["task_id": "bb1"], at: 40),
                  fx.result("toolu_K1", "{\"message\":\"Successfully stopped task: bb1\"}", ["message": "Successfully stopped task: bb1"], at: 39)] {
            if let o = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any] { more.consume(o) }
        }
        let resumed = more.work.subagents.first { $0.agentID == "aaa333" }
        check("work: SendMessage to a finished agent makes it run again", resumed?.state == .running && resumed?.endedAt == nil
              && resumed?.activeSince.map { abs($0.timeIntervalSince(fx.now.addingTimeInterval(-49))) < 1 } == true)
        check("work: TaskStop stops a background command", more.work.tasks.first { $0.taskID == "bb1" }?.state == .stopped)

        // The prefiltered follower the sidebar uses reads the same as the Overview's full parse.
        let follower = WorkFollower(url: fx.transcript, kind: .claude).poll()
        let insights = InsightsFollower(url: fx.transcript, kind: .claude).poll().work
        check("work: the sidebar's quick follower agrees with the Overview's parse", follower == insights && follower == w)

        var tail = SubagentTailParser()
        for l in (try? String(contentsOf: fx.subagents.appendingPathComponent("agent-aaa333.jsonl"), encoding: .utf8))?.split(separator: "\n") ?? [] {
            if let o = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any] { tail.consume(o) }
        }
        check("work: a subagent's transcript gives its last step and its handback", tail.step == "Editing Sources/hantuu/ReaderMode/Composer.swift"
              && tail.handback?.hasPrefix("Pasting now works") == true && tail.endedTurn && tail.prompt?.hasPrefix("Pasting an image") == true, "\(tail)")
    }

    // MARK: Codex

    static func agentWorkCodexParsing() {
        func ev(_ type: String, _ payload: [String: Any], _ ago: TimeInterval = 0) -> [String: Any] {
            ["timestamp": WorkFixture.iso.string(from: Date().addingTimeInterval(-ago)), "type": type, "payload": payload]
        }
        let lines: [[String: Any]] = [
            ev("session_meta", ["id": "parent", "cwd": "/x"]),
            ev("response_item", ["type": "function_call", "name": "spawn_agent", "namespace": "collaboration", "call_id": "c1",
                                 "arguments": #"{"task_name":"ghostty_system_theme","model":"gpt-6.1-sol","reasoning_effort":"medium","message":"gAAAAAB-encrypted"}"#], 600),
            ev("response_item", ["type": "function_call_output", "call_id": "c1", "output": #"{"task_name":"/root/ghostty_system_theme"}"#], 600),
            ev("event_msg", ["type": "item_completed", "item": ["type": "SubAgentActivity", "kind": "started", "model": "gpt-6.1-sol", "reasoning_effort": "medium",
                                                               "agent_thread_id": "01aa-child", "agent_path": "/root/ghostty_system_theme"]], 600),
            ev("event_msg", ["type": "item_completed", "item": ["type": "SubAgentActivity", "kind": "started", "model": "gpt-6.1-sol",
                                                               "agent_thread_id": "01bb-child", "agent_path": "/root/verify_model"]], 500),
            ev("event_msg", ["type": "item_completed", "item": ["type": "SubAgentActivity", "kind": "completed", "agent_thread_id": "01bb-child", "agent_path": "/root/verify_model"]], 300),
            ev("response_item", ["type": "custom_tool_call", "name": "exec", "call_id": "x1", "input": #"text(await tools.exec_command({cmd:"npm run dev",yield_time_ms:1000}));"#], 400),
            ev("response_item", ["type": "custom_tool_call_output", "call_id": "x1", "output": [["type": "input_text", "text": "Script completed\nOutput:\n"],
                ["type": "input_text", "text": #"{"chunk_id":"ab12","wall_time_seconds":1.0,"session_id":54914,"original_token_count":0,"output":""}"#]]], 399),
            ev("response_item", ["type": "custom_tool_call", "name": "exec", "call_id": "x2", "input": #"text(await tools.exec_command({cmd:"swift build",yield_time_ms:1000}));"#], 380),
            ev("response_item", ["type": "custom_tool_call_output", "call_id": "x2", "output": [["type": "input_text", "text":
                #"{"chunk_id":"cd34","wall_time_seconds":1.0,"session_id":91239,"original_token_count":0,"output":""}"#]]], 379),
            ev("event_msg", ["type": "item_completed", "item": ["type": "CommandExecution", "process_id": "91239", "status": "failed", "exit_code": 1,
                                                               "command": ["/bin/zsh", "-lc", "swift build"], "duration": ["secs": 6, "nanos": 500_000_000]]], 350),
            ev("response_item", ["type": "custom_tool_call", "name": "exec", "call_id": "x3", "input": #"text(await tools.exec_command({cmd:"ls"}));"#], 340),
            ev("response_item", ["type": "custom_tool_call_output", "call_id": "x3", "output": [["type": "input_text", "text":
                #"{"chunk_id":"ef56","wall_time_seconds":0.1,"exit_code":0,"original_token_count":3,"output":"a b"}"#]]], 339),
            ev("response_item", ["type": "function_call", "name": "exec_command", "call_id": "x4", "arguments": #"{"cmd":"tail -f server.log"}"#], 330),
            ev("response_item", ["type": "function_call_output", "call_id": "x4", "output": "Process running with session ID 777\nOutput:\n"], 329),
        ]
        var p = CodexWorkParser()
        for l in lines { p.consume(l) }
        let w = p.work
        check("codex: spawn_agent and SubAgentActivity name the subagents", w.subagents.map(\.title) == ["ghostty system theme", "verify model"]
              && w.subagents.first?.agentID == "01aa-child" && w.subagents.first?.model == "gpt-6.1-sol" && w.subagents.first?.state == .running, "\(w.subagents)")
        check("codex: a completed subagent", w.subagents.last?.state == .done && w.subagents.last?.agentID == "01bb-child")
        let terms = Dictionary(uniqueKeysWithValues: w.tasks.map { ($0.taskID ?? "", $0) })
        check("codex: unified exec terminals that outlived their call, and not the ones that didn't", w.tasks.count == 3 && terms["54914"]?.title == "npm run dev"
              && terms["54914"]?.kind == .terminal && terms["777"]?.title == "tail -f server.log", "\(w.tasks)")
        check("codex: a terminal's end comes from its CommandExecution", terms["91239"]?.state == .failed && terms["91239"]?.exitCode == 1 && terms["91239"]?.duration == 6.5)
        check("codex: the session id finder", CodexWorkParser.runningSessions(in: #"{"chunk_id":"a","session_id":5,"output":""}{"chunk_id":"b","session_id":6,"exit_code":0}"#) == ["5"])

        var child = CodexChildParser()
        for l: [String: Any] in [
            ["type": "session_meta", "payload": ["id": "01aa-child", "agent_nickname": "Volta", "source": ["subagent": ["thread_spawn": ["agent_path": "/root/x"]]]]],
            ev("event_msg", ["type": "task_started", "turn_id": "t1"], 60),
            ev("response_item", ["type": "custom_tool_call", "name": "exec", "call_id": "e1", "input": #"text(await tools.exec_command({cmd:"rg theme"}));"#], 50),
            ev("response_item", ["type": "function_call", "name": "send_message", "namespace": "collaboration", "call_id": "e2", "arguments": "{}"], 40),
        ] { child.consume(l) }
        check("codex: a subagent's rollout says it's running and what it's doing", child.running == true && child.step == "Running rg theme" && child.nickname == "Volta", "\(child)")
        child.consume(ev("event_msg", ["type": "task_complete", "turn_id": "t1", "last_agent_message": "Themes switch with the system.", "duration_ms": "93195"]))
        check("codex: and when it finished, with its last message", child.running == false && child.lastMessage == "Themes switch with the system." && child.duration == 93.195)
    }

    // MARK: The tracker

    static func agentWorkTracker(_ fx: WorkFixture) {
        let base = InsightsFollower(url: fx.transcript, kind: .claude).poll().work
        let tracker = AgentWorkTracker()
        let w = tracker.update(base, transcript: fx.transcript, kind: .claude, processStart: fx.processStart, now: fx.now)
        let byAgent = Dictionary(uniqueKeysWithValues: w.subagents.compactMap { a in a.agentID.map { ($0, a) } })
        check("tracker: what a running agent is doing now, from its own transcript", byAgent["aaa222"]?.step == "Running Bash: swift build -c debug"
              && byAgent["aaa222"]?.transcript?.hasSuffix("agent-aaa222.jsonl") == true, "\(String(describing: byAgent["aaa222"]))")
        check("tracker: an agent's report from its handback when the notification only points at it",
              byAgent["aaa333"]?.result?.hasPrefix("Pasting now works") == true, "\(String(describing: byAgent["aaa333"]?.result))")
        let nested = byAgent["nnn001"]
        check("tracker: an agent a subagent started, under its parent, from the meta file", nested?.parentID == WorkFixture.a1 && nested?.title == "Research Warp and iTerm2"
              && nested?.model == "sonnet" && nested?.state == .running && nested?.step == "Fetching warp.dev" && nested?.prompt?.hasPrefix("Read Warp's") == true,
              "\(String(describing: nested))")
        let tasks = Dictionary(uniqueKeysWithValues: w.tasks.map { ($0.taskID ?? $0.id, $0) })
        check("tracker: a background command quiet for 40 minutes is stale", tasks["bb2"]?.state == .stale
              && tasks["bb2"]?.lastUpdate.map { abs($0.timeIntervalSince(fx.now.addingTimeInterval(-2400))) < 2 } == true, "\(String(describing: tasks["bb2"]))")
        check("tracker: fresh output keeps a command running", tasks["bb1"]?.state == .running)

        // The parent finishing means its children are done too.
        var finished = base
        if let i = finished.subagents.firstIndex(where: { $0.id == WorkFixture.a1 }) { finished.subagents[i].state = .done }
        let w2 = AgentWorkTracker().update(finished, transcript: fx.transcript, kind: .claude, processStart: fx.processStart, now: fx.now)
        check("tracker: an agent's own agents finish with it", w2.subagents.first { $0.agentID == "nnn001" }?.state == .done)

        // The subagents folder follows the transcript path, so a switched session reads its own.
        let other = fx.transcript.deletingLastPathComponent().appendingPathComponent("99999999-0000-4000-8000-000000000000.jsonl")
        try? FileManager.default.copyItem(at: fx.transcript, to: other)
        let w3 = tracker.update(base, transcript: other, kind: .claude, processStart: fx.processStart, now: fx.now)
        check("tracker: a new transcript path brings its own subagents folder", w3.subagents.first { $0.agentID == "aaa222" }?.step == nil && !w3.subagents.contains { $0.agentID == "nnn001" })
        try? FileManager.default.removeItem(at: other)
    }

    static func agentWorkCodexTracker(_ base: URL) {
        let root = base.appendingPathComponent("codex-sessions", isDirectory: true)
        let started = Date().addingTimeInterval(-600)
        let c = Calendar.current.dateComponents([.year, .month, .day], from: started)
        let day = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        func ev(_ type: String, _ payload: [String: Any]) -> String { WorkFixture.line(["timestamp": WorkFixture.iso.string(from: Date()), "type": type, "payload": payload]) }
        WorkFixture.write(day.appendingPathComponent("rollout-2026-11-11T10-00-00-01aa-child.jsonl"), [
            ev("session_meta", ["id": "01aa-child", "agent_nickname": "Volta", "parent_thread_id": "parent", "thread_source": "subagent"]),
            ev("event_msg", ["type": "task_started", "turn_id": "t1"]),
            ev("response_item", ["type": "function_call", "name": "exec_command", "call_id": "e1", "arguments": #"{"cmd":"rg theme Sources"}"#]),
        ])
        WorkFixture.write(day.appendingPathComponent("rollout-2026-11-11T10-01-00-01bb-child.jsonl"), [
            ev("session_meta", ["id": "01bb-child", "agent_nickname": "Curie"]),
            ev("event_msg", ["type": "task_started", "turn_id": "t2"]),
            ev("event_msg", ["type": "task_complete", "turn_id": "t2", "last_agent_message": "Verified: the model is **gpt-6.1-sol**.", "duration_ms": 93195]),
        ])
        var a = SubagentInfo(id: "/root/ghostty_system_theme", agentID: "01aa-child", title: "ghostty system theme")
        a.startedAt = started
        var b = SubagentInfo(id: "/root/verify_model", agentID: "01bb-child", title: "verify model")
        b.startedAt = started
        let tracker = AgentWorkTracker()
        tracker.codexRoot = root
        let w = tracker.update(AgentWork(subagents: [a, b]), transcript: base.appendingPathComponent("parent.jsonl"), kind: .codex, processStart: started.addingTimeInterval(-60))
        check("codex tracker: a subagent's own rollout says what it's doing, with its nickname", w.subagents[0].state == .running && w.subagents[0].step == "Running rg theme Sources"
              && w.subagents[0].type == "Volta", "\(w.subagents[0])")
        check("codex tracker: a finished subagent's last message is its report", w.subagents[1].state == .done && w.subagents[1].result?.contains("gpt-6.1-sol") == true
              && w.subagents[1].duration == 93.195, "\(w.subagents[1])")

        // A new Codex chat in the same folder must find its own rollout, not a subagent's that started first.
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let now = root.appendingPathComponent(String(format: "%04d/%02d/%02d", today.year!, today.month!, today.day!))
        let chatStart = Date().addingTimeInterval(-30)
        WorkFixture.write(now.appendingPathComponent("rollout-2026-11-11T11-00-00-01cc-sub.jsonl"), [WorkFixture.line(["type": "session_meta", "payload": [
            "id": "01cc-sub", "cwd": "/Users/test/hantuu", "timestamp": WorkFixture.iso.string(from: chatStart.addingTimeInterval(5)),
            "parent_thread_id": "01aa-parent", "thread_source": "subagent"]])])
        WorkFixture.write(now.appendingPathComponent("rollout-2026-11-11T11-00-09-01dd-chat.jsonl"), [WorkFixture.line(["type": "session_meta", "payload": [
            "id": "01dd-chat", "cwd": "/Users/test/hantuu", "timestamp": WorkFixture.iso.string(from: chatStart.addingTimeInterval(9)), "thread_source": "user"]])])
        let found = CodexTranscriptParser.locate(cwd: "/Users/test/hantuu", after: chatStart, excluding: [], root: root)
        check("codex: a chat finds its own rollout, never a subagent's", found?.1.id == "01dd-chat", "\(String(describing: found?.1.id))")
    }

    // MARK: What still counts as running

    static func agentWorkRules(_ fx: WorkFixture) {
        let base = WorkFollower(url: fx.transcript, kind: .claude).poll()
        var live = base
        BackgroundRules.settle(&live, transcript: fx.transcript, processStart: fx.processStart, now: fx.now)
        let s = BackgroundSummary.of(live)
        check("rules: two agents and two tasks still running, the quiet one left out", s.agents == 2 && s.tasks == 2
              && s.detail == "2 agents and 2 tasks running in background", "\(s)")
        check("rules: the last end is the latest finished piece", s.endedAt.map { abs($0.timeIntervalSince(fx.now.addingTimeInterval(-300))) < 1 } == true, "\(String(describing: s.endedAt))")

        // A relaunch, or a resume, started a new agent process after some of this work began.
        var restarted = base
        BackgroundRules.settle(&restarted, transcript: fx.transcript, processStart: fx.now.addingTimeInterval(-1000), now: fx.now)
        let r = BackgroundSummary.of(restarted)
        check("rules: work from before the agent's current process is stopped", r.agents == 0 && r.tasks == 2
              && restarted.subagents.first { $0.id == WorkFixture.a2 }?.state == .stopped, "\(r)")
        var ended = base
        BackgroundRules.settle(&ended, transcript: fx.transcript, processStart: nil, now: fx.now)
        check("rules: nothing runs once the chat has ended", BackgroundSummary.of(ended).count == 0 && ended.tasks.first { $0.taskID == "bb1" }?.state == .stopped)

        // An agent whose transcript stopped growing an hour ago is stale.
        var later = base
        BackgroundRules.settle(&later, transcript: fx.transcript, processStart: fx.processStart, now: fx.now.addingTimeInterval(3 * 3600))
        check("rules: everything quiet for hours is stale, not running", BackgroundSummary.of(later).count == 0
              && later.subagents.first { $0.id == WorkFixture.a2 }?.state == .stale && later.tasks.first { $0.taskID == "bb1" }?.state == .stale)

        func one(_ a: Int, _ t: Int, _ title: String = "x") -> String {
            var w = AgentWork()
            for i in 0..<a { w.subagents.append(SubagentInfo(id: "a\(i)", title: title)) }
            for i in 0..<t { w.tasks.append(BackgroundTaskInfo(id: "t\(i)", kind: .shell, title: title)) }
            return BackgroundSummary.of(w).detail
        }
        check("rules: detail lines", one(1, 0, "Research cmux") == "Running in background: Research cmux" && one(0, 1, "npm run dev") == "Running in background: npm run dev"
              && one(3, 0) == "3 agents running in background" && one(0, 2) == "2 tasks running in background" && one(1, 1) == "1 agent and 1 task running in background"
              && one(0, 0) == "", "\(one(1, 1))")
    }

    // MARK: The sidebar's watcher

    static func agentWorkWatch(_ fx: WorkFixture) {
        let model = AppModel()
        let project = Project(path: "/Users/test/hantuu")
        model.projects = [project]
        let chat = Chat(projectID: project.id, agentID: "claude")
        chat.transcriptPath = fx.transcript.path
        chat.startedAt = fx.processStart
        model.chats = [chat]
        var got: [UUID: BackgroundSummary] = [:]
        func tick(_ w: BackgroundWatch) -> Bool {
            var done = false
            w.tick(now: fx.now) { done = true }
            return waitUntil(10) { done }
        }
        let watch2 = BackgroundWatch()
        watch2.deliver = { id, s in got[id] = s }
        watch2.start(model: model)
        watch2.stop()
        _ = waitUntil(10) { got[chat.id] != nil }
        check("watch: a live chat's background work, read from its transcript", got[chat.id]?.count == 4 && got[chat.id]?.checkedAt != nil, "\(String(describing: got[chat.id]))")

        // Relaunch: the agent process restarted, so the summary is worked out again from the transcript.
        got = [:]
        chat.startedAt = fx.now.addingTimeInterval(-1000)
        let watch3 = BackgroundWatch()
        watch3.deliver = { id, s in got[id] = s }
        watch3.start(model: model)
        watch3.stop()
        _ = waitUntil(10) { got[chat.id] != nil }
        check("watch: after a restart only work the new process started counts", got[chat.id]?.agents == 0 && got[chat.id]?.tasks == 2, "\(String(describing: got[chat.id]))")

        // New lines are picked up on the next tick, and an ended chat isn't watched.
        WorkFixture.append(fx.transcript, [fx.queued(WorkFixture.note("bb1", toolUse: "toolu_B1", status: "completed",
                                                                       summary: "Background command \"Build and run the hantuu self test\" completed (exit code 0)"), at: 1)])
        got = [:]
        _ = tick(watch3)
        _ = waitUntil(10) { got[chat.id] != nil }
        check("watch: a completion appended to the transcript is seen on the next tick", got[chat.id]?.tasks == 1, "\(String(describing: got[chat.id]))")
        chat.status = .ended
        got = [:]
        _ = tick(watch3)
        check("watch: ended chats aren't watched", got[chat.id] == nil)
    }

    // MARK: Status

    static func agentWorkReducer() {
        let t0 = Date()
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        func run(_ steps: [(Double, OriginSignal)], agent: AgentKind = .claude, watches: Bool = true, from: StatusState = StatusState()) -> StatusState {
            var st = from
            for (when, sig) in steps {
                StatusReducer.apply(sig, to: &st, ctx: StatusContext(agent: agent, focused: false, now: at(when), watchesBackground: watches))
            }
            return st
        }
        func bg(_ n: Int, ended: Double? = nil, checked: Double) -> OriginSignal {
            OriginSignal(origin: .transcript, signal: .background(BackgroundSummary(agents: n, tasks: 0, detail: n == 0 ? "" : "\(n) agents running in background",
                                                                                    endedAt: ended.map(at), checkedAt: at(checked))))
        }
        let ups = signals([hook("UserPromptSubmit")])[0]
        let stop = signals([hook("Stop", #""last_assistant_message":"Started two agents.""#)])[0]
        let stop2 = signals([hook("Stop", #""last_assistant_message":"Both agents are done.""#)])[0]

        var st = run([(0, ups), (1, bg(2, checked: 1)), (5, stop)])
        check("background: a turn that just ended waits for the next check", st.activity == .working, "\(st.activity)")
        st = run([(6, bg(2, checked: 6))], from: st)
        check("background: Stop with agents still running keeps the chat running", st.activity == .background && st.detail == "2 agents running in background"
              && !st.activity.wantsAttention, "\(st.activity) \(st.detail)")
        st = run([(100, bg(0, ended: 99, checked: 100))], from: st)
        check("background: the last one finishing waits for the turn that reads its results", st.activity == .background && st.detail == "Background work finished")
        st = run([(101, ups), (110, stop2), (112, bg(0, ended: 99, checked: 112))], from: st)
        check("background: that turn's end is when the chat is done", st.activity == .doneUnseen && st.doneAt == at(110) && st.lastMessage == "Both agents are done.",
              "\(st.activity) \(String(describing: st.doneAt))")

        var race = run([(0, ups), (0.5, bg(0, checked: 0.5)), (4, stop), (4.5, bg(0, checked: 2))])
        check("background: a check that began before Stop doesn't call the chat done", race.activity == .working)
        race = run([(6, bg(1, checked: 5))], from: race)
        check("background: the check after Stop sees the agent it started", race.activity == .background)

        var quiet = run([(0, ups), (1, bg(1, checked: 1)), (10, stop), (11, bg(1, checked: 11)), (51, bg(0, ended: 50, checked: 51))])
        check("background: no turn yet, still settling", quiet.activity == .background)
        quiet = run([(73, bg(0, ended: 50, checked: 73))], from: quiet)
        check("background: no turn came, so it's done from when the work ended", quiet.activity == .doneUnseen && quiet.doneAt == at(50), "\(quiet.activity)")

        let handled = run([(0, ups), (1, bg(1, checked: 1)), (10, stop), (11, bg(1, checked: 11)), (60, ups), (70, stop2), (71, bg(0, ended: 58, checked: 71))])
        check("background: results a turn already read leave the chat done right away", handled.activity == .doneUnseen && handled.doneAt == at(70), "\(handled.activity)")

        let needs = run([(0, ups), (1, bg(1, checked: 1)), (5, signals([hook("Stop", #""last_assistant_message":"Want me to merge them?""#)])[0]), (6, bg(1, checked: 6))])
        check("background: a question at the end still needs you", needs.activity == .needsAnswer)

        let codex = run([(0, OriginSignal(origin: .transcript, signal: .codexTurnStarted(id: "t1"))), (1, bg(1, checked: 1)),
                         (5, OriginSignal(origin: .transcript, signal: .codexTurnComplete(id: "t1", lastMessage: "Spawned a helper."))), (6, bg(1, checked: 6))], agent: .codex)
        let codexDone = run([(30, bg(0, ended: 29, checked: 30)), (39, bg(0, ended: 29, checked: 39))], agent: .codex, from: codex)
        check("background: Codex subagents keep a Codex chat running too", codex.activity == .background && codexDone.activity == .doneUnseen && codexDone.doneAt == at(29))

        let unwatched = run([(0, ups), (5, stop)], watches: false)
        check("background: without a watcher, Stop is Done as before", unwatched.activity == .doneUnseen)
    }

    static func agentWorkEngine(_ fx: WorkFixture) {
        let model = AppModel()
        let project = Project(path: cwd)
        model.projects = [project]
        let center = StatusCenter()
        let rec = NoticeRecorder()
        center.notifier = rec
        center.appIsActive = { false }
        center.start(model: model, live: false)
        center.watchingBackground = true
        let c = Chat(projectID: project.id, agentID: "claude")
        c.terminalTitle = "Orchestrate the fixes"
        c.transcriptPath = fx.transcript.path
        model.chats = [c]
        let file = AgentHooks.eventsFile(for: c.id)
        func append(_ lines: [String]) {
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            WorkFixture.append(file, lines)
        }
        func summary(_ n: Int, ended: Date? = nil) -> BackgroundSummary {
            BackgroundSummary(agents: n, tasks: 0, detail: n == 0 ? "" : "\(n) agents running in background", endedAt: ended, checkedAt: Date())
        }
        append([hook("SessionStart"), hook("UserPromptSubmit"), hook("Stop", #""last_assistant_message":"Started two agents.""#)])
        center.poll()
        center.backgroundChanged(c.id, summary(2))
        check("engine: a chat with agents running in background reads running, not Done", c.activity == .background
              && c.activityDetail == "2 agents running in background" && center.attention.isEmpty && rec.posted.isEmpty, "\(c.activity) \(c.activityDetail)")
        // The agents ended a while after the turn that started them.
        let ended = Date().addingTimeInterval(10)
        center.backgroundChanged(c.id, summary(0, ended: ended))
        check("engine: no finished notification while the results are still on their way", c.activity == .background && rec.posted.isEmpty)
        append([hook("UserPromptSubmit", #""prompt":"<task-notification>\n<task-id>aaa111</task-id>\n</task-notification>""#),
                hook("Stop", #""last_assistant_message":"Both agents are done.""#)])
        center.poll()
        center.backgroundChanged(c.id, summary(0, ended: ended))
        check("engine: one Done notification, once everything is done", c.activity == .doneUnseen && rec.posted.count == 1 && rec.posted.first?.body == "Both agents are done."
              && center.attention == [c.id], "\(c.activity) \(rec.posted)")
        center.backgroundChanged(c.id, summary(0, ended: ended))
        check("engine: and no second one", rec.posted.count == 1)
    }

    // MARK: Snapshots

    static func agentWorkSnapshots(_ dir: URL, _ fx: WorkFixture) {
        let out = dir.deletingLastPathComponent().appendingPathComponent("snapshots", isDirectory: true)
        Paths.ensure(out)
        Theme.configure(from: GhosttyApp.shared)
        ActivityDot.fixedPhase = 0.45
        defer { ActivityDot.fixedPhase = nil; ActivityDot.backgroundPulses = false }

        let model = AppModel()
        let project = model.addProject(path: fx.transcript.deletingLastPathComponent().path)
        let chat = Chat(projectID: project.id, agentID: "claude", createdAt: fx.processStart)
        chat.terminalTitle = "Orchestrate the fixes"
        chat.transcriptPath = fx.transcript.path
        chat.startedAt = fx.processStart
        var tv: TerminalView?
        if let g = GhosttyApp.shared {
            tv = TerminalView(app: g.app, launch: .init(workingDirectory: project.path, command: "/bin/sh -c 'sleep 30'"), handlesChildExit: true)
            chat.terminal = tv
        }
        defer { tv?.destroy() }
        chat.activity = .background
        chat.activityDetail = "2 agents and 2 tasks running in background"
        model.chats = [chat]
        model.selectedChatID = chat.id
        model.panelVisible = true
        model.panelTab = .overview
        let center = ReviewCenter()
        center.fixtureMode = true
        center.configure(model: model)
        center.setActiveTab(.overview)
        let loaded = waitUntil(10) { center.work.subagents.count >= 6 && center.work.subagents.contains { $0.result?.hasPrefix("Pasting") == true } }
        check("overview: the Overview shows the chat's agents and background tasks", loaded && center.work.tasks.count == 4, "\(center.work.subagents.count) \(center.work.tasks.count)")

        let w = makeWindow()
        func render<V: View>(_ view: V, size: NSSize, name: String, dark: Bool) -> Bool {
            let host = NSHostingView(rootView: AnyView(view.environmentObject(model).environmentObject(center).environment(\.colorScheme, dark ? .dark : .light)))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: size)
            w.contentView?.addSubview(host)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            defer { host.removeFromSuperview() }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return false }
            return (try? png.write(to: out.appendingPathComponent(name))) != nil
        }
        let overview = OverviewView().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        let o1 = render(overview, size: NSSize(width: 560, height: 700), name: "overview-agents-dark.png", dark: true)
        let o2 = render(overview, size: NSSize(width: 560, height: 700), name: "overview-agents-light.png", dark: false)
        let expandedIDs: Set<String> = [WorkFixture.a3, WorkFixture.a5]
        let expanded = ScrollView {
            AgentsCard(agents: center.work.subagents, expanded: expandedIDs).padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.hChrome)
        let o3 = render(expanded, size: NSSize(width: 560, height: 700), name: "overview-agents-expanded-dark.png", dark: true)
        let o4 = render(expanded, size: NSSize(width: 560, height: 700), name: "overview-agents-expanded-light.png", dark: false)
        let narrow = render(overview, size: NSSize(width: 360, height: 700), name: "overview-agents-narrow.png", dark: true)
        check("snapshot: Agents and Background tasks cards, light and dark, collapsed and expanded, narrow", o1 && o2 && o3 && o4 && narrow)

        // The sidebar: a chat working, one running in background, one done, one idle.
        let side = AppModel()
        let hantuu = Project(path: "/Users/test/hantuu")
        side.projects = [hantuu]
        func row(_ title: String, _ act: AgentActivity, _ detail: String, done: TimeInterval? = nil) -> Chat {
            let c = Chat(projectID: hantuu.id, agentID: "claude")
            c.terminalTitle = title
            c.activity = act
            c.activityDetail = detail
            c.lastTurnEndedAt = done.map { Date().addingTimeInterval(-$0) }
            return c
        }
        side.chats = [row("Orchestrate the fixes", .background, "2 agents running in background"),
                      row("Status dots and notifications", .working, "Running Bash: swift build"),
                      row("Start the docs site", .background, "Running in background: npm run dev"),
                      row("Tidy the README", .doneUnseen, "", done: 125),
                      row("Summarise this week", .idle, "", done: 840)]
        side.selectedChatID = side.chats[1].id
        func renderSidebar(_ name: String, dark: Bool) -> Bool {
            let host = NSHostingView(rootView: AnyView(SidebarView().environmentObject(side).environment(\.colorScheme, dark ? .dark : .light)))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 260, height: 300)
            w.contentView?.addSubview(host)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            defer { host.removeFromSuperview() }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
            host.cacheDisplay(in: host.bounds, to: rep)
            return (rep.representation(using: .png, properties: [:]).flatMap { try? $0.write(to: out.appendingPathComponent(name)) }) != nil
        }
        ActivityDot.backgroundPulses = false
        let s1 = renderSidebar("status-background-still-dark.png", dark: true)
        let s2 = renderSidebar("status-background-still-light.png", dark: false)
        ActivityDot.backgroundPulses = true
        let s3 = renderSidebar("status-background-pulse-dark.png", dark: true)
        ActivityDot.backgroundPulses = false
        check("snapshot: the sidebar with chats running in background, both dot styles", s1 && s2 && s3)
        print("      agent work snapshots in \(out.path)")
    }
}
