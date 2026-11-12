import AppKit

extension SelfTest {
    static func readerEvidence() {
        func data(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
        func claude(_ type: String, _ blocks: [[String: Any]], extra: [String: Any] = [:]) -> Data {
            var o: [String: Any] = ["type": type, "uuid": UUID().uuidString, "sessionId": "synthetic-session", "timestamp": "2026-11-11T12:00:00Z", "message": ["content": blocks]]
            o.merge(extra) { _, new in new }; return data(o)
        }
        func call(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] { ["type": "tool_use", "id": id, "name": name, "input": input] }
        func result(_ id: String, _ text: String, failed: Bool = false) -> [String: Any] { ["type": "tool_result", "tool_use_id": id, "content": text, "is_error": failed] }
        var c = ClaudeTranscriptParser()
        let requested = c.parse(line: claude("assistant", [call("bash-1", "Bash", ["command": "printf fixture"])]))
        check("evidence: Claude command starts requested", requested.first?.operation?.state == "requested" && requested.first?.operation?.command == "printf fixture")
        let finished = c.parse(line: claude("user", [result("bash-1", "fixture")]))
        let merged = ReaderEntries.merging(requested, finished)
        check("evidence: success updates the same invocation", merged.count == 1 && merged.first?.id == requested.first?.id && merged.first?.operation?.state == "completed" && merged.first?.operation?.output == "fixture")
        _ = c.parse(line: claude("assistant", [call("bash-2", "Bash", ["command": "false"])]))
        check("evidence: Claude error retains output", c.parse(line: claude("user", [result("bash-2", "fixture failed", failed: true)])).first?.operation?.state == "failed")
        _ = c.parse(line: claude("assistant", [call("bash-3", "Bash", ["command": "fixture"])]))
        check("evidence: declined operation never succeeds", c.parse(line: claude("user", [result("bash-3", "The user rejected this action", failed: true)])).first?.operation?.state == "declined")
        let edit = c.parse(line: claude("assistant", [call("edit", "Edit", ["file_path": "fixture.swift", "old_string": "let old = 1", "new_string": "let new = 2"])]))
        check("evidence: Edit retains historical replacement", edit.first?.operation?.patch?.contains("-let old = 1") == true && edit.first?.operation?.patch?.contains("+let new = 2") == true)
        let multi = c.parse(line: claude("assistant", [call("multi", "MultiEdit", ["file_path": "fixture.swift", "edits": [["old_string": "one", "new_string": "two"], ["old_string": "three", "new_string": "four"]]])]))
        check("evidence: MultiEdit retains every replacement", multi.first?.operation?.patch?.contains("-one") == true && multi.first?.operation?.patch?.contains("+four") == true)
        let thinking = c.parse(line: claude("assistant", [["type": "thinking", "thinking": "Published fixture reasoning"], ["type": "redacted_thinking", "data": "opaque-not-displayable"]]))
        check("evidence: only published Claude reasoning retained", thinking.filter { $0.kind == .reasoning }.map(\.text) == ["Published fixture reasoning"])
        let child = c.parse(line: claude("assistant", [call("child", "Bash", ["command": "child only"])], extra: ["isSidechain": true]))
        check("evidence: parent excludes sidechain calls", child.isEmpty)

        func cx(_ payload: [String: Any]) -> Data { data(["type": "response_item", "timestamp": "2026-11-11T12:00:01Z", "payload": payload]) }
        var x = CodexTranscriptParser()
        let script = "text(await tools.exec_command({cmd:'printf fixture'}));"
        let xcall = x.parse(line: cx(["type": "function_call", "call_id": "exec-1", "name": "functions.exec", "arguments": script]))
        check("evidence: exec wrapper retains full script", xcall.first?.operation?.command == script)
        let xout = x.parse(line: cx(["type": "function_call_output", "call_id": "exec-1", "output": "{\"exit_code\":7,\"output\":\"fixture failure\"}"]))
        check("evidence: Codex wrapper nonzero is failed", xout.first?.operation?.state == "failed" && xout.first?.operation?.exitCode == 7)
        check("evidence: Codex output replaces call", ReaderEntries.merging(xcall, xout).count == 1)
        let patch = "*** Begin Patch\n*** Update File: fixture.swift\n@@\n-old\n+new\n*** End Patch"
        let patchCall = x.parse(line: cx(["type": "custom_tool_call", "call_id": "patch-1", "name": "apply_patch", "input": patch]))
        check("evidence: Codex patch retained verbatim", patchCall.first?.operation?.patch == patch)
        let literal = String(decoding: try! JSONEncoder().encode(patch), as: UTF8.self)
        let wrappedPatch = x.parse(line: cx(["type": "custom_tool_call", "call_id": "wrapped-patch", "name": "functions.exec", "input": "text(await tools.apply_patch(\(literal)));" ]))
        check("evidence: wrapper patch literal retained without evaluation", wrappedPatch.first?.operation?.patch == patch && wrappedPatch.first?.operation?.patchNote?.contains("whole invocation") == true)
        check("evidence: computed patches are not invented", ReaderEvidence.literalPatches("await tools.apply_patch(computedPatch)").isEmpty)
        let patchDone = x.parse(line: cx(["type": "custom_tool_call_output", "call_id": "patch-1", "output": "Success. Updated fixture.swift"]))
        check("evidence: patch result preserves patch identity", patchDone.first?.id == patchCall.first?.id && patchDone.first?.operation?.patch == patch)
        let q = ReaderEvidence.json(["questions": [["id": "pick", "question": "Which view?", "options": [["label": "Reader", "description": "Readable history"]]]]])
        let question = x.parse(line: cx(["type": "function_call", "call_id": "q1", "name": "functions.request_user_input", "arguments": q]))
        check("evidence: Codex structured question is readable", question.first?.kind == .question && question.first?.text.contains("Which view?") == true && question.first?.text.contains("Readable history") == true)
        let reasoning = x.parse(line: cx(["type": "reasoning", "id": "r1", "summary": [["type": "summary_text", "text": "Published summary"]], "encrypted_content": "opaque-not-displayable"]))
        check("evidence: Codex published reasoning only", reasoning.first?.kind == .reasoning && reasoning.first?.text == "Published summary")
        let orphan = x.parse(line: cx(["type": "function_call_output", "call_id": "orphan", "output": "Retained result without earlier call"]))
        check("evidence: orphan result survives history tail", orphan.first?.operation?.output == "Retained result without earlier call")
        check("evidence: native exec output detects truncation", ReaderEvidence.outcome("Process exited with code 2\nWarning: 100 tokens truncated", metadata: nil).exitCode == 2 && ReaderEvidence.outcome("Output truncated", metadata: nil).truncated)
        codexCompletedItems()
    }

    static func readerEvidenceLifetimes() {
        func line(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        func cx(_ payload: [String: Any]) -> Data { line(["type": "response_item", "payload": payload]) }
        var parser = CodexTranscriptParser()
        _ = parser.parse(line: line(["type": "session_meta", "payload": ["id": "first-session"]]))
        _ = parser.parse(line: cx(["type": "function_call", "call_id": "reused", "name": "exec_command", "arguments": "{\"cmd\":\"first-session-command\"}"]))
        _ = parser.parse(line: line(["type": "session_meta", "payload": ["id": "second-session"]]))
        let orphan = parser.parse(line: cx(["type": "function_call_output", "call_id": "reused", "output": "second-session-result"]))
        check("evidence: session change cannot borrow old command", orphan.first?.id.contains("second-session") == true && orphan.first?.operation?.command == nil)
        let wrapper = ReaderEvidence.outcome("{\"exit_code\":9,\"output\":\"failed\"}\n{\"exit_code\":0,\"output\":\"passed\"}", metadata: nil)
        check("evidence: later wrapper success does not erase failure", wrapper.exitCode == 9)
        _ = parser.parse(line: cx(["type": "function_call", "call_id": "process", "name": "exec_command", "arguments": "{\"cmd\":\"long-fixture\"}"]))
        var running = parser.parse(line: cx(["type": "function_call_output", "call_id": "process", "output": "Process running with session ID 414\ninitial output"]))
        _ = parser.parse(line: cx(["type": "function_call", "call_id": "poll", "name": "write_stdin", "arguments": "{\"session_id\":414,\"chars\":\"\"}"]))
        let completion = parser.parse(line: cx(["type": "function_call_output", "call_id": "poll", "output": "Process exited with code 0\nfinal output"]))
        running = ReaderEntries.merging(running, completion)
        check("evidence: write_stdin completes original operation", running.first(where: { $0.operation?.id == "process" })?.operation?.state == "completed")
        check("evidence: process completion replaces every stale update", running.filter { $0.operation?.id == "process" }.count == 1 &&
              running.first(where: { $0.operation?.id == "process" })?.operation?.output?.contains("initial output") == true &&
              running.first(where: { $0.operation?.id == "process" })?.operation?.output?.contains("final output") == true)
        var side = CodexTranscriptParser(scope: .side)
        check("evidence: side fork excludes copied tool history", side.parse(line: cx(["type": "function_call", "call_id": "parent", "name": "exec_command", "arguments": "{\"cmd\":\"private-parent-command\"}"])).isEmpty)
        check("evidence: side fork excludes copied reasoning", side.parse(line: cx(["type": "reasoning", "summary": [["text": "Parent summary"]]])).isEmpty)
    }

    static func readerHealthFixtures(_ dir: URL) {
        let root = dir.appendingPathComponent("reader-health-fixtures", isDirectory: true)
        Paths.ensure(root)
        let url = root.appendingPathComponent("synthetic.jsonl")
        try? FileManager.default.removeItem(at: url)
        let follower = TranscriptFollower(url: url, kind: .claude, baseDir: root.path)
        follower.poll()
        check("reader health: missing file is explicit", follower.health == .missing && follower.entries.isEmpty)
        let record = #"{"type":"assistant","uuid":"health-fixture","message":{"content":[{"type":"text","text":"Retained synthetic answer"}]}}"#
        try? Data((record + "\n").utf8).write(to: url)
        follower.poll()
        check("reader health: complete record becomes ready", follower.health == .connected && follower.entries.count == 1)
        let before = follower.entries
        try? FileManager.default.removeItem(at: url)
        follower.poll()
        check("reader health: missing file preserves readable history", follower.health == .missing && follower.entries == before)
        try? Data((record + "\n{\"type\":").utf8).write(to: url)
        follower.poll()
        check("reader health: partial record preserves history", follower.health == .incomplete && follower.entries == before)
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd(); try? handle.write(contentsOf: Data("\"unknown\"}\nnot-json\n".utf8)); try? handle.close()
        }
        follower.poll()
        check("reader health: malformed record is visible without losing history", follower.health == .malformed && follower.entries == before)
        try? Data((record + "\n").utf8).write(to: url)
        follower.retry()
        check("reader health: retry recovers valid fixture", waitUntil(5) { follower.health == .connected && follower.entries.count == 1 })
        check("reader health: retry preserves one stable message", follower.entries.first?.text == "Retained synthetic answer")
        follower.stop()
    }

    static func readerEvidenceRendering(_ dir: URL) {
        guard Paths.webRoot != nil else { check("reader parity: web assets present", false); return }
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 760, height: 700))
        let page = WebPage(page: "reader.html?layout=main", identifier: "selftest.reader-parity")
        page.webView.frame = NSRect(x: 0, y: 0, width: 760, height: 700)
        window.contentView?.addSubview(page.webView)
        guard waitUntil(10, { page.ready }) else { check("reader parity: page ready", false); return }
        let out = snapshotDir(dir); Paths.ensure(out)
        let cases: [(String, String)] = [
            ("command-output-failure", #"[{id:'command',kind:'tool',text:'Run fixture checks',operation:{id:'call',name:'exec_command',provider:'codex',arguments:'',command:'swift test --filter ReaderFixtures',output:'Fixture failed: expected a retained result.\nProcess exited with code 1',state:'failed',exitCode:1}}]"#),
            ("historical-patch", #"[{id:'patch',kind:'tool',text:'Recorded replacement',files:['fixture.swift'],operation:{id:'edit',name:'Edit',provider:'claude',arguments:'',patch:'--- fixture.swift\n+++ fixture.swift\n@@ Recorded replacement @@\n-oldValue\n+newValue',output:'Updated fixture.swift',state:'completed'}}]"#),
            ("checklist", #"[{id:'plan',kind:'checklist',text:'Execution checklist',checklist:{state:'active',items:[{id:'1',text:'Retain operation output',status:'completed'},{id:'2',text:'Verify failure states',status:'in_progress'},{id:'3',text:'Review both appearances',status:'pending'}]}}]"#),
            ("delegated-work", #"[{id:'agent',kind:'tool',text:'Review reader fixtures',operation:{id:'agent-call',name:'Agent',provider:'claude',arguments:'Inspect synthetic fixtures',state:'completed',childID:'fixture-agent',report:'Confirmed that failures remain visible and the patch retains its original content.',duration:8.5}}]"#),
            ("published-reasoning", #"[{id:'reasoning',kind:'reasoning',text:'Published fixture reasoning explaining the next verification step.'}]"#),
            ("find-retained-output", #"[{id:'find',kind:'tool',text:'Search fixture',operation:{id:'find-call',name:'Bash',provider:'claude',arguments:'',command:'printf fixture',output:'The hidden needle remains searchable.',state:'completed'}}]"#),
            ("reader-health", "[]"),
            ("permission-request", "[]"),
            ("question-request", "[]")
        ]
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (NSAppearance.Name.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance)
            for (feature, entries) in cases {
                _ = js(page, "ReaderParity.closeFind(); ReaderParity.setRequests([]); ReaderParity.setStatus({state:'ready'}); window.hantuu.reset({chatID:'snapshot-\(name)-\(feature)',entries:\(entries),emptyText:''}); 0")
                if feature == "reader-health" { _ = js(page, "ReaderParity.setStatus({state:'unavailable',message:'This conversation could not be refreshed. Its retained history is still available.'}); 0") }
                if feature == "permission-request" {
                    _ = js(page, #"ReaderParity.setRequests([{id:'permission-fixture',tool:'Bash',sessionID:'fixture',inputJSON:JSON.stringify({command:'swift test --filter ReaderFixtures',description:'Run isolated fixture checks'})}]); 0"#)
                }
                if feature == "question-request" {
                    _ = js(page, #"ReaderParity.setRequests([{id:'question-fixture',tool:'AskUserQuestion',sessionID:'fixture',inputJSON:JSON.stringify({questions:[{question:'Which view should open?',header:'View',options:[{label:'Reader',description:'Readable conversation'},{label:'Terminal',description:'Native agent controls'}],multiSelect:false}]})}]); 0"#)
                }
                if feature == "find-retained-output" {
                    _ = js(page, "ReaderParity.openFind(); var fixtureField=document.querySelector('.reader-find input'); if(fixtureField){fixtureField.value='needle';fixtureField.dispatchEvent(new Event('input'));} 0")
                } else { _ = js(page, "document.querySelectorAll('details').forEach(d=>d.open=true); 0") }
                _ = js(page, "document.scrollingElement.scrollTop=0; 0")
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                check("snapshot: reader \(feature) \(name)", render(page.webView, to: out.appendingPathComponent("reader-\(feature)-\(name).png")))
            }
        }
    }
}
