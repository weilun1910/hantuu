import Foundation

/// Runs git as a read-only observer of the chat's folder. Every call sets GIT_OPTIONAL_LOCKS=0
/// so a refresh never takes the index lock away from the agent or the user, and passes config
/// that neutralises user settings which would change the output format (colour, prefixes,
/// external diff tools, quoted paths). Only `revert` changes anything, and only after the user
/// confirms it.
enum Git {
    struct Result {
        var status: Int32
        var out: Data
        var err: String
        var text: String { String(decoding: out, as: UTF8.self) }
        var ok: Bool { status == 0 }
    }

    static let executable = "/usr/bin/git"
    /// Git's well-known empty tree, the base for a repository with no commits yet.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    static let baseConfig = [
        "-c", "core.quotepath=off", "-c", "color.ui=never", "-c", "diff.noprefix=false",
        "-c", "diff.mnemonicPrefix=false", "-c", "diff.external=", "-c", "core.fsmonitor=false",
    ]

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        env["LC_ALL"] = "C"
        env.removeValue(forKey: "GIT_DIR")
        env.removeValue(forKey: "GIT_WORK_TREE")
        env.removeValue(forKey: "GIT_INDEX_FILE")
        return env
    }

    @discardableResult
    static func run(_ args: [String], in dir: String, timeout: TimeInterval = 15, extraEnv: [String: String] = [:]) -> Result {
        Process.capture(executable, baseConfig + args, in: dir, env: environment.merging(extraEnv) { $1 }, timeout: timeout)
    }

    /// Environment that points git at a private copy of the repository's index. `git diff`
    /// against the working tree can rewrite the index to refresh stat info (and take
    /// index.lock to do it) whatever GIT_OPTIONAL_LOCKS says, which could make an agent's own
    /// `git commit` fail. Reads go through the copy, so the real index is never written or
    /// locked. Empty when the repo has no index yet.
    static func readOnlyIndex(root: String) -> [String: String] {
        let p = run(["rev-parse", "--git-path", "index"], in: root, timeout: 5).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return [:] }
        let index = p.hasPrefix("/") ? p : (root as NSString).appendingPathComponent(p)
        let fm = FileManager.default
        guard fm.fileExists(atPath: index) else { return [:] }
        let dir = Paths.dataDir.appendingPathComponent("git-index", isDirectory: true)
        Paths.ensure(dir)
        var hash: UInt64 = 5381
        for b in root.utf8 { hash = (hash &* 33) &+ UInt64(b) }
        let copy = dir.appendingPathComponent(String(hash, radix: 16) + ".index")
        try? fm.removeItem(at: copy)
        // A plain data copy, not a clone: cloning the index posts an FSEvent on the real
        // index, which woke the folder watcher and started another refresh, forever.
        guard copyfile(index, copy.path, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else { return [:] }
        return ["GIT_INDEX_FILE": copy.path]
    }
}

extension Process {
    /// Runs a program to completion with stdin closed, collecting stdout and stderr. Kills it
    /// (only this child, by its own pid) if it outlives the timeout.
    static func capture(_ exe: String, _ args: [String], in dir: String?, env: [String: String]? = nil, timeout: TimeInterval) -> Git.Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let dir { p.currentDirectoryURL = URL(fileURLWithPath: dir, isDirectory: true) }
        if let env { p.environment = env }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        // waitUntilExit polls the run loop and added about 65 ms to every call on a
        // background queue. The termination handler fires as soon as the child exits.
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch {
            return Git.Result(status: -1, out: Data(), err: "\(error)")
        }
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = group.wait(timeout: .now() + 1)
        }
        if exited.wait(timeout: .now() + 2) == .timedOut { p.waitUntilExit() }
        return Git.Result(status: p.terminationStatus, out: outData, err: String(decoding: errData, as: UTF8.self))
    }
}

// MARK: - Repository facts

struct RepoInfo: Equatable {
    var root: String
    var branch: String?          // nil when HEAD is detached
    var headExists: Bool         // false in a repository with no commits yet
    var isLinkedWorktree: Bool
    var defaultBranch: String?   // e.g. origin/main or main
    var mergeBase: String?       // merge base of HEAD with the default branch

    /// What the uncommitted view compares against.
    var headRef: String { headExists ? "HEAD" : Git.emptyTree }

