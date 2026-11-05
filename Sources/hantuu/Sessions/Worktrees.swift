import Foundation

/// A chat's own git worktree: `<repo>/.hantuu/worktrees/<slug>` on branch `hantuu/<slug>`.
struct WorktreeInfo: Codable, Hashable {
    /// Top folder of the repo the worktree was made from. Worktree commands run here.
    var repo: String
    /// The worktree's top folder.
    var root: String
    /// Where the chat runs: the worktree's top folder, or the same subfolder the project is
    /// in, when the project is a folder inside the repo.
    var directory: String
    var branch: String

    var slug: String { (root as NSString).lastPathComponent }
}

enum WorktreeError: LocalizedError {
    case notARepo(String)
    case git(String)

    var errorDescription: String? {
        switch self {
        case .notARepo(let path): return "\((path as NSString).lastPathComponent) isn't in a git repository."
        case .git(let message): return message.isEmpty ? "git failed." : message
        }
    }
}

/// Worktree per chat. hantuu makes the worktree itself, so it works the same for every agent.
/// Nothing here runs unless the user asks for a worktree, and only in that chat's project.
enum Worktrees {
    static let gitPath = "/usr/bin/git"
    /// GIT_CEILING_DIRECTORIES for every git run. The self test sets it to its workdir, which
    /// sits inside hantuu's own checkout, so its git commands can never reach that repo.
    static var ceilingDirectories: String?

