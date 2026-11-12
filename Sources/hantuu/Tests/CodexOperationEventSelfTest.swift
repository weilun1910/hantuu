import Foundation

extension SelfTest {
    static func codexCompletedItems() {
        func record(_ type: String, _ payload: [String: Any]) -> Data {
            try! JSONSerialization.data(withJSONObject: ["type": type, "timestamp": "2026-11-11T12:00:01Z", "payload": payload])
        }
        func event(_ item: [String: Any], thread: String = "fixture-thread") -> Data {
            record("event_msg", ["type": "item_completed", "thread_id": thread, "turn_id": "fixture-turn",
                                 "started_at_ms": 1794398400000, "completed_at_ms": 1794398401000, "item": item])
        }
        var parser = CodexTranscriptParser()
        let wrapper = parser.parse(line: record("response_item", ["type": "custom_tool_call", "name": "exec",
            "call_id": "wrapper", "input": "const result = await tools.exec_command({cmd: 'fixture'}); text(result.output);"]))
        let success: [String: Any] = ["type": "CommandExecution", "id": "exec-ok", "process_id": "14",
            "command": ["/bin/zsh", "-lc", "printf fixture-output"], "status": "completed",
            "aggregated_output": "fixture-output\n", "exit_code": 0, "duration": ["secs": 0, "nanos": 500000000]]
        let good = parser.parse(line: event(success))
        check("evidence: completed command item retains stdout and exit", good.count == 1 &&
              good.first?.operation?.output == "fixture-output\n" && good.first?.operation?.exitCode == 0 &&
              good.first?.operation?.state == "completed" && good.first?.operation?.command == "printf fixture-output")
        check("evidence: completed item retains provider timing", good.first?.operation?.duration == 0.5 &&
              good.first?.operation?.startedAt != nil && good.first?.operation?.finishedAt != nil)
        var failure = success
        failure["id"] = "exec-fail"; failure["process_id"] = "15"; failure["status"] = "failed"
        failure["aggregated_output"] = "fixture-failure\n"; failure["exit_code"] = 7
        let bad = parser.parse(line: event(failure))
        let finished = parser.parse(line: record("response_item", ["type": "custom_tool_call_output", "call_id": "wrapper",
            "output": [["type": "input_text", "text": "fixture-output\n"],
                       ["type": "input_text", "text": "{\"output\":\"fixture-failure\",\"exit_code\":7}"]]]))
        let merged = ReaderEntries.merging(wrapper + good + bad, finished)
        check("evidence: mixed wrapper retains separate successful and failed commands", merged.count == 3 &&
              merged.contains { $0.operation?.id == "exec-ok" && $0.operation?.state == "completed" } &&
              merged.contains { $0.operation?.id == "exec-fail" && $0.operation?.exitCode == 7 } &&
              merged.contains { $0.operation?.id == "wrapper" && $0.operation?.state == "failed" })
        let replayed = ReaderEntries.merging(merged, parser.parse(line: event(success)))
        check("evidence: completed item replay replaces the same card", replayed.count == merged.count)
        let otherThread = parser.parse(line: event(success, thread: "other-thread"))
        check("evidence: completed item identity includes its thread", otherThread.first?.id != good.first?.id)

        let path = "/project/fixture.txt"
        let patch: [String: Any] = ["type": "FileChange", "id": "patch-update", "status": "completed",
            "changes": [path: ["type": "update", "unified_diff": "@@ -1 +1 @@\n-before-fixture\n+after-fixture\n", "move_path": NSNull()]],
            "stdout": "Success. Updated fixture.txt", "stderr": ""]
        let edit = parser.parse(line: event(patch)).first
        check("evidence: completed file item retains historical diff", edit?.operation?.state == "completed" &&
              edit?.operation?.patch?.contains("-before-fixture\n+after-fixture") == true && edit?.files == [path])
        let added = parser.parse(line: event(["type": "FileChange", "id": "patch-add", "status": "completed",
            "changes": [path: ["type": "add", "content": "before-fixture\n"]]])).first
        check("evidence: completed add item retains recorded content", added?.operation?.patch == "*** Add File: \(path)\n+before-fixture")
        let deleted = parser.parse(line: event(["type": "FileChange", "id": "patch-delete", "status": "failed",
            "changes": [path: ["type": "delete"]], "stderr": "Denied fixture"])).first
        check("evidence: failed delete never invents old contents", deleted?.operation?.state == "failed" &&
              deleted?.operation?.patch == "*** Delete File: \(path)" && deleted?.operation?.patchNote != nil)
        var unknown = success
        unknown.removeValue(forKey: "status")
        check("evidence: completed envelope alone does not assert success", parser.parse(line: event(unknown)).first?.operation?.state == "unknown")
        check("evidence: unrelated completed item stays hidden", parser.parse(line: event(["type": "Unknown", "id": "ignored"])).isEmpty)
        var side = CodexTranscriptParser(scope: .side)
        check("evidence: side fork excludes copied completion events", side.parse(line: event(success)).isEmpty)

        var running = CodexTranscriptParser()
        _ = running.parse(line: record("response_item", ["type": "function_call", "name": "exec_command", "call_id": "direct",
            "arguments": "{\"cmd\":\"fixture\"}"]))
        let started = running.parse(line: record("response_item", ["type": "function_call_output", "call_id": "direct",
            "output": "Process running with session ID 14\ninitial output"]))
        let ended = ReaderEntries.merging(started, running.parse(line: event(success)))
        check("evidence: native completion updates known running command once", ended.count == 1 &&
              ended.first?.operation?.id == "direct" && ended.first?.operation?.state == "completed" &&
              ended.first?.operation?.output == "fixture-output\n")

        let old = ReaderEntry(id: "same", kind: .tool, text: "Old")
        let new = ReaderEntry(id: "same", kind: .tool, text: "New")
        check("evidence: merging canonicalizes older duplicate updates", ReaderEntries.merging([old, new], []) == [new])
    }
}