    static func load(folder: String) -> RepoInfo? {
        let r = Git.run(["rev-parse", "--show-toplevel", "--git-dir", "--git-common-dir"], in: folder, timeout: 5)
        guard r.ok else { return nil }
        let lines = r.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3, !lines[0].isEmpty else { return nil }
        let root = lines[0]
        func absolute(_ p: String) -> String {
            let s = p.hasPrefix("/") ? p : (folder as NSString).appendingPathComponent(p)
            return URL(fileURLWithPath: s).standardizedFileURL.resolvingSymlinksInPath().path
        }
        let linked = absolute(lines[1]) != absolute(lines[2])
        let branch = Git.run(["symbolic-ref", "--short", "-q", "HEAD"], in: root, timeout: 5).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let headExists = Git.run(["rev-parse", "-q", "--verify", "HEAD^{commit}"], in: root, timeout: 5).ok
        var info = RepoInfo(root: root, branch: branch.isEmpty ? nil : branch, headExists: headExists,
                            isLinkedWorktree: linked, defaultBranch: nil, mergeBase: nil)
        if headExists, let def = defaultBranch(root: root) {
            info.defaultBranch = def
            let mb = Git.run(["merge-base", "HEAD", def], in: root, timeout: 5).text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !mb.isEmpty { info.mergeBase = mb }
        }
        return info
    }

    /// The remote's default branch if git knows it, else the first of main, master, trunk.
    static func defaultBranch(root: String) -> String? {
        let remote = Git.run(["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"], in: root, timeout: 5).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !remote.isEmpty { return remote }
        for name in ["origin/main", "origin/master", "main", "master", "trunk"] {
            let ref = name.hasPrefix("origin/") ? "refs/remotes/\(name)" : "refs/heads/\(name)"
            if Git.run(["rev-parse", "-q", "--verify", ref], in: root, timeout: 5).ok { return name }
        }
        return nil
    }
}

// MARK: - Changed files

enum DiffBase: String, Codable {
    case uncommitted, branch
}

struct ChangedFile: Identifiable, Equatable, Hashable {
    var path: String            // relative to the repository root
    var oldPath: String?        // for renames
    var status: Character       // M A D R ? U
    var added: Int?             // nil for binary files
    var deleted: Int?
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var directory: String {
        let d = (path as NSString).deletingLastPathComponent
        return d.isEmpty ? "" : d + "/"
    }
    var isUntracked: Bool { status == "?" }
}

struct ChangeSummary: Equatable {
    var files: Int
    var added: Int
    var deleted: Int
}

enum GitParse {
    /// `git status --porcelain=v1 -z`: "XY path\0", with "XY new\0old\0" for renames and copies.
    static func status(_ data: Data) -> [ChangedFile] {
        let fields = split0(data)
        var out: [ChangedFile] = []
        var i = 0
        while i < fields.count {
            let f = fields[i]
            i += 1
            guard f.count >= 4 else { continue }
            let chars = Array(f)
            let x = chars[0], y = chars[1]
            let path = String(chars[3...])
            var old: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                if i < fields.count { old = fields[i]; i += 1 }
            }
            out.append(ChangedFile(path: path, oldPath: old, status: letter(x: x, y: y), added: nil, deleted: nil))
        }
        return out
    }

    static func letter(x: Character, y: Character) -> Character {
        if x == "?" && y == "?" { return "?" }
        if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") { return "U" }
        if x == "R" || y == "R" { return "R" }
        if x == "C" || y == "C" { return "A" }
        if x == "D" || y == "D" { return "D" }
        if x == "A" { return "A" }
        return "M"
    }

    /// `git diff --name-status -z -M`: "M\0path\0", "R100\0old\0new\0".
    static func nameStatus(_ data: Data) -> [ChangedFile] {
        let fields = split0(data)
        var out: [ChangedFile] = []
        var i = 0
        while i < fields.count {
            let code = fields[i]
            i += 1
            guard let first = code.first else { continue }
            if first == "R" || first == "C" {
                guard i + 1 < fields.count else { break }
                let old = fields[i], new = fields[i + 1]
                i += 2
                out.append(ChangedFile(path: new, oldPath: first == "R" ? old : nil, status: first == "R" ? "R" : "A", added: nil, deleted: nil))
            } else {
                guard i < fields.count else { break }
                let p = fields[i]
                i += 1
                let s: Character = ["A", "D", "U"].contains(first) ? first : "M"
                out.append(ChangedFile(path: p, oldPath: nil, status: s, added: nil, deleted: nil))
            }
        }
        return out
    }

    struct NumstatEntry: Equatable {
        var path: String
        var oldPath: String?
        var added: Int?
        var deleted: Int?
    }

    /// `git diff --numstat -z -M`: "a\td\tpath\0", or "a\td\t\0old\0new\0" for renames.
    /// Binary files show "-\t-".
    static func numstat(_ data: Data) -> [NumstatEntry] {
        let fields = split0(data)
        var out: [NumstatEntry] = []
        var i = 0
        while i < fields.count {
            let f = fields[i]
            i += 1
            let parts = f.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let a = Int(parts[0]), d = Int(parts[1])
            if parts[2].isEmpty {
                guard i + 1 < fields.count else { break }
                out.append(NumstatEntry(path: fields[i + 1], oldPath: fields[i], added: a, deleted: d))
                i += 2
            } else {
                out.append(NumstatEntry(path: String(parts[2]), oldPath: nil, added: a, deleted: d))
            }
        }
        return out
    }

    static func split0(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Lines in an untracked file, or nil if it looks binary or is too big to count.
    static func countLines(atPath path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.intValue, size <= 2_000_000,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        if data.isEmpty { return 0 }
        if data.prefix(8192).contains(0) { return nil }
        var n = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        if data.last != 0x0A { n += 1 }
        return n
    }
}

