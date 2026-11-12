import Foundation

/// Code-mode wrappers can omit nested results when they print only selected fields.
/// Codex's completed items retain the actual command output and historical file changes.
enum CodexOperationEvent {
    static func entry(_ payload: [String: Any], session: String, time: String?) -> ReaderEntry? {
        guard payload["type"] as? String == "item_completed",
              let item = payload["item"] as? [String: Any],
              let id = item["id"] as? String, !id.isEmpty,
              let type = item["type"] as? String,
              ["CommandExecution", "FileChange"].contains(type) else { return nil }
        let thread = (payload["thread_id"] as? String) ?? session
        let name = type == "CommandExecution" ? "exec_command" : "apply_patch"
        var operation = ReaderOperation(id: id, name: name, provider: "codex", arguments: "")
        operation.startedAt = timestamp(payload["started_at_ms"])
        operation.finishedAt = timestamp(payload["completed_at_ms"]) ?? time
        let status = item["status"] as? String
        switch status {
        case "completed": operation.state = "completed"
        case "failed": operation.state = "failed"
        case "declined": operation.state = "declined"
        case "interrupted": operation.state = "interrupted"
        default: operation.state = "unknown"
        }
        var files: [String] = []
        if type == "CommandExecution" {
            if let command = item["command"] as? [String] { operation.command = CodexRolloutStatus.shellLine(command) }
            else { operation.command = item["command"] as? String }
            operation.output = item["aggregated_output"] as? String
            operation.exitCode = CodexWorkParser.string(item["exit_code"]).flatMap(Int.init)
            if let code = operation.exitCode, code != 0 { operation.state = "failed" }
            if let duration = item["duration"] as? [String: Any] {
                operation.duration = ((duration["secs"] as? NSNumber)?.doubleValue ?? 0)
                    + ((duration["nanos"] as? NSNumber)?.doubleValue ?? 0) / 1e9
            }
            operation.truncated = item["truncated"] as? Bool == true
        } else {
            let changes = item["changes"] as? [String: [String: Any]] ?? [:]
            files = changes.keys.sorted()
            var patches: [String] = []
            for path in files {
                guard let change = changes[path] else { continue }
                switch change["type"] as? String {
                case "update":
                    if let diff = change["unified_diff"] as? String {
                        let destination = (change["move_path"] as? String) ?? path
                        patches.append("--- \(path)\n+++ \(destination)\n" + diff)
                    }
                case "add":
                    if let content = change["content"] as? String {
                        patches.append("*** Add File: \(path)\n" + marked(content, prefix: "+"))
                    }
                case "delete":
                    patches.append("*** Delete File: \(path)")
                    if let content = change["content"] as? String { patches.append(marked(content, prefix: "-")) }
                    else { operation.patchNote = "The provider did not record the deleted file's contents." }
                default: break
                }
            }
            if !patches.isEmpty { operation.patch = patches.joined(separator: "\n") }
            operation.output = [item["stdout"] as? String, item["stderr"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return ReaderEntry(id: "operation:\(thread):item:\(id)", kind: .tool,
                           text: type == "CommandExecution" ? "Ran a command" : "Changed files",
                           tool: name, files: files, time: time, operation: operation)
    }

    private static func timestamp(_ value: Any?) -> String? {
        guard let milliseconds = value as? NSNumber else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds.doubleValue / 1000))
    }

    private static func marked(_ content: String, prefix: String) -> String {
        var lines = content.components(separatedBy: "\n")
        if content.hasSuffix("\n") { lines.removeLast() }
        return lines.map { prefix + $0 }.joined(separator: "\n")
    }
}
