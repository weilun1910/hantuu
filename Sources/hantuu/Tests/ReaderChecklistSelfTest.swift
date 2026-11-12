import Foundation

extension SelfTest {
    /// Sanitized provider envelopes; Claude result bodies match installed 2.1.322 mappings.
    static func readerChecklist() {
        func line(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        func call(_ id: String, _ name: String, _ input: [String: Any]) -> Data {
            line(["type": "assistant", "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
        }
        func result(_ id: String, _ text: String, _ structured: [String: Any] = [:], error: Bool = false) -> Data {
            line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": text, "is_error": error]]], "toolUseResult": structured])
        }
        var c = ReaderChecklistReducer(kind: .claude)
        c.consume(line: call("create", "TaskCreate", ["subject": "Inspect parser"]))
        check("checklist: no invented creation ID", c.current?.items.isEmpty == true && c.current?.state == "unconfirmed")
        c.consume(line: result("create", "Task #17 created successfully: Inspect parser", ["task": ["id": "17", "subject": "Inspect parser"]]))
        check("checklist: confirmed task creation", c.current?.items.first?.id == "17" && c.current?.state == "active")
        c.consume(line: call("fail", "TaskUpdate", ["taskId": "17", "status": "completed"]))
        c.consume(line: result("fail", "Task not found", ["success": false]))
        check("checklist: failed mutation preserves confirmed status", c.current?.items.first?.status == "pending" && c.current?.state == "unconfirmed")
        c.consume(line: call("update", "TaskUpdate", ["taskId": "17", "status": "completed", "subject": "Unconfirmed rename"]))
        c.consume(line: result("update", "Updated task #17 status", ["success": true, "taskId": "17", "updatedFields": ["status"]]))
        check("checklist: applies only confirmed fields", c.current?.items.first?.text == "Inspect parser" && c.current?.state == "completed")
        c.consume(line: line(["type": "user", "isMeta": true, "message": ["content": "Injected context"]]))
        check("checklist: meta input is not a new prompt", c.current?.state == "completed")
        c.consume(line: line(["type": "user", "message": ["content": "Next request"]]))
        check("checklist: new prompt makes plan stale", c.current?.state == "stale")
        c.consume(line: call("list", "TaskList", [:]))
        c.consume(line: result("list", "#21 [in_progress] Check results", ["tasks": [["id": "21", "subject": "Check results", "status": "in_progress"]]]))
        check("checklist: TaskList reconciles and refreshes", c.current?.items.map(\.id) == ["21"] && c.current?.state == "active")
        c.consume(line: call("get", "TaskGet", ["taskId": "21"]))
        c.consume(line: result("get", "Task #21: Check results\nStatus: completed\nDescription: Test"))
        check("checklist: text TaskGet reconciles", c.current?.state == "completed")
        c.consume(line: call("delete", "TaskUpdate", ["taskId": "21", "status": "deleted"]))
        c.consume(line: result("delete", "Updated task #21 deleted", ["success": true, "taskId": "21", "updatedFields": ["deleted"]]))
        check("checklist: confirmed deletion", c.current?.items.isEmpty == true)
        c.consume(line: call("todo", "TodoWrite", ["todos": [["content": "Check replacement", "status": "pending"]]]))
        c.consume(line: result("todo", "Todos have been modified successfully", ["newTodos": [["content": "Check replacement", "status": "in_progress"]]]))
        check("checklist: TodoWrite uses confirmed snapshot", c.current?.items.first?.status == "in_progress")
        c.consume(line: call("todo-fail", "TodoWrite", ["todos": []]))
        c.consume(line: result("todo-fail", "Rejected", error: true))
        check("checklist: failed TodoWrite retains items", c.current?.items.count == 1)
        c.consume(line: line(["type": "user", "message": ["content": "[Request interrupted by user]"]]))
        check("checklist: Claude interruption", c.current?.state == "interrupted")
        c.consume(line: line(["type": "attachment", "attachment": ["type": "queued_command", "origin": ["kind": "human"], "source_uuid": "queued-1", "prompt": "Next request"]]))
        check("checklist: delivered human queue makes plan stale", c.current?.state == "stale")
        c.consume(line: call("refresh", "TodoWrite", ["todos": [["content": "Refreshed", "status": "pending"]]]))
        c.consume(line: result("refresh", "Todos have been modified successfully"))
        c.consume(line: line(["type": "user", "uuid": "queued-1", "message": ["content": "Next request"]]))
        check("checklist: queue mirror does not stale refreshed plan", c.current?.state == "active")
        var unknown = ReaderChecklistReducer(kind: .claude)
        unknown.consume(line: call("unknown", "TaskCreate", ["subject": "Unknown ID"]))
        unknown.consume(line: result("unknown", "OK"))
        check("checklist: unknown creation response never invents ID", unknown.current?.items.isEmpty == true)

        func cxCall(_ id: String, _ status: String) -> Data {
            let args = String(decoding: line(["plan": [["step": "Inspect parser", "status": status]]]), as: UTF8.self)
            return line(["type": "response_item", "payload": ["type": "function_call", "call_id": id, "name": "update_plan", "arguments": args]])
        }
        func cxResult(_ id: String, _ text: String) -> Data {
            line(["type": "response_item", "payload": ["type": "function_call_output", "call_id": id, "output": text]])
        }
        var x = ReaderChecklistReducer(kind: .codex)
        x.consume(line: cxCall("p1", "in_progress"))
        x.consume(line: cxResult("wrong", "Plan updated"))
        check("checklist: Codex requires matching result", x.current?.items.isEmpty == true)
        x.consume(line: cxResult("p1", "Plan updated"))
        check("checklist: Codex confirmation", x.current?.state == "active")
        x.consume(line: cxCall("p2", "completed"))
        x.consume(line: cxResult("p2", "update_plan is unavailable in Plan mode"))
        check("checklist: Codex error retains prior items", x.current?.items.first?.status == "in_progress")
        x.consume(line: cxCall("p3", "completed"))
        x.consume(line: line(["type": "event_msg", "payload": ["type": "user_message", "message": "New request"]]))
        x.consume(line: cxResult("p3", "Plan updated"))
        check("checklist: late result cannot refresh newer prompt", x.current?.state == "stale" && x.current?.items.first?.status == "completed")
        x.consume(line: cxCall("p4", "in_progress"))
        x.consume(line: cxResult("p4", "Plan updated"))
        x.consume(line: line(["type": "event_msg", "payload": ["type": "turn_aborted", "reason": "interrupted"]]))
        check("checklist: Codex interruption", x.current?.state == "interrupted")
        x.consume(line: cxCall("p4", "completed"))
        x.consume(line: cxResult("p4", "Plan updated"))
        check("checklist: replayed calls are ignored", x.current?.state == "interrupted" && x.current?.items.first?.status == "in_progress")
    }
}