extension Array where Element == ChangedFile {
    var summary: ChangeSummary {
        ChangeSummary(files: count, added: reduce(0) { $0 + ($1.added ?? 0) }, deleted: reduce(0) { $0 + ($1.deleted ?? 0) })
    }
}

/// Reads the list of changed files. Nothing here writes to the repository: every command
/// runs against a private copy of the index (see Git.readOnlyIndex).
enum ChangeScanner {
    static let maxFiles = 2000

    static func uncommitted(_ repo: RepoInfo, env: [String: String]? = nil) -> [ChangedFile] {
        let env = env ?? Git.readOnlyIndex(root: repo.root)
        let st = Git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: repo.root, extraEnv: env)
        guard st.ok else { return [] }
        var files = GitParse.status(st.out)
        let num = Git.run(["diff", "--numstat", "-z", "-M", "--no-ext-diff", repo.headRef, "--"], in: repo.root, extraEnv: env)
        return merge(&files, numstat: GitParse.numstat(num.out), root: repo.root)
    }

    /// Everything on the branch since it left the default branch: committed work plus what's
    /// still uncommitted, plus untracked files.
    static func branch(_ repo: RepoInfo, base: String, env: [String: String]? = nil) -> [ChangedFile] {
        let env = env ?? Git.readOnlyIndex(root: repo.root)
        let ns = Git.run(["diff", "--name-status", "-z", "-M", "--no-ext-diff", base, "--"], in: repo.root, extraEnv: env)
        var files = GitParse.nameStatus(ns.out)
        let st = Git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: repo.root, extraEnv: env)
        let tracked = Set(files.map(\.path))
        files += GitParse.status(st.out).filter { $0.isUntracked && !tracked.contains($0.path) }
        let num = Git.run(["diff", "--numstat", "-z", "-M", "--no-ext-diff", base, "--"], in: repo.root, extraEnv: env)
        return merge(&files, numstat: GitParse.numstat(num.out), root: repo.root)
    }

    private static func merge(_ files: inout [ChangedFile], numstat: [GitParse.NumstatEntry], root: String) -> [ChangedFile] {
        var counts: [String: GitParse.NumstatEntry] = [:]
        for n in numstat { counts[n.path] = n }
        for i in files.indices {
            if let n = counts[files[i].path] {
                files[i].added = n.added
                files[i].deleted = n.deleted
                if files[i].oldPath == nil, let old = n.oldPath { files[i].oldPath = old }
            } else if files[i].isUntracked, i < maxFiles {
                let abs = (root as NSString).appendingPathComponent(files[i].path)
                if let lines = GitParse.countLines(atPath: abs) {
                    files[i].added = lines
                    files[i].deleted = 0
                }
            } else if files[i].status == "D" {
                files[i].added = 0
            }
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return Array(files.prefix(maxFiles))
    }

    /// The unified diff for one file against the given base ("HEAD", the empty tree or a
    /// merge base). Untracked files are diffed against /dev/null.
    static func diff(_ file: ChangedFile, base: String, root: String, env: [String: String]? = nil) -> String {
        let common = ["--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "-U3"]
        if file.isUntracked {
            return Git.run(["diff"] + common + ["--no-index", "--", "/dev/null", file.path], in: root).text
        }
        var paths = [file.path]
        if let old = file.oldPath { paths.insert(old, at: 0) }
        return Git.run(["diff"] + common + ["-M", base, "--"] + paths, in: root, extraEnv: env ?? Git.readOnlyIndex(root: root)).text
    }

    /// Discards the uncommitted changes to one file, after the user confirmed it. Tracked
    /// files are restored from HEAD (index and working tree). Files that aren't in HEAD
    /// (untracked or newly added) are unstaged and moved to the Trash, never deleted outright.
    static func revert(_ file: ChangedFile, repo: RepoInfo) -> String? {
        let fm = FileManager.default
        let abs = (repo.root as NSString).appendingPathComponent(file.path)
        func trash(_ path: String) -> String? {
            guard fm.fileExists(atPath: path) else { return nil }
            do { try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) } catch { return "Couldn't move \((path as NSString).lastPathComponent) to the Trash." }
            return nil
        }
        if file.isUntracked { return trash(abs) }
        let inHead = repo.headExists && Git.run(["cat-file", "-e", "HEAD:\(file.path)"], in: repo.root, timeout: 5).ok
        if let old = file.oldPath, file.status == "R" {
            // A rename: bring the old file back and drop the new one.
            let r = Git.run(["restore", "--source=HEAD", "--staged", "--worktree", "--", old], in: repo.root)
            if !r.ok { return r.err.trimmingCharacters(in: .whitespacesAndNewlines) }
            _ = Git.run(["rm", "--cached", "--quiet", "--ignore-unmatch", "--", file.path], in: repo.root)
            return trash(abs)
        }
        if inHead {
            let r = Git.run(["restore", "--source=HEAD", "--staged", "--worktree", "--", file.path], in: repo.root)
            return r.ok ? nil : r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = Git.run(["rm", "--cached", "--quiet", "--ignore-unmatch", "--", file.path], in: repo.root)
        return trash(abs)
    }
}

// MARK: - Unified diff rows

struct DiffRow: Codable, Equatable {
    enum Kind: String, Codable { case hunk = "h", context = "c", add = "a", del = "d", note = "n" }
    var t: Kind
    var o: Int?      // old line number
    var n: Int?      // new line number
    var s: String    // text without the +/-/space prefix
}

struct ParsedDiff: Equatable {
    var rows: [DiffRow] = []
    var binary = false
    var added = 0
    var deleted = 0
}

enum DiffParser {
    static func parse(_ text: String) -> ParsedDiff {
        var d = ParsedDiff()
        var oldLine = 0, newLine = 0
        var inHunk = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if line.hasPrefix("@@") {
                // @@ -a,b +c,d @@ context
                inHunk = true
                let nums = line.split(separator: " ")
                if nums.count >= 3 {
                    oldLine = Int(nums[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    newLine = Int(nums[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                d.rows.append(DiffRow(t: .hunk, o: nil, n: nil, s: String(line)))
                continue
            }
            if !inHunk {
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { d.binary = true }
                continue
            }
            if line.hasPrefix("diff --git ") { inHunk = false; continue }
            guard let first = line.first else {
                // A blank line inside a hunk is an empty context line some tools emit.
                continue
            }
            let body = String(line.dropFirst())
            switch first {
            case " ":
                d.rows.append(DiffRow(t: .context, o: oldLine, n: newLine, s: body))
                oldLine += 1; newLine += 1
            case "+":
                d.rows.append(DiffRow(t: .add, o: nil, n: newLine, s: body))
                newLine += 1; d.added += 1
            case "-":
                d.rows.append(DiffRow(t: .del, o: oldLine, n: nil, s: body))
                oldLine += 1; d.deleted += 1
            case "\\":
                d.rows.append(DiffRow(t: .note, o: nil, n: nil, s: body.trimmingCharacters(in: .whitespaces)))
            default:
                break
            }
        }
        return d
    }
}
