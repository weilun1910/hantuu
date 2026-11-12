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
        let codexRequest = ReaderRequest(id: UUID(), chatID: chat, sessionID: "fixture", tool: "apply_patch", inputJSON: "{}",
            helperPID: ProcessInfo.processInfo.processIdentifier, createdAt: now, expiresAt: now.addingTimeInterval(90), provider: .codex)
        try? JSONEncoder().encode(codexRequest).write(to: folder.appendingPathComponent(codexRequest.id.uuidString + ".request.json"))
        check("requests: Claude lease hides Codex request", ReaderRequestBridge.poll(chatID: chat, sessionID: "fixture", now: now).isEmpty)
        check("requests: Codex lease offers Codex request", ReaderRequestBridge.poll(chatID: chat, sessionID: "fixture", now: now, provider: .codex).map(\.id) == [codexRequest.id])
        let codexAnswer = ReaderRequestResponse(id: codexRequest.id, chatID: chat, sessionID: "fixture", action: .allow, provider: .codex)
        check("requests: Codex response is single use", ReaderRequestBridge.respond(codexAnswer, now: now) && !ReaderRequestBridge.respond(codexAnswer, now: now))
        ReaderRequestBridge.release(chatID: chat)
        check("requests: released reader cannot reply", !ReaderRequestBridge.respond(answer, now: now))
    }

    static func readerRequests() {
        readerRequestKeyboard()
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
        guard let codexRequest = ReaderRequest.fromHook(permission, chatID: chat, now: now, pid: 123, provider: .codex) else {
            check("requests: Codex live hook fixture parses", false); return
        }
        check("requests: Codex provider identity retained", codexRequest.resolvedProvider == .codex)
        for action in [ReaderRequestResponse.Action.allow, .deny] {
            let reply = ReaderRequestResponse(id: codexRequest.id, chatID: chat, sessionID: codexRequest.sessionID,
                                              action: action, provider: .codex)
            let text = reply.hookOutput(for: codexRequest, now: now).map { String(decoding: $0, as: UTF8.self) } ?? ""
            check("requests: Codex \(action.rawValue) uses supported decision only", text.contains("PermissionRequest")
                && text.contains(action.rawValue) && !text.contains("updatedInput") && !text.contains("updatedPermissions")
                && !text.contains("interrupt"))
        }
        check("requests: cross-provider response rejected", ReaderRequestResponse(id: codexRequest.id, chatID: chat,
            sessionID: codexRequest.sessionID, action: .allow).hookOutput(for: codexRequest, now: now) == nil)
        check("requests: Codex question answers stay in terminal", ReaderRequest.fromHook(Data(questionJSON.utf8),
            chatID: chat, now: now, pid: 123, provider: .codex) == nil)
        check("requests: Codex answer action rejected", ReaderRequestResponse(id: codexRequest.id, chatID: chat,
            sessionID: codexRequest.sessionID, action: .answer, provider: .codex).hookOutput(for: codexRequest, now: now) == nil)
        let patch = String(decoding: permission, as: UTF8.self).replacingOccurrences(of: "Bash", with: "apply_patch")
        check("requests: Codex patch hook supported", ReaderRequest.fromHook(Data(patch.utf8), chatID: chat,
            now: now, pid: 123, provider: .codex)?.tool == "apply_patch")
        for field in ["agent_id", "agent_type"] {
            let child = String(decoding: permission, as: UTF8.self).replacingOccurrences(of: "\"tool_name\"",
                with: "\"\(field)\":\"child\",\"tool_name\"")
            check("requests: Codex child \(field) stays in terminal", ReaderRequest.fromHook(Data(child.utf8),
                chatID: chat, now: now, pid: 123, provider: .codex) == nil)
        }
        if let data = try? JSONEncoder().encode(request),
           var legacy = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            legacy.removeValue(forKey: "provider")
            let encoded = try? JSONSerialization.data(withJSONObject: legacy)
            let decoded = encoded.flatMap { try? JSONDecoder().decode(ReaderRequest.self, from: $0) }
            check("requests: old request payload remains Claude", decoded?.resolvedProvider == .claude)
        } else { check("requests: old request payload remains Claude", false) }
        let arguments = AgentHooks.codexArguments(existingNotify: .none)
        check("requests: Codex respects hook trust and disabled feature", !arguments.contains("--dangerously-bypass-hook-trust")
            && !arguments.contains { $0.hasPrefix("features.hooks=") || $0.hasPrefix("hooks.states") })
        check("requests: Codex launch adds only its permission event", arguments.filter { $0.hasPrefix("hooks.") } == [AgentHooks.codexPermissionOverride])
        check("requests: Codex launch adds synchronous permission hook", arguments.contains(AgentHooks.codexPermissionOverride)
            && AgentHooks.codexPermissionOverride.contains("timeout=95,async=false")
            && AgentHooks.codexPermissionOverride.contains("Bash|apply_patch")
            && AgentHooks.codexPermissionOverride.contains("HANTUU_READER_PROVIDER=codex"))
        check("requests: Claude launch keeps its provider", AgentHooks.permissionCommand.contains("HANTUU_READER_PROVIDER=claude"))
        let plan = String(decoding: permission, as: UTF8.self).replacingOccurrences(of: "Bash", with: "ExitPlanMode")
        check("requests: plan mode stays in provider UI", ReaderRequest.fromHook(Data(plan.utf8), chatID: chat, now: now, pid: 123) == nil)
        check("requests: malformed input falls back", ReaderRequest.fromHook(Data("{}".utf8), chatID: chat, now: now, pid: 123) == nil)
    }
}
