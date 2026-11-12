import Foundation
import Darwin

enum ReaderRequestProvider: String, Codable { case claude, codex }

/// A live hook invocation, never inferred from a transcript or terminal pixels.
struct ReaderRequest: Codable, Equatable {
    let id: UUID
    let chatID: UUID
    let sessionID: String
    let tool: String
    let inputJSON: String
    let helperPID: Int32
    let createdAt: Date
    let expiresAt: Date
    var cwd: String? = nil
    var provider: ReaderRequestProvider? = nil
    var resolvedProvider: ReaderRequestProvider { provider ?? .claude }

    struct Question: Codable, Equatable {
        let question: String
        let header: String?
        let options: [Option]
        let multiSelect: Bool?
        struct Option: Codable, Equatable { let label: String; let description: String? }
    }

    var questions: [Question] {
        guard resolvedProvider == .claude, tool == "AskUserQuestion", let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["questions"], let encoded = try? JSONSerialization.data(withJSONObject: raw),
              let result = try? JSONDecoder().decode([Question].self, from: encoded) else { return [] }
        return result
    }

    func belongs(to chat: UUID, session: String, now: Date) -> Bool {
        chatID == chat && sessionID == session && createdAt <= now && now < expiresAt
            && expiresAt.timeIntervalSince(createdAt) <= ReaderRequestBridge.lifetime
    }

    static func fromHook(_ data: Data, chatID: UUID, now: Date, pid: Int32, provider: ReaderRequestProvider = .claude) -> ReaderRequest? {
        guard data.count <= 1_048_576,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["hook_event_name"] as? String == "PermissionRequest",
              let session = o["session_id"] as? String, !session.isEmpty,
              let tool = o["tool_name"] as? String, !tool.isEmpty,
              tool != "ExitPlanMode", // Plan approval can change mode; keep the provider's UI.
              (o["agent_id"] as? String).map({ $0.isEmpty }) ?? true, // Child ownership is separate.
              let input = o["tool_input"] as? [String: Any],
              let json = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return nil }
        guard provider != .codex || (["Bash", "apply_patch"].contains(tool)
            && o["agent_id"] == nil && o["agent_type"] == nil) else { return nil }
        let request = ReaderRequest(id: UUID(), chatID: chatID, sessionID: session, tool: tool,
                                    inputJSON: String(decoding: json, as: UTF8.self), helperPID: pid,
                                    createdAt: now, expiresAt: now.addingTimeInterval(ReaderRequestBridge.lifetime), cwd: o["cwd"] as? String, provider: provider)
        if tool == "AskUserQuestion" {
            let questions = request.questions
            guard !questions.isEmpty, questions.count <= 4,
                  Set(questions.map(\.question)).count == questions.count,
                  questions.allSatisfy({ !$0.question.isEmpty && !$0.options.isEmpty }) else { return nil }
        }
        return request
    }
}

struct ReaderRequestResponse: Codable {
    enum Action: String, Codable { case allow, deny, answer, terminal }
    let id: UUID
    let chatID: UUID
    let sessionID: String
    let action: Action
    var answers: [String: String] = [:]
    var provider: ReaderRequestProvider? = nil

    /// Only Claude question answers rewrite input. No permission or mode grants.
    func hookOutput(for request: ReaderRequest, now: Date) -> Data? {
        guard (provider ?? .claude) == request.resolvedProvider, id == request.id, request.belongs(to: chatID, session: sessionID, now: now), action != .terminal else { return nil }
        var decision: [String: Any]
        switch action {
        case .allow:
            guard request.tool != "AskUserQuestion" else { return nil }
            decision = ["behavior": "allow"]
        case .deny:
            decision = ["behavior": "deny", "message": "The user declined this request in hantuu."]
        case .answer:
            let questions = request.questions
            guard request.resolvedProvider == .claude, request.tool == "AskUserQuestion", !questions.isEmpty,
                  Set(answers.keys) == Set(questions.map(\.question)),
                  answers.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 16_384 }),
                  let data = request.inputJSON.data(using: .utf8),
                  var input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            input["answers"] = answers
            decision = ["behavior": "allow", "updatedInput": input]
        case .terminal: return nil
        }
        return try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]], options: [.sortedKeys])
    }
}

