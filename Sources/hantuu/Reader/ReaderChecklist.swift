import Foundation

/// Only confirmed provider items. An unconfirmed mutation changes the envelope, never the items.
struct ReaderChecklist: Codable, Equatable {
    struct Item: Codable, Equatable {
        var id: String
        var text: String
        var status: String
    }
    var items: [Item]
    var state: String
}

struct ReaderChecklistReducer {
    let kind: TranscriptKind
    private(set) var current: ReaderChecklist?
    private struct Call {
        var name: String
        var input: [String: Any]
        var generation: Int
    }
    private var pending: [String: Call] = [:]
    private var seen = Set<String>()
    private var generation = 0
    private var promptIDs = Set<String>()
    private var tasks: [ReaderChecklist.Item] = []

    init(kind: TranscriptKind) { self.kind = kind }

    @discardableResult
    mutating func consume(line: Data) -> ReaderChecklist? {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return current }
        if kind == .claude { claude(obj) } else { codex(obj) }
        return current
    }

    private mutating func boundary(_ state: String) {
        generation += 1
        if current != nil { current?.state = state }
    }

    private mutating func requested(_ id: String, _ name: String, _ input: [String: Any]) {
        guard seen.insert(id).inserted else { return }
        pending[id] = Call(name: name, input: input, generation: generation)
        if current == nil { current = ReaderChecklist(items: [], state: "unconfirmed") }
        if current?.state != "stale" && current?.state != "interrupted" { current?.state = "unconfirmed" }
    }

    private mutating func confirmed(_ items: [ReaderChecklist.Item], _ call: Call) {
        let state = items.allSatisfy { $0.status == "completed" } ? "completed" : "active"
        // A late result still establishes facts, but cannot refresh a newer user request.
        current = ReaderChecklist(items: items, state: call.generation == generation ? state : (current?.state ?? "stale"))
        if call.generation == generation && !pending.isEmpty { current?.state = "unconfirmed" }
    }

    private mutating func claude(_ obj: [String: Any]) {
        guard obj["isSidechain"] as? Bool != true, let type = obj["type"] as? String else { return }
        if type == "attachment", let attachment = obj["attachment"] as? [String: Any],
           attachment["type"] as? String == "queued_command",
           (attachment["origin"] as? [String: Any])?["kind"] as? String == "human",
           attachment["commandMode"] as? String != "task-notification" {
            if let source = attachment["source_uuid"] as? String, !promptIDs.insert(source).inserted { return }
            boundary("stale")
            return
        }
        guard let msg = obj["message"] as? [String: Any] else { return }
        let blocks = msg["content"] as? [[String: Any]] ?? []
        if type == "assistant" {
            for b in blocks where b["type"] as? String == "tool_use" {
                guard let name = b["name"] as? String,
                      ["TodoWrite", "TaskCreate", "TaskUpdate", "TaskGet", "TaskList"].contains(name),
                      let id = b["id"] as? String else { continue }
                requested(id, name, b["input"] as? [String: Any] ?? [:])
            }
        } else if type == "user" {
            let results = blocks.filter { $0["type"] as? String == "tool_result" }
            for result in results {
                guard let id = result["tool_use_id"] as? String, let call = pending.removeValue(forKey: id) else { continue }
                guard result["is_error"] as? Bool != true else { continue }
                // The outer structured result belongs to a single result block only.
                let structured = results.count == 1 ? obj["toolUseResult"] as? [String: Any] : nil
                applyClaude(call, structured ?? [:], Self.text(result["content"]))
            }
            if !results.isEmpty || obj["isMeta"] as? Bool == true || obj["isCompactSummary"] as? Bool == true { return }
            if let uuid = obj["uuid"] as? String, !promptIDs.insert(uuid).inserted { return }
            let text = Self.text(msg["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("[Request interrupted by user") { boundary("interrupted"); return }
            let noise = ["<system-reminder>", "<task-notification>", "<local-command-", "<command-", "Caveat:", "<user-prompt-submit-hook>", "<bash-stdout>", "<bash-stderr>"]
            if !noise.contains(where: { text.hasPrefix($0) }) && (!text.isEmpty || blocks.contains(where: { $0["type"] as? String == "image" })) { boundary("stale") }
        }
    }

    private mutating func applyClaude(_ call: Call, _ result: [String: Any], _ text: String) {
        guard result["success"] as? Bool != false, result["error"] == nil else { return }
        switch call.name {
        case "TodoWrite":
            guard let rows = (result["newTodos"] ?? call.input["todos"]) as? [[String: Any]],
                  let items = Self.snapshot(rows, field: "content", prefix: "todo-") else { return }
            confirmed(items, call)
        case "TaskCreate":
            let task = result["task"] as? [String: Any]
            let id = Self.string(task?["id"]) ?? Self.captures(#"^Task #(\S+) created successfully:"#, text).first
            guard let id, let subject = (task?["subject"] ?? call.input["subject"]) as? String else { return }
            upsert(.init(id: id, text: subject, status: "pending"))
            confirmed(tasks, call)
        case "TaskUpdate":
            guard let id = Self.string(call.input["taskId"]),
                  Self.string(result["taskId"]) == nil || Self.string(result["taskId"]) == id else { return }
            let fields: [String]
            if result["success"] as? Bool == true, let changed = result["updatedFields"] as? [String] { fields = changed }
            else if text.hasPrefix("Updated task #\(id) ") {
                fields = String(text.dropFirst("Updated task #\(id) ".count)).components(separatedBy: "\n")[0].components(separatedBy: ", ")
            } else { return }
            if fields.contains("deleted") { tasks.removeAll { $0.id == id } }
            else if let index = tasks.firstIndex(where: { $0.id == id }) {
                if fields.contains("subject"), let subject = call.input["subject"] as? String { tasks[index].text = subject }
                if fields.contains("status"), let status = Self.status(call.input["status"]) { tasks[index].status = status }
            } else { return } // An unseen task needs TaskGet/List, not a made-up subject.
            confirmed(tasks, call)
        case "TaskGet":
            if result["task"] is NSNull || text == "Task not found" {
                if let id = Self.string(call.input["taskId"]) { tasks.removeAll { $0.id == id }; confirmed(tasks, call) }
            } else if let task = result["task"] as? [String: Any], let item = Self.task(task) {
                upsert(item); confirmed(tasks, call)
            } else {
                let title = Self.captures(#"^Task #(\S+): ([^\n]+)"#, text)
                let status = Self.captures(#"(?m)^Status: (pending|in_progress|completed)$"#, text).first
                if title.count == 2, let status { upsert(.init(id: title[0], text: title[1], status: status)); confirmed(tasks, call) }
            }
        case "TaskList":
            if let rows = result["tasks"] as? [[String: Any]] {
                let items = rows.compactMap(Self.task)
                guard items.count == rows.count else { return }
                tasks = items; confirmed(tasks, call)
            } else if text == "No tasks found" { tasks = []; confirmed(tasks, call) }
            else {
                let lines = text.split(separator: "\n")
                let items = lines.compactMap { line -> ReaderChecklist.Item? in
                    let parts = Self.captures(#"^#(\S+) \[(pending|in_progress|completed)\] (.+)$"#, String(line))
                    guard parts.count == 3 else { return nil }
                    return .init(id: parts[0], text: parts[2], status: parts[1])
                }
                if !items.isEmpty && items.count == lines.count { tasks = items; confirmed(tasks, call) }
            }
        default: break
        }
    }

    private mutating func codex(_ obj: [String: Any]) {
        guard let p = obj["payload"] as? [String: Any] else { return }
        let type = obj["type"] as? String, subtype = p["type"] as? String
        if type == "event_msg", subtype == "user_message" { boundary("stale"); return }
        if type == "event_msg", subtype == "turn_aborted" { boundary("interrupted"); return }
        guard type == "response_item", let id = p["call_id"] as? String else { return }
        if subtype == "function_call" || subtype == "custom_tool_call" {
            guard (p["name"] as? String)?.split(separator: ".").last == "update_plan",
                  let raw = (p["arguments"] ?? p["input"]) as? String,
                  let input = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { return }
            requested(id, "update_plan", input)
        } else if subtype == "function_call_output" || subtype == "custom_tool_call_output" {
            guard let call = pending.removeValue(forKey: id), p["is_error"] as? Bool != true,
                  Self.text(p["output"]).trimmingCharacters(in: .whitespacesAndNewlines) == "Plan updated",
                  let rows = call.input["plan"] as? [[String: Any]],
                  let items = Self.snapshot(rows, field: "step", prefix: "plan-") else { return }
            confirmed(items, call)
        }
    }

    private mutating func upsert(_ item: ReaderChecklist.Item) {
        if let index = tasks.firstIndex(where: { $0.id == item.id }) { tasks[index] = item }
        else { tasks.append(item) }
    }
    private static func task(_ row: [String: Any]) -> ReaderChecklist.Item? {
        guard let id = string(row["id"]), let text = row["subject"] as? String, let status = status(row["status"]) else { return nil }
        return .init(id: id, text: text, status: status)
    }
    private static func snapshot(_ rows: [[String: Any]], field: String, prefix: String) -> [ReaderChecklist.Item]? {
        let items = rows.enumerated().compactMap { index, row -> ReaderChecklist.Item? in
            guard let text = row[field] as? String, let status = status(row["status"]) else { return nil }
            return .init(id: string(row["id"]) ?? "\(prefix)\(index)", text: text, status: status)
        }
        return items.count == rows.count ? items : nil
    }
    private static func status(_ value: Any?) -> String? {
        guard let value = value as? String, ["pending", "in_progress", "completed"].contains(value) else { return nil }
        return value
    }
    private static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s.isEmpty ? nil : s }
        return (value as? NSNumber)?.stringValue
    }
    private static func text(_ value: Any?) -> String {
        if let text = value as? String { return text }
        return (value as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
    }
    private static func captures(_ pattern: String, _ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
