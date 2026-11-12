import Foundation

struct SideQuestion: Codable, Identifiable, Equatable {
    enum State: String, Codable { case streaming, answered, stopped, failed }
    var id = UUID()
    var question: String
    var answer = ""
    var state: State = .streaming
    var error: String?
    var rawError: String?
    var createdAt = Date()

    var entries: [ReaderEntry] {
        let key = id.uuidString
        var result = [ReaderEntry(id: key + "-q", kind: .user, text: question)]
        if !answer.isEmpty { result.append(ReaderEntry(id: key + "-a", kind: .assistant, text: answer)) }
        if let error {
            result.append(ReaderEntry(id: key + "-error", kind: .error, text: error,
                                      detail: rawError, detailTitle: rawError == nil ? nil : "CLI output"))
        }
        if state == .streaming { result.append(ReaderEntry(id: key + "-state", kind: .notice, text: "Answering...")) }
        if state == .stopped { result.append(ReaderEntry(id: key + "-state", kind: .notice, text: "Stopped")) }
        return result
    }
}

enum SideQuestionCommand {
    static func arguments(agent: String, session: String) throws -> [String] {
        guard !session.isEmpty else { throw Failure("Send a message in this chat first so it has a session to use.") }
        if agent == "codex" {
            // Codex's native side conversations allow non-mutating exploration. Forking
            // keeps its parent rollout untouched; the sandbox restricts local writes.
            return ["exec", "--skip-git-repo-check", "--disable", "hooks", "--disable", "apps", "-s", "read-only",
                    "-c", "approval_policy=\"never\"", "-c", "agents.enabled=false", "-c", "notify=[]",
                    "-c", "web_search=\"disabled\"", "--ephemeral", "--json", "--thread-source", "hantuu_side",
                    "fork", session, "-"]
        }
        guard agent == "claude" else {
            throw Failure("Side questions are not supported for this agent yet.")
        }
        // A fork and no persistence keep the parent's transcript untouched. Disable hooks,
        // MCP and slash commands too, so asking a question cannot start project tools.
        return ["--print", "--resume", session, "--fork-session", "--no-session-persistence",
                "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                "--disable-slash-commands", "--settings", "{\"disableAllHooks\":true}",
                "--append-system-prompt", "Answer only the side question supplied now. The inherited conversation is reference context. Do not continue its tasks. You cannot run tools or make changes. Do not claim to have executed tools."]
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func failureMessage(agent: String, raw: String, startedAnswer: Bool) -> String {
        let name = AgentCatalog.definition(agent).name
        let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var reason = lines.first(where: { $0.lowercased().hasPrefix("error:") })
            ?? lines.first(where: { !$0.isEmpty }) ?? "The CLI exited without an explanation."
        if reason.lowercased().hasPrefix("error:") { reason = String(reason.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        if raw.contains("Not inside a trusted directory") && raw.contains("--skip-git-repo-check") {
            reason = "its folder check rejected this directory."
        }
        reason = String(reason.prefix(400))
        return startedAnswer ? "\(name) couldn't finish this side question: \(reason)"
            : "\(name) couldn't start a side question here: \(reason)"
    }

    /// Only reader input is intercepted. Native terminal commands never pass this route.
    static func question(_ text: String, agent: String, reader: Bool) -> String? {
        guard reader, agent == "claude" || agent == "codex" else { return nil }
        let pieces = text.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard pieces.first == "/btw" || (agent == "codex" && pieces.first == "/side") else { return nil }
        return pieces.count > 1 ? String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
}

/// Buffers bytes, rather than Strings, so a split UTF-8 character survives a pipe read.
struct SideAnswerStream {
    private var pending = Data()
    private var completed = ""
    private var current = ""
    private var codexItems: [String: String] = [:]
    private var codexOrder: [String] = []
    private(set) var answer = ""
    private(set) var error: String?
    private(set) var finished = false

    mutating func consume(_ bytes: Data, eof: Bool = false) {
        pending.append(bytes)
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            parse(line)
        }
        if eof && !pending.isEmpty { let line = pending; pending.removeAll(); parse(line) }
    }

    private mutating func parse(_ line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        switch object["type"] as? String {
        case "item.started", "item.updated", "item.completed":
            guard let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message",
                  let id = item["id"] as? String, let text = item["text"] as? String else { return }
            if codexItems[id] == nil { codexOrder.append(id) }
            codexItems[id] = text
            answer = codexOrder.compactMap { codexItems[$0] }.joined(separator: "\n\n")
        case "turn.completed": finished = true
        case "turn.failed":
            finished = true
            error = (object["error"] as? [String: Any])?["message"] as? String ?? "The side question failed."
        case "stream_event":
            guard let event = object["event"] as? [String: Any] else { return }
            if event["type"] as? String == "message_start" { current = "" }
            if event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                current += text
                answer = completed + current
            }
        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if object["isApiErrorMessage"] as? Bool == true { error = text; return }
            if !text.isEmpty { completed += text; answer = completed; current = "" }
        case "result":
            finished = true
            if object["is_error"] as? Bool == true {
                error = (object["errors"] as? [String])?.joined(separator: "\n") ?? object["result"] as? String ?? "The side question failed."
            } else if answer.isEmpty, let text = object["result"] as? String { answer = text }
        case "error":
            let details = object["error"] as? [String: Any]
            error = details?["message"] as? String ?? object["message"] as? String ?? "The side question failed."
        default: break
        }
    }
}
