import AppKit
import SwiftUI

/// Self-test checks for agent status (bet 1): hook parsing, precedence, the hook commands
/// themselves run through /bin/sh, the engine end to end, and offscreen snapshots.
extension SelfTest {
    static func status(_ dir: URL) {
        statusParsing()
        statusReducer()
        statusArguments()
        statusHookCommands(dir)
        statusEngine(dir)
        statusSnapshots(dir)
        liveAgent(dir)   // only with HANTUU_LIVE_AGENT=claude or codex
    }

    // MARK: Fixtures

    static let cwd = "/Users/test/proj"

    static func hook(_ event: String, _ extra: String = "") -> String {
        #"{"session_id":"s1","transcript_path":"/tmp/t.jsonl","cwd":"/Users/test/proj","permission_mode":"default","hook_event_name":"\#(event)""# + (extra.isEmpty ? "" : "," + extra) + "}"
    }

    static func signals(_ lines: [String]) -> [OriginSignal] {
        lines.flatMap { HookLineParser.parse(Data($0.utf8), cwd: cwd) }
    }

    static func reduce(_ lines: [OriginSignal], agent: AgentKind = .claude, focused: Bool = false, from start: StatusState = StatusState()) -> StatusState {
        var st = start
        let ctx = StatusContext(agent: agent, focused: focused, now: Date())
        for s in lines { StatusReducer.apply(s, to: &st, ctx: ctx) }
        return st
    }

