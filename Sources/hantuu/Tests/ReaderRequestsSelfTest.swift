import Foundation

extension SelfTest {
    static func readerRequestFiles(_ dir: URL) {
        guard Paths.dataDir.path.hasPrefix(dir.path + "/") else {
            check("requests: isolated data folder", false); return
        }
        let chat = UUID(), now = Date()
        _ = ReaderRequestBridge.poll(chatID: chat, sessionID: "fixture", now: now)
        let folder = ReaderRequestBridge.directory(for: chat)
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = ReaderRequest(id: UUID(), chatID: chat, sessionID: "fixture", tool: "Bash", inputJSON: "{}",
                                    helperPID: ProcessInfo.processInfo.processIdentifier, createdAt: now, expiresAt: now.addingTimeInterval(90))
        let path = folder.appendingPathComponent(request.id.uuidString + ".request.json")
        try? JSONEncoder().encode(request).write(to: path)
        check("requests: active owned hook is offered", ReaderRequestBridge.poll(chatID: chat, sessionID: "fixture", now: now).map(\.id) == [request.id])
        let answer = ReaderRequestResponse(id: request.id, chatID: chat, sessionID: "fixture", action: .deny)
        check("requests: response is single use", ReaderRequestBridge.respond(answer, now: now) && !ReaderRequestBridge.respond(answer, now: now))
        check("requests: answered hook is removed from controls", ReaderRequestBridge.poll(chatID: chat, sessionID: "fixture", now: now).isEmpty)
        ReaderRequestBridge.release(chatID: chat)
        check("requests: released reader cannot reply", !ReaderRequestBridge.respond(answer, now: now))
    }

    static func readerRequests() {
        let chat = UUID()
        let now = Date(timeIntervalSince1970: 1000)
        let permission = Data(#"{"hook_event_name":"PermissionRequest","session_id":"session-fixture","tool_name":"Bash","tool_input":{"command":"printf fixture"},"permission_suggestions":[{"type":"setMode","mode":"bypassPermissions"}]}"#.utf8)
        guard let request = ReaderRequest.fromHook(permission, chatID: chat, now: now, pid: 123) else {
            check("requests: Claude hook fixture parses", false); return
        }
        check("requests: invocation gets independent identity without tool_use_id", request.id != ReaderRequest.fromHook(permission, chatID: chat, now: now, pid: 123)?.id)
        check("requests: ownership and expiry", request.belongs(to: chat, session: "session-fixture", now: now) && !request.belongs(to: UUID(), session: "session-fixture", now: now) && !request.belongs(to: chat, session: "other", now: now) && !request.belongs(to: chat, session: "session-fixture", now: now.addingTimeInterval(90)))
        let response = ReaderRequestResponse(id: request.id, chatID: chat, sessionID: request.sessionID, action: .allow)
        let output = response.hookOutput(for: request, now: now).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("requests: allow once never copies suggested grants", output.contains("allow") && !output.contains("updatedPermissions") && !output.contains("updatedInput") && !output.contains("bypass"))
        check("requests: late response rejected", response.hookOutput(for: request, now: now.addingTimeInterval(91)) == nil)
        check("requests: response id mismatch rejected", ReaderRequestResponse(id: UUID(), chatID: chat, sessionID: request.sessionID, action: .allow).hookOutput(for: request, now: now) == nil)
        check("requests: response session mismatch rejected", ReaderRequestResponse(id: request.id, chatID: chat, sessionID: "other", action: .allow).hookOutput(for: request, now: now) == nil)
        check("requests: terminal fallback returns no decision", ReaderRequestResponse(id: request.id, chatID: chat, sessionID: request.sessionID, action: .terminal).hookOutput(for: request, now: now) == nil)
        let questionJSON = #"{"hook_event_name":"PermissionRequest","session_id":"session-fixture","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which components?","header":"Components","options":[{"label":"Reader","description":"Conversation"},{"label":"Terminal","description":"Shell"}],"multiSelect":true}]}}"#
        guard let question = ReaderRequest.fromHook(Data(questionJSON.utf8), chatID: chat, now: now, pid: 123) else {
            check("requests: question hook fixture parses", false); return
        }
        check("requests: question options and multiselect retained", question.questions.first?.options.count == 2 && question.questions.first?.multiSelect == true)
        let answer = ReaderRequestResponse(id: question.id, chatID: chat, sessionID: question.sessionID, action: .answer, answers: ["Which components?": "Reader, Terminal"])
        let answerText = answer.hookOutput(for: question, now: now).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("requests: answer preserves original questions", answerText.contains("updatedInput") && answerText.contains("Reader, Terminal") && answerText.contains("questions") && !answerText.contains("updatedPermissions"))
        check("requests: unanswered question cannot approve", ReaderRequestResponse(id: question.id, chatID: chat, sessionID: question.sessionID, action: .allow).hookOutput(for: question, now: now) == nil)
        check("requests: missing answer rejected", ReaderRequestResponse(id: question.id, chatID: chat, sessionID: question.sessionID, action: .answer).hookOutput(for: question, now: now) == nil)
        let subagent = String(decoding: permission, as: UTF8.self).replacingOccurrences(of: "\"tool_name\"", with: "\"agent_id\":\"child\",\"tool_name\"")
        check("requests: subagent never borrowed by parent", ReaderRequest.fromHook(Data(subagent.utf8), chatID: chat, now: now, pid: 123) == nil)
        let codex = Data(#"{"type":"response_item","payload":{"type":"function_call","call_id":"call_fixture","name":"request_user_input","arguments":"{\"questions\":[]}"}}"#.utf8)
        check("requests: Codex transcript has no live approval channel", ReaderRequest.fromHook(codex, chatID: chat, now: now, pid: 123) == nil)
        let plan = String(decoding: permission, as: UTF8.self).replacingOccurrences(of: "Bash", with: "ExitPlanMode")
        check("requests: plan mode stays in provider UI", ReaderRequest.fromHook(Data(plan.utf8), chatID: chat, now: now, pid: 123) == nil)
        check("requests: malformed input falls back", ReaderRequest.fromHook(Data("{}".utf8), chatID: chat, now: now, pid: 123) == nil)
    }
}