/// Local rendezvous for the app's own synchronous provider hooks. No provider config edits.
/// Poll only while the owned main reader is visible and its current session is confirmed.
/// Historical entries, subagents and unsupported prompts use Show Terminal.
enum ReaderRequestBridge {
    static let flag = "--reader-permission-hook"
    static let envKey = "HANTUU_READER_REQUESTS"
    static let providerEnvKey = "HANTUU_READER_PROVIDER"
    static let chatEnvKey = "HANTUU_READER_CHAT"
    static let lifetime: TimeInterval = 90
    static let leaseLifetime: TimeInterval = 3
    static var root: URL { Paths.dataDir.appendingPathComponent("reader-requests", isDirectory: true) }
    static func directory(for chat: UUID) -> URL { root.appendingPathComponent(chat.uuidString, isDirectory: true) }

    private struct Lease: Codable {
        let sessionID: String
        let at: Date
        var provider: ReaderRequestProvider? = nil
        func valid(session: String, provider expected: ReaderRequestProvider, now: Date) -> Bool {
            (provider ?? .claude) == expected && sessionID == session && at <= now && now.timeIntervalSince(at) < leaseLifetime
        }
    }

    static func poll(chatID: UUID, sessionID: String, now: Date = Date(), provider: ReaderRequestProvider = .claude) -> [ReaderRequest] {
        guard !sessionID.isEmpty else { return [] }
        let dir = directory(for: chatID)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try write(Lease(sessionID: sessionID, at: now, provider: provider), to: dir.appendingPathComponent("lease.json"))
        } catch { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasSuffix(".request.json") }.compactMap { url in
            guard let request: ReaderRequest = read(url), request.resolvedProvider == provider,
                  request.belongs(to: chatID, session: sessionID, now: now),
                  request.helperPID > 1, kill(request.helperPID, 0) == 0,
                  !FileManager.default.fileExists(atPath: responseURL(request, dir: dir).path) else { return nil }
            return request
        }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Use on selection changes, terminal reveal, reader disappearance and session changes.
    static func release(chatID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: chatID).appendingPathComponent("lease.json"))
    }

    static func respond(_ response: ReaderRequestResponse, now: Date = Date()) -> Bool {
        let dir = directory(for: response.chatID)
        guard let lease: Lease = read(dir.appendingPathComponent("lease.json")), lease.valid(session: response.sessionID, provider: response.provider ?? .claude, now: now),
              let request: ReaderRequest = read(dir.appendingPathComponent(response.id.uuidString + ".request.json")),
              request.resolvedProvider == (response.provider ?? .claude),
              request.id == response.id, request.belongs(to: response.chatID, session: response.sessionID, now: now),
              request.helperPID > 1, kill(request.helperPID, 0) == 0,
              response.action == .terminal || response.hookOutput(for: request, now: now) != nil,
              let data = try? JSONEncoder().encode(response) else { return false }
        // O_EXCL makes a double click or second window unable to overwrite a decision.
        let url = responseURL(request, dir: dir)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.close(); return true }
        catch { try? handle.close(); try? FileManager.default.removeItem(at: url); return false }
    }

    /// Called before NSApplication is initialized. All failure paths return no decision,
    /// leaving the existing terminal permission flow intact.
    static func runHook() -> Int32 {
        let env = ProcessInfo.processInfo.environment
        guard let path = env[envKey], let chatText = env[chatEnvKey], let chat = UUID(uuidString: chatText) else { return 0 }
        guard let provider = ReaderRequestProvider(rawValue: env[providerEnvKey] ?? "claude") else { return 0 }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let request = ReaderRequest.fromHook(input, chatID: chat, now: Date(), pid: getpid(), provider: provider),
              let lease: Lease = read(dir.appendingPathComponent("lease.json")), lease.valid(session: request.sessionID, provider: provider, now: Date()) else { return 0 }
        let requestURL = dir.appendingPathComponent(request.id.uuidString + ".request.json")
        let responseURL = responseURL(request, dir: dir)
        defer { try? FileManager.default.removeItem(at: requestURL); try? FileManager.default.removeItem(at: responseURL) }
        do { try write(request, to: requestURL) } catch { return 0 }
        let parent = getppid()
        while Date() < request.expiresAt && getppid() == parent && parent > 1 {
            guard let active: Lease = read(dir.appendingPathComponent("lease.json")), active.valid(session: request.sessionID, provider: provider, now: Date()) else { return 0 }
            if let response: ReaderRequestResponse = read(responseURL) {
                if let output = response.hookOutput(for: request, now: Date()) {
                    FileHandle.standardOutput.write(output)
                }
                return 0
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return 0
    }

    private static func responseURL(_ request: ReaderRequest, dir: URL) -> URL {
        dir.appendingPathComponent(request.id.uuidString + ".response.json")
    }
    private static func read<T: Decodable>(_ url: URL) -> T? {
        guard let info = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]), info.isSymbolicLink != true,
              (info.fileSize ?? Int.max) <= 1_048_576, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