    static let preBash = hook("PreToolUse", #""tool_name":"Bash","tool_input":{"command":"npm test","description":"Run tests"},"tool_use_id":"toolu_A""#)
    static let permBash = hook("PermissionRequest", #""tool_name":"Bash","tool_input":{"command":"npm test","description":"Run tests"}"#)
    static let postBash = #"{"hook_event_name":"PostToolUse","tool_use_id":"toolu_A"}"#

    // MARK: Parsing

    static func statusParsing() {
        func one(_ line: String) -> StatusSignal? { signals([line]).first?.signal }
        check("status: SessionStart parsed", one(hook("SessionStart", #""source":"resume""#)) == .sessionStarted(source: "resume"))
        check("status: UserPromptSubmit parsed", one(hook("UserPromptSubmit", #""prompt":"hi""#)) == .promptSubmitted)
        if case .toolStarted(let id, let call)? = one(preBash) {
            check("status: PreToolUse Bash -> Running Bash: npm test", id == "toolu_A" && call.workingText == "Running Bash: npm test", call.workingText)
        } else { check("status: PreToolUse parsed", false) }
        if case .permissionRequested(let call)? = one(permBash) {
            check("status: PermissionRequest -> Wants to run Bash: npm test", call.wantsText == "Wants to run Bash: npm test", call.wantsText)
        } else { check("status: PermissionRequest parsed", false) }
        let edit = hook("PermissionRequest", #""tool_name":"Edit","tool_input":{"file_path":"/Users/test/proj/Sources/App.swift","old_string":"a","new_string":"b"}"#)
        if case .permissionRequested(let call)? = one(edit) {
            check("status: Edit path shown relative to the project", call.wantsText == "Wants to edit Sources/App.swift" && call.workingText == "Editing Sources/App.swift", call.wantsText)
        } else { check("status: Edit parsed", false) }
        let ask = hook("PreToolUse", #""tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database should I use?","header":"DB","options":[{"label":"Postgres"},{"label":"SQLite"}],"multiSelect":false}]},"tool_use_id":"toolu_Q""#)
        if case .toolStarted(_, let call)? = one(ask) {
            check("status: AskUserQuestion -> Asks: <question>", call.isQuestion && call.askText == "Asks: Which database should I use?", call.askText)
        } else { check("status: AskUserQuestion parsed", false) }
        check("status: compact PostToolUse line parsed", one(postBash) == .toolFinished(id: "toolu_A"))
        check("status: PostToolUseFailure parsed", one(#"{"hook_event_name":"PostToolUseFailure","tool_use_id":"toolu_B"}"#) == .toolFinished(id: "toolu_B"))
        check("status: Stop carries the last message", one(hook("Stop", #""stop_hook_active":false,"last_assistant_message":"All green.""#)) == .turnEnded(lastMessage: "All green."))
        check("status: StopFailure parsed", one(hook("StopFailure", #""error":"rate_limit","last_assistant_message":"API Error: Rate limit reached""#)) == .turnFailed(reason: "API Error: Rate limit reached"))
        check("status: Notification parsed", one(hook("Notification", #""message":"Claude needs your permission to use Bash","notification_type":"permission_prompt""#)) == .notification(type: "permission_prompt", message: "Claude needs your permission to use Bash"))
        check("status: SessionEnd parsed", one(hook("SessionEnd", #""reason":"clear""#)) == .sessionEnded(reason: "clear"))
        let notify = signals([#"{"type":"agent-turn-complete","thread-id":"th","turn-id":"t1","cwd":"/Users/test/proj","input-messages":["hi"],"last-assistant-message":"Done here."}"#])
        check("status: Codex notify parsed as a turn end", notify == [OriginSignal(origin: .notify, signal: .codexTurnComplete(id: "t1", lastMessage: "Done here."))])
        check("status: junk lines ignored", signals(["not json", "{}", #"{"hook_event_name":"FileChanged"}"#]).isEmpty)

        // Transcripts: only interrupts and declined prompts.
        let decline = #"{"type":"user","uuid":"r","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_A","content":"The user doesn't want to proceed with this tool use. The tool use was rejected.","is_error":true}]}}"#
        let interrupt = #"{"type":"user","uuid":"i","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
        let tsig = (ClaudeTranscriptStatus.parse(Data(decline.utf8)) + ClaudeTranscriptStatus.parse(Data(interrupt.utf8))).map(\.signal)
        check("status: transcript decline and interrupt", tsig == [.declined(id: "toolu_A"), .interrupted], "\(tsig)")
        check("status: ordinary transcript lines ignored", ClaudeTranscriptStatus.parse(Data(claudeFixture[3].utf8)).isEmpty)

        let rollout = [
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"task_started","turn_id":"t1","started_at":1}}"#,
            #"{"timestamp":"t","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"swift build\"]}","call_id":"c1"}}"#,
            #"{"timestamp":"t","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"ok"}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"Built."}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
        ]
        let rsig = rollout.flatMap { CodexRolloutStatus.parse(Data($0.utf8), cwd: cwd) }.map(\.signal)
        var shellOK = false
        if rsig.count == 4, case .toolStarted(_, let call) = rsig[1] { shellOK = call.workingText == "Running swift build" }
        check("status: Codex rollout turns and tools", rsig.count == 4 && rsig[0] == .codexTurnStarted(id: "t1") && shellOK
              && rsig[2] == .toolFinished(id: nil) && rsig[3] == .codexTurnComplete(id: "t1", lastMessage: "Built."), "\(rsig)")
        check("status: Codex approval text", TerminalNoticeText.classify("Approval requested: npm test") == (.permission, "Wants to run npm test"))
        check("status: Codex edit text", TerminalNoticeText.classify("Codex wants to edit src/a.py").1 == "Wants to edit src/a.py")
        check("status: Codex question text", TerminalNoticeText.classify("Question: Which port?") == (.answer, "Asks: Which port?"))
        check("status: final question found", StatusText.finalQuestion("I fixed the tests.\n\nShould I also update the **README**?") == "Should I also update the README?")
        check("status: no question, no Needs answer", StatusText.finalQuestion("All done. Tests pass.") == nil && StatusText.finalQuestion("```\nx?\n```\nDone.") == nil)
        let now = Date()
        check("status: Done 2m ago", StatusText.done(at: now.addingTimeInterval(-125), now: now) == "Done 2m ago" && StatusText.done(at: now, now: now) == "Done just now")
    }

    // MARK: Precedence and transitions

    static func statusReducer() {
        let hookTurn = signals([hook("UserPromptSubmit"), preBash])
        var st = reduce(hookTurn)
        check("status: prompt then tool -> Working with the command", st.activity == .working && st.detail == "Running Bash: npm test", st.detail)
        st = reduce(signals([permBash]), from: st)
        check("status: PermissionRequest -> Needs permission", st.activity == .needsPermission && st.detail == "Wants to run Bash: npm test", st.detail)
        StatusReducer.markSeen(&st, ctx: StatusContext(agent: .claude, focused: true))
        check("status: Needs permission survives being looked at", st.activity == .needsPermission)
        st = reduce(signals([postBash]), from: st)
        check("status: its PostToolUse resumes Working", st.activity == .working)
        st = reduce(signals([hook("Stop", #""last_assistant_message":"Tests pass.""#)]), from: st)
        check("status: Stop while away -> Done, unseen", st.activity == .doneUnseen && st.lastMessage == "Tests pass.")
        StatusReducer.markSeen(&st, ctx: StatusContext(agent: .claude, focused: true))
        check("status: looking at it -> Idle, Done Xm ago", st.activity == .idle && st.detail.isEmpty && st.doneAt != nil)
        let focusedStop = reduce(hookTurn + signals([hook("Stop", #""last_assistant_message":"ok""#)]), focused: true)
        check("status: Stop while looking -> Idle straight away", focusedStop.activity == .idle)

        // Parallel subagents: another agent's PostToolUse must not clear a pending prompt.
        let preA = hook("PreToolUse", #""agent_id":"a1","tool_name":"Bash","tool_input":{"command":"rm -rf build"},"tool_use_id":"toolu_1""#)
        let preB = hook("PreToolUse", #""agent_id":"a2","tool_name":"Read","tool_input":{"file_path":"/Users/test/proj/a.txt"},"tool_use_id":"toolu_2""#)
        let permA = hook("PermissionRequest", #""agent_id":"a1","tool_name":"Bash","tool_input":{"command":"rm -rf build"}"#)
        var par = reduce(signals([hook("UserPromptSubmit"), preA, preB, permA, #"{"hook_event_name":"PostToolUse","tool_use_id":"toolu_2"}"#]))
        check("status: a parallel subagent finishing doesn't clear Needs permission", par.activity == .needsPermission && par.detail == "Wants to run Bash: rm -rf build", par.detail)
        par = reduce(signals([#"{"hook_event_name":"PostToolUse","tool_use_id":"toolu_1"}"#]), from: par)
        check("status: the waiting call finishing clears it", par.activity == .working)

        // Seen in a real run: a background subagent ran `cat` right after the main Stop.
        let afterStop = reduce(hookTurn + signals([postBash, hook("Stop", #""last_assistant_message":"One file.""#),
            hook("PreToolUse", #""agent_id":"a3cd","tool_name":"Bash","tool_input":{"command":"cat hello.txt"},"tool_use_id":"toolu_S""#),
            #"{"hook_event_name":"PostToolUse","tool_use_id":"toolu_S"}"#]))
        check("status: a background subagent after Stop doesn't make the chat Working", afterStop.activity == .doneUnseen && afterStop.lastMessage == "One file.")
        let subPerm = reduce(signals([hook("PreToolUse", #""agent_id":"a3cd","tool_name":"Bash","tool_input":{"command":"touch x"},"tool_use_id":"toolu_T""#),
                                   hook("PermissionRequest", #""agent_id":"a3cd","tool_name":"Bash","tool_input":{"command":"touch x"}"#)]), from: afterStop)
        check("status: but its permission prompt still needs you", subPerm.activity == .needsPermission && subPerm.waits.first?.toolUseID == "toolu_T")
        check("status: and answering it goes back to Done", reduce(signals([#"{"hook_event_name":"PostToolUse","tool_use_id":"toolu_T"}"#]), from: subPerm).activity == .doneUnseen)

        let ask = hook("PreToolUse", #""tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database should I use?","options":[]}]},"tool_use_id":"toolu_Q""#)
        var q = reduce(signals([hook("UserPromptSubmit"), ask]))
        check("status: AskUserQuestion -> Needs answer", q.activity == .needsAnswer && q.detail == "Asks: Which database should I use?", q.detail)
        q = reduce(signals([#"{"hook_event_name":"PostToolUse","tool_use_id":"toolu_Q"}"#]), from: q)
        check("status: answering resumes Working", q.activity == .working)
        let plan = reduce(signals([hook("UserPromptSubmit"), hook("PreToolUse", #""tool_name":"ExitPlanMode","tool_input":{"plan":"1. x"},"tool_use_id":"toolu_P""#)]))
        check("status: plan approval -> Needs answer", plan.activity == .needsAnswer && plan.detail == "Plan ready for review")
        var fq = reduce(signals([hook("UserPromptSubmit"), hook("Stop", #""last_assistant_message":"Built it.\nShould I deploy it now?""#)]))
        check("status: a question in the final message -> Needs answer", fq.activity == .needsAnswer && fq.detail == "Asks: Should I deploy it now?", fq.detail)
        fq = reduce(signals([hook("UserPromptSubmit")]), from: fq)
        check("status: the next prompt clears it", fq.activity == .working)

        // A declined prompt and Esc: no hook fires, so the transcript says so.
        let decline = OriginSignal(origin: .transcript, signal: .declined(id: "toolu_A"))
        let esc = OriginSignal(origin: .transcript, signal: .interrupted)
        let declined = reduce(hookTurn + signals([permBash]) + [decline, esc])
        check("status: declined then interrupted -> Idle, Interrupted", declined.activity == .idle && declined.detail == "Interrupted", declined.detail)
        // Reader mode's Stop, once the agent's screen shows the turn stopped and nothing else said so.
        let readerStop = reduce(hookTurn + [OriginSignal(origin: .app, signal: .interrupted)])
        check("status: reader mode's confirmed Stop -> Idle, Interrupted", readerStop.activity == .idle && readerStop.detail == "Interrupted", readerStop.detail)

        // The late Notification hook doesn't duplicate a PermissionRequest or get stuck.
        let late = hook("Notification", #""message":"Claude needs your permission to use Bash","notification_type":"permission_prompt""#)
        var l = reduce(hookTurn + signals([permBash, late]))
        check("status: late permission_prompt adds nothing", l.waits.count == 1)
        l = reduce(signals([postBash]), from: l)
        check("status: and doesn't stick after the tool runs", l.activity == .working)
        let net = reduce(hookTurn + signals([late]))
        check("status: permission_prompt alone is the fallback", net.activity == .needsPermission && net.detail == "Claude needs your permission to use Bash")

        let failed = reduce(hookTurn + signals([hook("StopFailure", #""error":"rate_limit","last_assistant_message":"API Error: Rate limit reached""#)]))
        check("status: StopFailure -> Done with the error", failed.activity == .doneUnseen && failed.detail == "Stopped: API Error: Rate limit reached", failed.detail)
        let idleFix = reduce(hookTurn + signals([hook("Notification", #""message":"Claude is waiting for your input","notification_type":"idle_prompt""#)]))
        check("status: idle_prompt corrects a missed Stop", idleFix.activity == .doneUnseen)

        // Precedence between sources.
        let bell = OriginSignal(origin: .terminal, signal: .terminalNotice(text: nil))
        let progressOn = OriginSignal(origin: .terminal, signal: .progress(active: true))
        let progressOff = OriginSignal(origin: .terminal, signal: .progress(active: false))
        let withHooks = reduce(signals([hook("SessionStart")]) + [bell, progressOn])
        check("status: once hooks report, the bell and OSC 9;4 are ignored", withHooks.activity == .idle && withHooks.structured)
        let noHooks = reduce([progressOn])
        check("status: without hooks, OSC 9;4 means Working", noHooks.activity == .working)
        check("status: and its end means Done", reduce([progressOff], from: noHooks).activity == .doneUnseen)
        var other = reduce([bell], agent: .other)
        check("status: other agents: the bell means Needs answer", other.activity == .needsAnswer && other.detail == "Waiting for you")
        StatusReducer.markSeen(&other, ctx: StatusContext(agent: .other, focused: true))
        check("status: other agents: looking clears the bell", other.activity == .idle)

        // Codex: rollout, notify and OSC 9 together, with turn ids keeping them in step.
        func r(_ s: StatusSignal) -> OriginSignal { OriginSignal(origin: .transcript, signal: s) }
        func osc(_ t: String) -> OriginSignal { OriginSignal(origin: .terminal, signal: .terminalNotice(text: t)) }
        let notifyDone = OriginSignal(origin: .notify, signal: .codexTurnComplete(id: "t1", lastMessage: "Built."))
        var cx = reduce([r(.codexTurnStarted(id: "t1"))], agent: .codex)
        check("status: Codex task_started -> Working", cx.activity == .working)
        cx = reduce([osc("Approval requested: npm test")], agent: .codex, from: cx)
        check("status: Codex approval notification -> Needs permission", cx.activity == .needsPermission && cx.detail == "Wants to run npm test", cx.detail)
        cx = reduce([r(.toolStarted(id: nil, call: ToolCall(name: "shell", command: "ls", cwd: nil)))], agent: .codex, from: cx)
        check("status: Codex: a tool call alone doesn't clear it", cx.activity == .needsPermission)
        cx = reduce([r(.toolFinished(id: nil))], agent: .codex, from: cx)
        check("status: Codex: tool output resumes Working", cx.activity == .working)
        cx = reduce([notifyDone], agent: .codex, from: cx)
        let key = cx.headKey
        check("status: Codex notify -> Done", cx.activity == .doneUnseen && cx.lastMessage == "Built.")
        cx = reduce([r(.codexTurnComplete(id: "t1", lastMessage: "Built.")), r(.codexTurnStarted(id: "t1"))], agent: .codex, from: cx)
        check("status: Codex: the rollout's copy of the same turn end changes nothing", cx.activity == .doneUnseen && cx.headKey == key)
        var ooo = reduce([r(.codexTurnStarted(id: "t1")), r(.codexTurnComplete(id: "t1", lastMessage: nil)), r(.codexTurnStarted(id: "t2"))], agent: .codex)
        ooo = reduce([notifyDone], agent: .codex, from: ooo)
        check("status: Codex: a late notify for the last turn doesn't end the new one", ooo.activity == .working)
        let cxBell = reduce([r(.codexTurnStarted(id: "t1")), bell], agent: .codex)
        check("status: Codex: a bare bell is ignored", cxBell.activity == .working)

        // From a real Codex 0.160 run: the exec tool takes a script, and the approval
        // notification cuts the command short behind its shell wrapper.
        let execLine = #"{"timestamp":"t","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"c","name":"exec","input":"text(await tools.exec_command({cmd:\"touch hantuu-probe.txt\",sandbox_permissions:\"require_escalated\",max_output_tokens:1000}));\n"}}"#
        let execSig = CodexRolloutStatus.parse(Data(execLine.utf8), cwd: cwd)
        var real = reduce([r(.codexTurnStarted(id: "t1"))] + execSig, agent: .codex)
        check("status: Codex exec script -> Running touch hantuu-probe.txt", real.detail == "Running touch hantuu-probe.txt", real.detail)
        real = reduce([osc(" Approval requested: /bin/zsh -lc 'touch hantuu-...")], agent: .codex, from: real)
        check("status: Codex approval shows the whole command", real.activity == .needsPermission && real.detail == "Wants to run touch hantuu-probe.txt", real.detail)
        check("status: Codex approval without a known command is unwrapped", TerminalNoticeText.classify("Approval requested: /bin/zsh -lc 'npm test'").1 == "Wants to run npm test")

        let ended = { () -> StatusState in var s = reduce(hookTurn); s.ended = true; return reduce(signals([permBash]), from: s) }()
        check("status: Ended ignores everything", ended.activity == .ended && ended.detail == "Ended")
    }

    // MARK: Command lines

    static func statusArguments() {
        let json = AgentHooks.claudeSettingsJSON
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        let hooks = obj?["hooks"] as? [String: Any] ?? [:]
        check("settings: --settings JSON parses with only a hooks key", obj != nil && obj?.keys.sorted() == ["hooks"])
        check("settings: hooks every event bet 1 needs", Set(hooks.keys) == Set(AgentHooks.claudeEvents)
              && ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd"].allSatisfy { hooks[$0] != nil })
        var commands: [String] = []
        for (_, v) in hooks {
            for group in v as? [[String: Any]] ?? [] {
                check("settings: no matcher, so every tool and type is seen", group["matcher"] == nil)
                for h in group["hooks"] as? [[String: Any]] ?? [] {
                    if h["type"] as? String == "command", let c = h["command"] as? String { commands.append(c) }
                }
            }
        }
        check("settings: every hook only appends to $HANTUU_EVENTS and exits 0", commands.count == AgentHooks.claudeEvents.count
              && commands.allSatisfy { $0.contains(#">> "$HANTUU_EVENTS""#) && $0.hasSuffix("exit 0") })
        let lowered = json.lowercased()
        check("settings: the hooks never decide anything", !["permissiondecision", "\"decision\"", "\"allow\"", "\"deny\"", "updatedinput", "continue"].contains { lowered.contains($0) })

        let claude = AgentCatalog.definition("claude")
        let launch = claude.launchArguments(sessionID: "abc")
        check("launch: claude gets --settings with the hooks", launch.prefix(3) == ["claude", "--session-id", "abc"] && launch.dropFirst(3).first == "--settings" && launch.last == json)
        check("launch: claude resume keeps the hooks", claude.resumeArguments(sessionID: "abc") == ["claude", "--resume", "abc", "--settings", json])

        let felix = "model = \"gpt-6\"\nnotify = [\"/Apps/Sky Client.app/Contents/MacOS/Sky\", \"turn-ended\"]  # comment\n\n[tui]\nnotify = [\"not top level\"]\n"
        check("codex: reads the user's own notify", AgentHooks.parseNotify(toml: felix) == .found(["/Apps/Sky Client.app/Contents/MacOS/Sky", "turn-ended"]))
        check("codex: no notify key", AgentHooks.parseNotify(toml: "model = \"x\"\n[tui]\nnotify = [\"y\"]\n") == .none)
        check("codex: a notify it can't read safely is left alone", AgentHooks.parseNotify(toml: "notify = [\n  \"a\",\n]\n") == .unreadable
              && !AgentHooks.codexArguments(existingNotify: .unreadable).contains { $0.hasPrefix("notify=") })
        let cargs = AgentHooks.codexArguments(existingNotify: .found(["/Apps/Sky", "turn-ended"]))
        let notifyArg = cargs.first { $0.hasPrefix("notify=") } ?? ""
        let parsed = AgentHooks.parseStringArray(String(notifyArg.dropFirst("notify=".count)))
        check("codex: notify chains to the user's command", parsed == ["/bin/sh", "-c", AgentHooks.codexNotifyScript, "hantuu-notify", "/Apps/Sky", "turn-ended"], notifyArg)
        check("codex: OSC 9 notifications for approvals and questions", cargs.contains(#"tui.notifications=["approval-requested","plan-mode-prompt","async-question"]"#)
              && cargs.contains(#"tui.notification_method="osc9""#) && cargs.contains(#"tui.notification_condition="always""#))
        let codex = AgentCatalog.definition("codex")
        let cres = codex.resumeArguments(sessionID: "S") ?? []
        check("codex: resume passes the overrides before the session id", cres.first == "codex" && cres.dropFirst().first == "resume" && cres.last == "S" && cres.contains("-c"))
        let everything = AgentCatalog.known.flatMap { $0.launchArguments(sessionID: "x") + ($0.resumeArguments(sessionID: "x") ?? []) }.joined(separator: " ").lowercased()
        check("launch: still no permission-bypass flags anywhere", !["dangerously", "bypass", "--yolo", "full-auto", "skip-permissions", "approval_policy", "sandbox_mode", "never"].contains { everything.contains($0) })
    }

    // MARK: The hook commands, run for real

    @discardableResult
    static func sh(_ script: String, args: [String] = [], stdin: Data, env: [String: String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script] + args
        var e = ProcessInfo.processInfo.environment
        e["HANTUU_EVENTS"] = nil
        for (k, v) in env { e[k] = v }
        p.environment = e
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        DispatchQueue.global().async {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    static func statusHookCommands(_ dir: URL) {
        let events = dir.appendingPathComponent("hook-events.jsonl")
        let env = ["HANTUU_EVENTS": events.path]
        let pre = Data(preBash.utf8)
        let (code, out) = sh(AgentHooks.claudeCommand(for: "PreToolUse"), stdin: pre, env: env)
        let written = (try? String(contentsOf: events, encoding: .utf8)) ?? ""
        check("hook: appends the event as one line, prints nothing, exits 0", code == 0 && out.isEmpty && written == preBash + "\n", "code=\(code) out=\(out) written=\(written.prefix(120))")

        // PostToolUse: the output is dropped, the right tool_use_id kept, even when the
        // output itself mentions a tool_use_id.
        let big = String(repeating: "x", count: 300_000)
        let post = hook("PostToolUse", #""tool_name":"Read","tool_input":{"file_path":"/a"},"tool_response":{"content":"\"tool_use_id\":\"toolu_FAKE\" \#(big)","nested":{"tool_use_id":"toolu_NESTED"}},"tool_use_id":"toolu_REAL","duration_ms":3"#)
        try? FileManager.default.removeItem(at: events)
        let (c2, o2) = sh(AgentHooks.claudeCommand(for: "PostToolUse"), stdin: Data(post.utf8), env: env)
        let compact = (try? String(contentsOf: events, encoding: .utf8)) ?? ""
        check("hook: PostToolUse cut down to the event and its tool_use_id", c2 == 0 && o2.isEmpty && compact == #"{"hook_event_name":"PostToolUse","tool_use_id":"toolu_REAL"}"# + "\n", compact)

        try? FileManager.default.removeItem(at: events)
        let (c3, _) = sh(AgentHooks.claudeCommand(for: "Stop"), stdin: Data(hook("Stop").utf8), env: [:])
        check("hook: without HANTUU_EVENTS it writes nothing and still exits 0", c3 == 0 && !FileManager.default.fileExists(atPath: events.path))
        let (c4, _) = sh(AgentHooks.claudeCommand(for: "Stop"), stdin: Data(hook("Stop").utf8), env: ["HANTUU_EVENTS": dir.appendingPathComponent("missing/dir/x.jsonl").path])
        check("hook: an unwritable events file still exits 0", c4 == 0)

        // Parallel hooks (subagents) each land as one whole line.
        try? FileManager.default.removeItem(at: events)
        let group = DispatchGroup()
        for i in 0..<12 {
            group.enter()
            DispatchQueue.global().async {
                let payload = hook("PreToolUse", #""tool_name":"Write","tool_input":{"file_path":"/f\#(i)","content":"\#(String(repeating: "y", count: 40_000 + i))"},"tool_use_id":"toolu_\#(i)""#)
                sh(AgentHooks.claudeCommand(for: "PreToolUse"), stdin: Data(payload.utf8), env: env)
                group.leave()
            }
        }
        group.wait()
        let lines = ((try? String(contentsOf: events, encoding: .utf8)) ?? "").split(separator: "\n")
        let parsedOK = lines.allSatisfy { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil }
        check("hook: 12 concurrent 40 KB hooks give 12 whole lines", lines.count == 12 && parsedOK, "lines=\(lines.count) ok=\(parsedOK)")

        // Codex notify: written to the events file, then the user's own notify still runs.
        try? FileManager.default.removeItem(at: events)
        let seen = dir.appendingPathComponent("user-notify-args.txt")
        let userNotify = dir.appendingPathComponent("user-notify.sh")
        try? "#!/bin/sh\nprintf '%s|' \"$@\" > \"\(seen.path)\"\n".write(to: userNotify, atomically: true, encoding: .utf8)
        chmod(userNotify.path, 0o755)
        let payload = #"{"type":"agent-turn-complete","turn-id":"t9","last-assistant-message":"ok"}"#
        let (c5, _) = sh(AgentHooks.codexNotifyScript, args: ["hantuu-notify", userNotify.path, "turn-ended", payload], stdin: Data(), env: env)
        let notified = (try? String(contentsOf: events, encoding: .utf8)) ?? ""
        let userGot = (try? String(contentsOf: seen, encoding: .utf8)) ?? ""
        check("codex notify: event written to HANTUU_EVENTS", c5 == 0 && notified == payload + "\n", notified)
        check("codex notify: the user's notify still gets the same arguments", userGot == "turn-ended|\(payload)|", userGot)
        try? FileManager.default.removeItem(at: events)
        let (c6, _) = sh(AgentHooks.codexNotifyScript, args: ["hantuu-notify", payload], stdin: Data(), env: env)
        check("codex notify: works with no user notify", c6 == 0 && ((try? String(contentsOf: events, encoding: .utf8)) ?? "") == payload + "\n")
    }

    // MARK: The engine end to end

    final class NoticeRecorder: AttentionNotifying {
        var posted: [AttentionNotice] = []
        var withdrawn: [UUID] = []
        func prepare() {}
        func post(_ notice: AttentionNotice) { posted.append(notice) }
        func withdraw(chatID: UUID) { withdrawn.append(chatID) }
    }

    static func statusEngine(_ dir: URL) {
        let model = AppModel()
        let project = Project(path: cwd)
        model.projects = [project]
        let center = StatusCenter()
        let rec = NoticeRecorder()
        var active = false
        center.notifier = rec
        center.appIsActive = { active }
        center.start(model: model, live: false)

        let a = Chat(projectID: project.id, agentID: "claude")
        a.terminalTitle = "Fix the login redirect"
        let b = Chat(projectID: project.id, agentID: "claude")
        b.terminalTitle = "Tidy the README"
        model.chats = [a, b]
        let fileA = AgentHooks.eventsFile(for: a.id), fileB = AgentHooks.eventsFile(for: b.id)
        func append(_ url: URL, _ lines: [String]) {
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            h.seekToEndOfFile()
            h.write(Data(lines.map { $0 + "\n" }.joined().utf8))
            try? h.close()
        }
        check("engine: a new chat starts Idle", a.activity == .idle && center.attention.isEmpty)
        check("engine: the chat environment points at its events file", AgentHooks.environment(for: a.id)["HANTUU_EVENTS"] == fileA.path)

        append(fileA, [hook("SessionStart"), hook("UserPromptSubmit"), preBash])
        center.poll()
        check("engine: hook lines move the chat to Working", a.activity == .working && a.activityDetail == "Running Bash: npm test", a.activityDetail)
        append(fileA, [permBash])
        center.poll()
        check("engine: Needs permission, with one notification quoting the command", a.activity == .needsPermission && rec.posted.count == 1
              && rec.posted.first?.title == "Fix the login redirect in proj" && rec.posted.first?.body == "Wants to run Bash: npm test", "\(rec.posted)")
        center.poll()
        check("engine: no duplicate notification for the same state", rec.posted.count == 1)

        // The second chat finishes later than the first started needing you.
        append(fileB, [hook("UserPromptSubmit"), hook("Stop", #""last_assistant_message":"Cleaned up.\n\nThe README now has a **Get started** section.""#)])
        center.poll()
        check("engine: Done notification quotes the last line", b.activity == .doneUnseen && rec.posted.last?.body == "The README now has a Get started section." && rec.posted.last?.isDone == true, "\(String(describing: rec.posted.last))")
        check("engine: needs-you order is Needs first, then Done", center.attention == [a.id, b.id])

        center.settings.notifyWhenDone = false
        append(fileB, [hook("UserPromptSubmit"), hook("Stop", #""last_assistant_message":"Again.""#)])
        center.poll()
        check("engine: the Done switch turns Done notifications off", rec.posted.count == 2 && b.activity == .doneUnseen)
        center.settings.notifyWhenDone = true

        // Looking at a chat: Done becomes Idle, Needs stays.
        active = true
        model.selectedChatID = b.id
        check("engine: selecting a Done chat makes it Idle and withdraws its notification", b.activity == .idle && rec.withdrawn.contains(b.id))
        model.selectedChatID = a.id
        check("engine: selecting a Needs chat keeps it Needs", a.activity == .needsPermission)
        let before = rec.posted.count
        append(fileA, [postBash, hook("PreToolUse", #""tool_name":"Bash","tool_input":{"command":"git push"},"tool_use_id":"toolu_C""#),
                       hook("PermissionRequest", #""tool_name":"Bash","tool_input":{"command":"git push"}"#)])
        center.poll()
        check("engine: no notification for the chat you're looking at", a.activity == .needsPermission && rec.posted.count == before)

        // Cmd-J: oldest first, skipping the chat you're on.
        active = false
        append(fileB, [hook("UserPromptSubmit"), hook("Stop", #""last_assistant_message":"Shall I commit?""#)])
        center.poll()
        model.selectedChatID = a.id
        center.jumpToNext()
        check("engine: Cmd-J jumps to the next chat that needs you", model.selectedChatID == b.id)

        // Ended, then removed.
        a.status = .ended
        check("engine: process exit -> Ended", a.activity == .ended && a.activityDetail == "Ended")
        a.status = .running
        check("engine: resume starts fresh", a.activity == .idle)
        model.chats = [a]
        check("engine: removing a chat drops its events file", !FileManager.default.fileExists(atPath: fileB.path))

        // A session that outlived the app comes back from its events file, quietly.
        let c = Chat(projectID: project.id, agentID: "claude")
        append(AgentHooks.eventsFile(for: c.id), [hook("SessionStart"), hook("UserPromptSubmit"), permBash])
        let model2 = AppModel()
        model2.projects = [project]
        model2.chats = [c]
        let center2 = StatusCenter()
        let rec2 = NoticeRecorder()
        center2.notifier = rec2
        center2.appIsActive = { false }
        center2.start(model: model2, live: false)
        check("engine: a running chat found at launch replays its state without notifying", c.activity == .needsPermission && rec2.posted.isEmpty)
    }

    // MARK: Snapshots

    static func statusSnapshots(_ dir: URL) {
        let out = dir.deletingLastPathComponent().appendingPathComponent("snapshots", isDirectory: true)
        Paths.ensure(out)
        Theme.configure(from: GhosttyApp.shared)
        ActivityDot.fixedPhase = 0.45
        defer { ActivityDot.fixedPhase = nil }

        let model = AppModel()
        let hantuu = Project(path: "/Users/test/hantuu")
        let notes = Project(path: "/Users/test/notes")
        model.projects = [hantuu, notes]
        let now = Date()
        func chat(_ p: Project, _ agent: String, _ title: String, _ act: AgentActivity, _ detail: String, done: TimeInterval? = nil, since: TimeInterval = 0) -> Chat {
            let c = Chat(projectID: p.id, agentID: agent)
            c.terminalTitle = title
            c.activity = act
            c.activityDetail = detail
            c.activitySince = now.addingTimeInterval(-since)
            c.lastTurnEndedAt = done.map { now.addingTimeInterval(-$0) }
            if act == .ended { c.status = .ended }
            return c
        }
        let chats = [
            chat(hantuu, "claude", "Status dots and notifications", .working, "Running Bash: swift build"),
            chat(hantuu, "claude", "Fix the flaky reader test", .needsPermission, "Wants to run Bash: npm test", since: 300),
            chat(hantuu, "codex", "Pick a store for sessions", .needsAnswer, "Asks: Which database should I use?", since: 120),
            chat(hantuu, "claude", "Tidy the README", .doneUnseen, "", done: 125, since: 125),
            chat(notes, "claude", "Summarise this week", .idle, "", done: 840),
            chat(notes, "codex", "Rename the screenshots", .ended, "Ended"),
        ]
        model.chats = chats
        model.selectedChatID = chats[0].id
        StatusCenter.shared.preview(model: model)
        check("snapshot: needs-you list has the three that need you", StatusCenter.shared.attention.count == 3)

        let w = makeWindow()
        w.appearance = NSAppearance(named: .darkAqua)
        func render<V: View>(_ view: V, size: NSSize, name: String, dark: Bool = true) -> Bool {
            let host = NSHostingView(rootView: AnyView(view.environmentObject(model).environment(\.colorScheme, dark ? .dark : .light)))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: size)
            w.contentView?.addSubview(host)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            defer { host.removeFromSuperview() }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return false }
            let url = out.appendingPathComponent(name)
            return (try? png.write(to: url)) != nil
        }
        let s1 = render(SidebarView(), size: NSSize(width: 260, height: 430), name: "status-sidebar.png")
        let s2 = render(SidebarView(), size: NSSize(width: 200, height: 430), name: "status-sidebar-narrow.png")
        let list = NeedsYouList(now: now) {}
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: NSColor(white: 0.17, alpha: 1)))
        let s3 = render(list, size: NSSize(width: 300, height: 190), name: "status-needs-you-list.png")
        let legend = VStack(alignment: .leading, spacing: 10) {
            ForEach(AgentActivity.allCases, id: \.self) { a in
                HStack(spacing: 9) {
                    ActivityDot(activity: a)
                    Text(a.label).font(.system(size: 12)).foregroundStyle(Color.hSecondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.hChrome)
        let s4 = render(legend, size: NSSize(width: 180, height: 200), name: "status-dots.png")
        let settings = Form { NotificationSettingsSection() }.formStyle(.grouped)
        let s5 = render(settings, size: NSSize(width: 520, height: 190), name: "status-settings.png")
        let s6 = render(SidebarView(), size: NSSize(width: 260, height: 430), name: "status-sidebar-light.png", dark: false)
        let appearance = Form { AppearanceSettingsSection() }.formStyle(.grouped)
        let s7 = render(appearance, size: NSSize(width: 520, height: 120), name: "settings-appearance-light.png", dark: false)
        check("snapshot: sidebar, narrow sidebar, needs-you list, dots and settings written to \(out.path)", s1 && s2 && s3 && s4 && s5)
        check("snapshot: light sidebar and the Appearance setting", s6 && s7)
    }
}
