import Foundation
import Combine
import AppKit
import Darwin

/// Owns only hantuu's side history. Provider session directories are never written here.
final class SideChatStore: ObservableObject {
    static let historyLimit = 40
    @Published private(set) var histories: [UUID: [SideQuestion]] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var running: Set<UUID> = []
    let showQuestions = PassthroughSubject<UUID, Never>()
    var commandOverride: ((String, [String]) -> (URL, [String]))?
    private let directory: URL
    private let logger: (String) -> Void
    private var jobs: [UUID: SideQuestionJob] = [:]
    private var loaded: Set<UUID> = []
    private var quitObserver: NSObjectProtocol?

    init(directory: URL = Paths.dataDir.appendingPathComponent("side-chats"), logger: @escaping (String) -> Void = Log.write) {
        self.directory = directory
        self.logger = logger
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            for job in self.jobs.values { job.stop() }
        }
    }

    deinit {
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        for job in jobs.values { job.stop() }
    }

    func load(_ chat: UUID) {
        guard loaded.insert(chat).inserted else { return }
        let data = try? Data(contentsOf: file(chat))
        var records = data.flatMap { try? JSONDecoder().decode([SideQuestion].self, from: $0) } ?? []
        for i in records.indices where records[i].state == .streaming { records[i].state = .stopped }
        histories[chat] = Array(records.suffix(Self.historyLimit))
    }

    func entries(_ chat: UUID) -> [ReaderEntry] { (histories[chat] ?? []).flatMap(\.entries) }

    @discardableResult
    func ask(chat: UUID, agent: String, session: String?, executable: String?, folder: String, question: String) -> Bool {
        load(chat)
        guard !running.contains(chat) else { errors[chat] = "A side question is already running for this chat."; return false }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { errors[chat] = "Type a side question first."; return false }
        let args: [String]
        do {
            args = try SideQuestionCommand.arguments(agent: agent, session: session ?? "")
            if commandOverride == nil && executable == nil {
                throw SideQuestionCommand.Failure("\(AgentCatalog.definition(agent).name) was not found. Install it and sign in through its terminal.")
            }
        } catch {
            errors[chat] = error.localizedDescription
            return false
        }
        errors[chat] = nil
        let recent = Array((histories[chat] ?? []).filter { $0.state == .answered }.suffix(20))
        var prompt: String
        if recent.isEmpty { prompt = text }
        else {
            let exchanges = recent.map { "Side question: \($0.question)\nSide answer: \($0.answer)" }.joined(separator: "\n\n")
            prompt = "Previous side exchanges, for reference only:\n\n" + exchanges + "\n\nCurrent side question:\n" + text
        }
        if agent == "codex" {
            prompt = "Side conversation boundary.\nThe inherited conversation is reference context only. Do not continue or complete the parent's task. Only answer the current side question. Do not spawn subagents. You may inspect information using non-mutating tools, but never write files, change state, send messages, or invoke mutating MCP or app tools. Do not ask for elevated permissions.\n\n" + prompt
        }
        let record = SideQuestion(question: text)
        histories[chat, default: []].append(record)
        histories[chat] = Array((histories[chat] ?? []).suffix(Self.historyLimit))
        save(chat)
        let command = commandOverride?(agent, args) ?? (URL(fileURLWithPath: executable!), args)
        let job = SideQuestionJob(executable: command.0, arguments: command.1, folder: folder, prompt: prompt, agent: agent)
        jobs[chat] = job
        running.insert(chat)
        job.onUpdate = { [weak self, weak job] stream in
            guard let self, let job, self.jobs[chat] === job,
                  let index = self.histories[chat]?.firstIndex(where: { $0.id == record.id }) else { return }
            self.histories[chat]?[index].answer = stream.answer
        }
        job.onFinish = { [weak self, weak job] stream, status, stderr, stopped in
            guard let self, let job, self.jobs[chat] === job else { return }
            if let index = self.histories[chat]?.firstIndex(where: { $0.id == record.id }) {
                self.histories[chat]?[index].answer = stream.answer
                let problem = stream.error ?? (status != 0 ? (stderr.isEmpty ? "The CLI exited with status \(status). Check that it is signed in and up to date." : stderr) : nil)
                    ?? (!stream.finished ? "The CLI ended before completing its answer. Check that it supports streaming side questions." : nil)
                self.histories[chat]?[index].state = stopped ? .stopped : (problem == nil ? .answered : .failed)
                self.histories[chat]?[index].error = stopped ? nil : problem.map {
                    SideQuestionCommand.failureMessage(agent: agent, raw: $0, startedAnswer: !stream.answer.isEmpty)
                }
                self.histories[chat]?[index].rawError = stopped || problem == nil ? nil
                    : [problem, stderr.isEmpty || stderr == problem ? nil : stderr].compactMap { $0 }.joined(separator: "\n\n")
            }
            self.jobs[chat] = nil
            self.running.remove(chat)
            self.save(chat)
            self.log(chat: chat, agent: agent, job: job, success: self.histories[chat]?.last?.state == .answered)
        }
        job.start()
        return true
    }

    func stop(_ chat: UUID) { jobs[chat]?.stop() }

    func forget(_ chat: UUID) {
        if let job = jobs.removeValue(forKey: chat) {
            job.stop()
            log(chat: chat, agent: job.agentName, job: job, success: false)
        }
        running.remove(chat)
        histories[chat] = nil
        errors[chat] = nil
        loaded.remove(chat)
        try? FileManager.default.removeItem(at: file(chat))
    }

    private func log(chat: UUID, agent: String, job: SideQuestionJob, success: Bool) {
        logger("side question chat=\(chat) agent=\(agent) duration=\(String(format: "%.2f", Date().timeIntervalSince(job.started))) success=\(success)")
    }

    private func file(_ chat: UUID) -> URL { directory.appendingPathComponent(chat.uuidString + ".json") }

    private func save(_ chat: UUID) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(histories[chat] ?? [])
            try data.write(to: file(chat), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(chat).path)
        } catch { errors[chat] = "Side history could not be saved: \(error.localizedDescription)" }
    }
}

