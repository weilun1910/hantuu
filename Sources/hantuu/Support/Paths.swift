import Foundation

/// Where hantuu keeps its own data, and where the agents keep theirs.
enum Paths {
    /// App data (state.json, hantuu.log). `--data-dir <path>` or HANTUU_DATA_DIR overrides
    /// the default, which the self test and test launches use to stay out of ~/Library.
    static var dataDir: URL = {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        if let env = ProcessInfo.processInfo.environment["HANTUU_DATA_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/hantuu", isDirectory: true)
    }()

    static var stateFile: URL { dataDir.appendingPathComponent("state.json") }
    static var logFile: URL { dataDir.appendingPathComponent("hantuu.log") }

    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Claude Code transcripts: <config dir>/projects/<mangled cwd>/<session id>.jsonl
    static var claudeProjects: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("projects")
        }
        return home.appendingPathComponent(".claude/projects")
    }

    /// Codex rollouts: <CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl
    static var codexSessions: URL {
        if let dir = ProcessInfo.processInfo.environment["CODEX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("sessions")
        }
        return home.appendingPathComponent(".codex/sessions")
    }

    /// When running the bare binary from .build (not the .app), use vendor/ resources.
    static var devGhosttyResources: URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("vendor/ghostty-resources/ghostty")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// hantuu's own terminal look (Resources/terminal.ghostty), in the app bundle or, for a
    /// debug build, in the repo.
    static var terminalTheme: URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("terminal.ghostty"),
           FileManager.default.fileExists(atPath: r.path) {
            return r
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/terminal.ghostty")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Bundled web assets (reader, code viewer, JS libraries).
    static var webRoot: URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("web"),
           FileManager.default.fileExists(atPath: r.appendingPathComponent("reader.html").path) {
            return r
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/web")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("reader.html").path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

enum Log {
    private static let queue = DispatchQueue(label: "hantuu.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            Paths.ensure(Paths.dataDir)
            let url = Paths.logFile
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
        if ProcessInfo.processInfo.environment["HANTUU_LOG_STDERR"] == "1" {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}
