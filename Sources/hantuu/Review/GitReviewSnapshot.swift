import Foundation
import CryptoKit

/// A failed read never becomes an empty successful review.
struct PanelReadState: Equatable {
    var loading = false
    var lastSuccess: Date?
    var error: String?
    var label: String {
        if loading { return lastSuccess == nil ? "Loading" : "Refreshing" }
        if error != nil { return lastSuccess == nil ? "Unavailable" : "Stale" }
        return lastSuccess == nil ? "Not loaded" : "Current"
    }
}

struct GitReviewError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

struct GitReviewSelection: Codable, Equatable {
    var target: String?
    var targetRevision: String?
    var commit: String?
    var checkout: String?

    static func load(_ root: String) -> Self {
        guard let data = try? Data(contentsOf: url(root)), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(_ root: String) {
        let url = Self.url(root)
        Paths.ensure(url.deletingLastPathComponent())
        var value = self
        if value.checkout == nil { value.checkout = Self.load(root).checkout }
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func url(_ root: String) -> URL {
        Paths.dataDir.appendingPathComponent("review-selection").appendingPathComponent(GitReviewSnapshot.hash(Data(root.utf8)) + ".json")
    }
}

struct GitReviewSnapshot {
    var info: RepoInfo
    var scope: DiffBase
    var selection: GitReviewSelection
    var baseRevision: String
    var headRevision: String
    var tipRevision: String?
    var files: [ChangedFile]
    var uncommitted: [ChangedFile]
    var staged: [ChangedFile]
    var overviewSummary: ChangeSummary
    var revision: String
    var fingerprints: [String: String]
    var refs: [String]
    var commits: [String]
    var worktrees: [String]
    var remotes: [String]
    var remoteURLs: [String: String]
    var remotePushURLs: [String: String]
    var upstream: String?
    var ahead: Int?
    var behind: Int?
    var truncated: Bool

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func checked(_ args: [String], root: String, env: [String: String] = [:], timeout: TimeInterval = 15) throws -> Git.Result {
        let r = Git.run(["--literal-pathspecs"] + args, in: root, timeout: timeout, extraEnv: env)
        guard r.ok else { throw GitReviewError(message: r.err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Git failed: \(args.first ?? "read") (\(r.status))." : r.err) }
        return r
    }

    /// Each operation owns its index copy. A second refresh must never replace the
    /// index underneath an in-flight scan, and reads must not refresh the real index.
    static func withReadOnlyIndex<T>(root: String, _ body: ([String: String]) throws -> T) throws -> T {
        let path = try checked(["rev-parse", "--git-path", "index"], root: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = path.hasPrefix("/") ? path : (root as NSString).appendingPathComponent(path)
        let directory = Paths.dataDir.appendingPathComponent("review-index", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = directory.appendingPathComponent(UUID().uuidString + ".index")
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(atPath: copy.path + ".lock")
        }
        if FileManager.default.fileExists(atPath: source) {
            let data = try Data(contentsOf: URL(fileURLWithPath: source))
            guard FileManager.default.createFile(atPath: copy.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw GitReviewError(message: "Could not copy the Git index for a read-only review.")
            }
        }
        return try body(["GIT_INDEX_FILE": copy.path])
    }

    static func emptyTree(root: String) throws -> String {
        try checked(["hash-object", "-t", "tree", "/dev/null"], root: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func resolve(_ ref: String, root: String) throws -> String {
        try checked(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], root: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Includes index-only changes and full untracked contents, not just timestamps/counts.
    static func checkoutRevision(_ repo: RepoInfo, env: [String: String]? = nil) throws -> String {
        guard let env else {
            return try withReadOnlyIndex(root: repo.root) { try checkoutRevision(repo, env: $0) }
        }
        var bytes = Data()
        bytes.append(Data(((try? resolve("HEAD", root: repo.root)) ?? "unborn").utf8))
        for args in [["diff", "--binary", "--no-ext-diff", "--no-textconv", "--cached", "--"],
                     ["diff", "--binary", "--no-ext-diff", "--no-textconv", "--"],
                     ["status", "--porcelain=v1", "-z", "--untracked-files=all"]] {
            bytes.append(try checked(args, root: repo.root, env: env).out)
        }
        let untracked = try checked(["ls-files", "--others", "--exclude-standard", "-z"], root: repo.root, env: env)
        for path in GitParse.split0(untracked.out).sorted() {
            bytes.append(Data(path.utf8))
            let url = URL(fileURLWithPath: repo.root).appendingPathComponent(path)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            bytes.append(Data("|\(attrs[.type] ?? "")|\(attrs[.posixPermissions] ?? "")|".utf8))
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                bytes.append(Data(target.utf8))
            } else {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var digest = SHA256()
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
                bytes.append(Data(digest.finalize()))
            }
        }
        return hash(bytes)
    }

    static func diffArguments(scope: DiffBase, base: String, tip: String?) -> [String] {
        switch scope {
        case .unstaged: return []
        case .staged: return ["--cached", base]
        case .branch, .commit: return [base, tip ?? "HEAD"]
        case .uncommitted: return [base]
        }
    }

    func diff(_ file: ChangedFile, context: Int = 3) throws -> String {
        let common = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/", "-U\(context)"]
        if file.isUntracked {
            let r = Git.run(common + ["--no-index", "--", "/dev/null", file.path], in: info.root)
            guard r.status == 0 || r.status == 1 else { throw GitReviewError(message: r.err) }
            return r.text
        }
        return try Self.withReadOnlyIndex(root: info.root) { env in
            try Self.checked(common + ["-M"] + Self.diffArguments(scope: scope, base: baseRevision, tip: tipRevision) + ["--"] + ([file.oldPath].compactMap { $0 } + [file.path]), root: info.root, env: env).text
        }
    }

    static func load(root: String, scope: DiffBase, selection supplied: GitReviewSelection) throws -> Self {
        try withReadOnlyIndex(root: root) { env in try load(root: root, scope: scope, selection: supplied, env: env) }
    }

    private static func load(root: String, scope: DiffBase, selection supplied: GitReviewSelection, env: [String: String]) throws -> Self {
        guard let repo = RepoInfo.load(folder: root) else { throw GitReviewError(message: "The checkout is unavailable or is not a Git repository.") }
        let revision = try checkoutRevision(repo, env: env)
        var selection = supplied
        let head = repo.headExists ? try resolve("HEAD", root: root) : try emptyTree(root: root)
        var base = head
        var tip: String?
        if scope == .branch {
            guard let target = selection.target ?? repo.defaultBranch else { throw GitReviewError(message: "Choose a target branch. Git has no default branch for this checkout.") }
            let revision = try resolve(target, root: root)
            selection.target = target
            selection.targetRevision = revision
            base = try checked(["merge-base", head, revision], root: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else { throw GitReviewError(message: "No merge base exists for the selected target.") }
            tip = head
        } else if scope == .commit {
            let commit = try resolve(selection.commit ?? "HEAD", root: root)
            selection.commit = commit
            tip = commit
            if let parent = try? resolve(commit + "^", root: root) { base = parent }
            else { base = try emptyTree(root: root) }
        }
        let args = diffArguments(scope: scope, base: base, tip: tip)
        let ns = try checked(["diff", "--name-status", "-z", "-M", "--no-ext-diff", "--no-textconv"] + args + ["--"], root: root, env: env)
        var files = GitParse.nameStatus(ns.out)
        let status = try checked(["status", "--porcelain=v1", "-z", "--untracked-files=all"], root: root, env: env)
        let unc = GitParse.status(status.out)
        if scope == .unstaged || scope == .uncommitted { files += unc.filter(\.isUntracked) }
        let conflicts = Set(unc.filter { $0.status == "U" }.map(\.path))
        files = Array(Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, second in
            first.status == "U" ? first : second
        }).values)
        if scope == .unstaged || scope == .staged || scope == .uncommitted {
            for i in files.indices where conflicts.contains(files[i].path) { files[i].status = "U" }
        }
        let num = try checked(["diff", "--numstat", "-z", "-M", "--no-ext-diff", "--no-textconv"] + args + ["--"], root: root, env: env)
        let counts = Dictionary(GitParse.numstat(num.out).map { ($0.path, $0) }, uniquingKeysWith: { _, b in b })
        for i in files.indices {
            if let count = counts[files[i].path] { files[i].added = count.added; files[i].deleted = count.deleted }
            else if files[i].isUntracked { files[i].added = GitParse.countLines(atPath: (root as NSString).appendingPathComponent(files[i].path)); files[i].deleted = 0 }
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let staged = GitParse.nameStatus(try checked(["diff", "--cached", "--name-status", "-z", "-M", head, "--"], root: root, env: env).out)
        // Overview retains the full branch-plus-working-tree aggregate regardless of
        // the review pane's staged/unstaged/commit filter.
        let overviewBase = scope == .branch ? base : (repo.mergeBase ?? head)
        let overviewEntries = GitParse.numstat(try checked(["diff", "--numstat", "-z", "-M", "--no-ext-diff", "--no-textconv", overviewBase, "--"], root: root, env: env).out)
        let overviewCounts = Array(Dictionary(overviewEntries.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last }).values)
        let overviewPaths = Set(overviewCounts.map(\.path))
        let overviewNew = unc.filter { $0.isUntracked && !overviewPaths.contains($0.path) }
        let overview = ChangeSummary(files: overviewCounts.count + overviewNew.count,
                                     added: overviewCounts.reduce(0) { $0 + ($1.added ?? 0) } + overviewNew.reduce(0) { $0 + (GitParse.countLines(atPath: (root as NSString).appendingPathComponent($1.path)) ?? 0) },
                                     deleted: overviewCounts.reduce(0) { $0 + ($1.deleted ?? 0) })
        let refs = try checked(["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"], root: root).text.split(separator: "\n").map(String.init)
        let commits = repo.headExists ? try checked(["log", "-50", "--format=%H %s"], root: root).text.split(separator: "\n").map(String.init) : []
        let worktrees = GitParse.split0(try checked(["worktree", "list", "--porcelain", "-z"], root: root).out).filter { $0.hasPrefix("worktree ") }.map { String($0.dropFirst(9)) }
        let remotes = try checked(["remote"], root: root).text.split(separator: "\n").map(String.init)
        var remoteURLs: [String: String] = [:]
        var remotePushURLs: [String: String] = [:]
        for remote in remotes {
            remoteURLs[remote] = try checked(["remote", "get-url", remote], root: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
            remotePushURLs[remote] = try checked(["remote", "get-url", "--push", "--all", remote], root: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let upstream = Git.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let distance = upstream.isEmpty ? [] : Git.run(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], in: root).text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        var result = Self(info: repo, scope: scope, selection: selection, baseRevision: base, headRevision: head, tipRevision: tip, files: Array(files.prefix(ChangeScanner.maxFiles)), uncommitted: unc, staged: staged, overviewSummary: overview, revision: revision, fingerprints: [:], refs: refs, commits: commits, worktrees: worktrees, remotes: remotes, remoteURLs: remoteURLs, remotePushURLs: remotePushURLs, upstream: upstream.isEmpty ? nil : upstream, ahead: distance.first, behind: distance.count == 2 ? distance[1] : nil, truncated: files.count > ChangeScanner.maxFiles)
        // Bind marks to the full checkout revision and comparison. Other edits conservatively invalidate them.
        for file in result.files {
            result.fingerprints[file.path] = hash(Data((scope.rawValue + "|" + base + "|" + (tip ?? "") + "|" + revision + "|" + file.path).utf8))
        }
        guard try checkoutRevision(repo) == revision else { throw GitReviewError(message: "The checkout changed during the scan. Refresh to review its current revision.") }
        return result
    }
}

extension DiffBase {
    var title: String {
        switch self {
        case .uncommitted: return "All local"
        case .unstaged: return "Unstaged"
        case .staged: return "Staged"
        case .branch: return "Branch"
        case .commit: return "Commit"
        }
    }
}