/// Nonblocking pipe reads run on a worker queue. A child holding an inherited pipe open
/// cannot keep a stopped question alive after the CLI process has exited.
final class SideQuestionJob {
    var onUpdate: ((SideAnswerStream) -> Void)?
    var onFinish: ((SideAnswerStream, Int32, String, Bool) -> Void)?
    let started = Date()
    let agentName: String
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let prompt: Data
    private let queue = DispatchQueue(label: "hantuu.side-stream", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var inputOffset = 0
    private var inputClosed = false
    private var stream = SideAnswerStream()
    private var stderr = Data()
    private var exitedAt: Date?
    private var stopped = false

    init(executable: URL, arguments: [String], folder: String, prompt: String, agent: String) {
        self.prompt = Data(prompt.utf8)
        agentName = agent
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        var env = ProcessInfo.processInfo.environment
        for key in Array(env.keys) where key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("HANTUU_") || key == "CLAUDECODE" {
            env.removeValue(forKey: key)
        }
        process.environment = env
    }

    deinit {
        timer?.cancel()
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }

    func start() {
        for handle in [input.fileHandleForWriting, output.fileHandleForReading, errors.fileHandleForReading] {
            let fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch {
            DispatchQueue.main.async { [self] in onFinish?(SideAnswerStream(), -1, "Could not start the agent CLI: \(error.localizedDescription)", false) }
            return
        }
        let source = DispatchSource.makeTimerSource(queue: queue)
        timer = source
        source.schedule(deadline: .now(), repeating: .milliseconds(40))
        source.setEventHandler { [weak self] in self?.poll() }
        source.resume()
    }

    private func poll() {
        // Stdin avoids putting either the question or its reference history in argv.
        if !inputClosed {
            let written = prompt.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress, inputOffset < bytes.count else { return 0 }
                return Darwin.write(input.fileHandleForWriting.fileDescriptor, base.advanced(by: inputOffset), min(65536, bytes.count - inputOffset))
            }
            if written > 0 { inputOffset += written }
            if inputOffset == prompt.count || (written < 0 && errno != EAGAIN && errno != EINTR) {
                try? input.fileHandleForWriting.close()
                inputClosed = true
            }
        }
        let out = readAvailable(output.fileHandleForReading)
        let err = readAvailable(errors.fileHandleForReading)
        if !out.isEmpty {
            stream.consume(out)
            let update = stream
            DispatchQueue.main.async { [weak self] in self?.onUpdate?(update) }
        }
        stderr.append(err)
        if stderr.count > 16384 { stderr = Data(stderr.suffix(16384)) }
        // Drain a bounded chunk per tick. EOF is not required after process exit because
        // wrappers may have handed their pipe descriptors to other processes.
        guard !process.isRunning else { return }
        if exitedAt == nil { exitedAt = Date() }
        let drained = out.count < 65536 && err.count < 65536
        guard drained || Date().timeIntervalSince(exitedAt!) >= 0.5 else { return }
        stream.consume(Data(), eof: true)
        timer?.cancel()
        timer = nil
        if !inputClosed { try? input.fileHandleForWriting.close(); inputClosed = true }
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
        let final = stream
        let status = process.terminationStatus
        let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async { [self] in onFinish?(final, status, message, stopped) }
    }

    private func readAvailable(_ handle: FileHandle) -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while result.count < 65536 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 { result.append(contentsOf: buffer.prefix(count)) }
            else if count < 0 && errno == EINTR { continue }
            else { break }
        }
        return result
    }

    func stop() {
        stopped = true
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

extension AppModel {
    func openSideQuestions(in chat: Chat) {
        panelTab = .side
        panelVisible = true
        sideChats.showQuestions.send(chat.id)
    }

    @discardableResult
    func askSideQuestion(_ question: String, in chat: Chat) -> Bool {
        openSideQuestions(in: chat)
        let executable = agents.first { $0.id == chat.agentID }?.path
        // Read the current identity on every ask; transcript discovery replaces it after /resume.
        return sideChats.ask(chat: chat.id, agent: chat.agentID, session: chat.sessionID,
                             executable: executable, folder: workingDirectory(of: chat), question: question)
    }
}
