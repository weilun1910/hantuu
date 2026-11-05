import CryptoKit
import Foundation

/// How a chat's terminal reaches its agent through hantuu-session (Sources/hantuu-session).
/// `create` starts the agent in a new session unless one is already running for the chat;
/// `attach` only reconnects, and ends at once if the session is gone.
struct SessionLaunch {
    enum Mode {
        case create(cwd: String)
        case attach
    }

    let chatID: UUID
    let mode: Mode

    /// The helper's command line around the agent's argv, or nil if the helper isn't there
    /// (a bare binary built without it), in which case the agent runs directly as before.
    func arguments(wrapping argv: [String]) -> [String]? {
        guard let helper = SessionHelper.executable else { return nil }
        var a = [helper, "attach", "--socket-dir", SessionHelper.socketDir, "--id", chatID.uuidString]
        switch mode {
        case .create(let cwd): a += ["--create", "--cwd", cwd, "--"] + argv
        case .attach: break
        }
        return a
    }
}

/// One live session, as `hantuu-session list --json` reports it.
struct SessionInfo: Decodable, Equatable {
    let id: String
    let pid: Int32
    let child: Int32
    let attached: Bool
    let exited: Bool
    let created: TimeInterval
    let cwd: String
    let command: String
}

/// Finding and talking to hantuu-session.
///
/// Socket paths: a Unix socket path has to fit in 104 bytes on macOS, and the data folder can
/// be long (the default one plus a 36-character chat id is already 102), and test data folders
/// live under paths with emoji and spaces. So the sockets live in a short private folder,
/// `/tmp/hantuu-<uid>/<first 8 hex of SHA-256 of the data folder>/`, the way tmux keeps its
/// sockets in `/tmp/tmux-<uid>/`. Keying by the data folder keeps a test copy's sessions apart
/// from the real app's. `<data folder>/sessions/socket-dir` records which folder that is.
/// macOS's daily /tmp cleanup only removes old regular files and empty folders, never sockets,
/// and both folders are recreated whenever they're missing.
enum SessionHelper {
    /// hantuu-session next to the app's own executable (Contents/MacOS, or .build/<config>).
    static var executable: String? {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let url = exe.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("hantuu-session")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    static var socketRoot: String { "/tmp/hantuu-\(getuid())" }

    static func socketDir(for dataDir: URL) -> String {
        let key = dataDir.standardizedFileURL.resolvingSymlinksInPath().path
        let hex = SHA256.hash(data: Data(key.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(socketRoot)/\(hex)"
    }

    static var socketDir: String { socketDir(for: Paths.dataDir) }

    /// `<data folder>/sessions/`: the pointer file and the session settings.
    static var dataFolder: URL { Paths.dataDir.appendingPathComponent("sessions", isDirectory: true) }

    /// Creates the private socket folders and records where they are. The helper checks the
    /// folders again itself before using them.
    @discardableResult
    static func prepare() -> Bool {
        for dir in [socketRoot, socketDir] {
            mkdir(dir, 0o700)
            var st = stat()
            // /tmp is shared, so the folder must be a real folder that only we can use.
            guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else {
                Log.write("sessions: \(dir) isn't a private folder owned by this user")
                return false
            }
        }
        Paths.ensure(dataFolder)
        try? Data((socketDir + "\n").utf8).write(to: dataFolder.appendingPathComponent("socket-dir"), options: .atomic)
        return true
    }

    /// Runs the helper and returns its exit code and output.
    @discardableResult
    static func run(_ args: [String], timeout: TimeInterval = 15) -> (code: Int32, out: String) {
        guard let exe = executable else { return (-1, "") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            Log.write("sessions: helper failed to start: \(error)")
            return (-1, "")
        }
        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = group.wait(timeout: .now() + 1)
        }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Live sessions for this data folder. Sockets whose server is gone are cleared on the way.
    static func list() -> [SessionInfo] {
        let r = run(["list", "--socket-dir", socketDir, "--json"])
        return r.out.split(whereSeparator: \.isNewline).compactMap { try? JSONDecoder().decode(SessionInfo.self, from: Data($0.utf8)) }
    }

    static func info(_ chatID: UUID) -> SessionInfo? {
        list().first { $0.id == chatID.uuidString && !$0.exited }
    }

    static func isAlive(_ chatID: UUID) -> Bool { info(chatID) != nil }

    /// Stops a chat's agent and waits for it to go (the helper waits up to about 3 seconds
    /// for it to exit after a hangup, then kills it). True if there was a session.
    @discardableResult
    static func killNow(_ chatID: UUID) -> Bool {
        run(["kill", "--socket-dir", socketDir, "--id", chatID.uuidString]).code == 0
    }

    /// Same, without blocking: the helper process is started right away, so the request goes
    /// out even if the app quits a moment later. `then` runs on a background queue once the
    /// agent has stopped.
    static func kill(_ chatID: UUID, then: (() -> Void)? = nil) {
        guard let exe = executable else { then?(); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["kill", "--socket-dir", socketDir, "--id", chatID.uuidString]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { _ in then?() }
        do { try p.run() } catch { then?() }
    }

    /// Stops several agents at once and waits, up to `timeout`, for all of them.
    static func killAll(_ chatIDs: [UUID], timeout: TimeInterval = 6) {
        let group = DispatchGroup()
        for id in chatIDs {
            group.enter()
            kill(id) { group.leave() }
        }
        _ = group.wait(timeout: .now() + timeout)
    }
}