    /// Runs git in a folder. A GUI app's PATH is short, so the usual tool folders are added
    /// for git hooks (git-lfs and the like). Never prompts for credentials.
    @discardableResult
    static func run(_ args: [String], in dir: String, input: Data? = nil) -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":/opt/homebrew/bin:/usr/local/bin"
        env["GIT_TERMINAL_PROMPT"] = "0"
        if let c = ceilingDirectories { env["GIT_CEILING_DIRECTORIES"] = c }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = input.map { _ in Pipe() }
        p.standardInput = inPipe ?? FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "", "\(error)") }
        if let inPipe, let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.wait()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The top folder of the git repo `path` is in, or nil.
    static func repoRoot(of path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let r = run(["rev-parse", "--show-toplevel"], in: path)
        let top = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.code == 0 && !top.isEmpty ? top : nil
    }

    /// `chat-3f2a`, then longer prefixes of the chat id if that's taken.
    static func slugCandidates(for chatID: UUID) -> [String] {
        let hex = chatID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return [4, 6, 8, 12, 32].map { "chat-" + hex.prefix($0) }
    }

    static func create(projectPath: String, chatID: UUID) throws -> WorktreeInfo {
        guard let top = repoRoot(of: projectPath) else { throw WorktreeError.notARepo(projectPath) }
        // The project can be a folder inside the repo. The chat then runs in the same folder
        // of the worktree. git reports the top folder with symlinks resolved, so compare that way.
        let resolved = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath().path
        var rel = ""
        if resolved.hasPrefix(top + "/") { rel = String(resolved.dropFirst(top.count + 1)) }

        let base = top + "/.hantuu/worktrees"
        let fm = FileManager.default
        guard let slug = slugCandidates(for: chatID).first(where: { s in
            !fm.fileExists(atPath: base + "/" + s)
                && run(["show-ref", "--verify", "--quiet", "refs/heads/hantuu/" + s], in: top).code != 0
        }) else { throw WorktreeError.git("Couldn't find a free name for the worktree.") }

        try excludeHantuuFolder(repo: top)
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        let root = base + "/" + slug
        let branch = "hantuu/" + slug
        let r = run(["worktree", "add", "-b", branch, root], in: top)
        guard r.code == 0 else { throw WorktreeError.git(r.err) }
        let copied = copyIncludedFiles(repo: top, into: root)
        Log.write("worktree chat=\(chatID) root=\(root) branch=\(branch) copied=\(copied.count)")
        return WorktreeInfo(repo: top, root: root, directory: rel.isEmpty ? root : root + "/" + rel, branch: branch)
    }

    /// Off the main thread, with the result back on it.
    static func createAsync(projectPath: String, chatID: UUID, completion: @escaping (Result<WorktreeInfo, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try create(projectPath: projectPath, chatID: chatID) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Adds `.hantuu/` to the repo's own `info/exclude`, so the worktrees never show up in
    /// `git status`. `.gitignore` is left alone, since that's shared with everyone.
    static func excludeHantuuFolder(repo: String) throws {
        let r = run(["rev-parse", "--git-common-dir"], in: repo)
        guard r.code == 0 else { throw WorktreeError.git(r.err) }
        var common = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if !common.hasPrefix("/") { common = repo + "/" + common }
        let info = common + "/info"
        try FileManager.default.createDirectory(atPath: info, withIntermediateDirectories: true)
        let file = info + "/exclude"
        let existing = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let lines = existing.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(".hantuu/") || lines.contains("/.hantuu/") { return }
        let addition = (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + "# hantuu chat worktrees\n.hantuu/\n"
        try (existing + addition).write(toFile: file, atomically: true, encoding: .utf8)
    }

    /// Copies files named in `.worktreeinclude` at the repo's top (gitignore syntax) that git
    /// ignores, such as `.env`, into the new worktree. Tracked files are there already, and
    /// untracked files git doesn't ignore are left out. Returns the copied paths.
    @discardableResult
    static func copyIncludedFiles(repo: String, into root: String) -> [String] {
        let include = repo + "/.worktreeinclude"
        guard FileManager.default.fileExists(atPath: include) else { return [] }
        let listed = run(["ls-files", "--others", "--ignored", "--exclude-from=" + include, "-z"], in: repo).out
            .split(separator: "\0").map(String.init)
            .filter { !$0.hasPrefix(".hantuu/") }
        guard !listed.isEmpty else { return [] }
        let input = Data(listed.joined(separator: "\0").utf8 + [0])
        let ignored = Set(run(["check-ignore", "--stdin", "-z"], in: repo, input: input).out.split(separator: "\0").map(String.init))
        var copied: [String] = []
        let fm = FileManager.default
        for rel in listed where ignored.contains(rel) {
            let dst = root + "/" + rel
            guard !fm.fileExists(atPath: dst) else { continue }
            try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if (try? fm.copyItem(atPath: repo + "/" + rel, toPath: dst)) != nil { copied.append(rel) }
        }
        return copied
    }

    /// Uncommitted changes, untracked files included (removing the worktree would lose them).
    static func isDirty(_ wt: WorktreeInfo) -> Bool {
        guard FileManager.default.fileExists(atPath: wt.root) else { return false }
        let r = run(["status", "--porcelain"], in: wt.root)
        return r.code != 0 || !r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Commits on the chat's branch that no other branch or remote has.
    static func unmergedCommits(_ wt: WorktreeInfo) -> Int {
        let short = wt.branch
        let r = run(["rev-list", "--count", "refs/heads/" + short, "--not", "--exclude=" + short, "--branches", "--remotes"], in: wt.repo)
        return r.code == 0 ? Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
    }

    enum RemoveResult: Equatable {
        case removed
        /// The worktree went, but git kept the branch because it has commits nowhere else.
        case removedKeptBranch
        /// Refused: the worktree has uncommitted changes.
        case dirty
        case failed(String)
    }

    /// Deletes the worktree and its branch. Without `force` it refuses when there are
    /// uncommitted changes, and keeps a branch whose commits aren't anywhere else.
    static func remove(_ wt: WorktreeInfo, force: Bool) -> RemoveResult {
        if !force && isDirty(wt) { return .dirty }
        if FileManager.default.fileExists(atPath: wt.root) {
            let r = run(["worktree", "remove"] + (force ? ["--force"] : []) + [wt.root], in: wt.repo)
            if r.code != 0 { return .failed(r.err) }
        } else {
            run(["worktree", "prune"], in: wt.repo)
        }
        let flag = force || unmergedCommits(wt) == 0 ? "-D" : "-d"
        let b = run(["branch", flag, wt.branch], in: wt.repo)
        return b.code == 0 ? .removed : .removedKeptBranch
    }
}
