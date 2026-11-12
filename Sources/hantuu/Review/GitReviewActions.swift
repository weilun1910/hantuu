import Foundation

struct GitReviewHunk: Identifiable, Equatable {
    var id: Int
    var header: String
    var patch: String
    var context: Int = 3

    /// Structural changes use the explicit file action. A hunk never falls back to a file.
    static func parse(_ patch: String, file: ChangedFile, context: Int = 3) -> [Self] {
        guard file.status == "M", file.oldPath == nil, !patch.contains("GIT binary patch"),
              !patch.contains("old mode "), !patch.contains("new mode "),
              !patch.contains("Subproject commit ") else { return [] }
        let lines = patch.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { $0.hasPrefix("@@ ") }) else { return [] }
        let mode = lines[..<first].first(where: { $0.hasPrefix("index ") })?.split(separator: " ").last
        guard mode == "100644" || mode == "100755" else { return [] }
        let preamble = lines[..<first].joined(separator: "\n") + "\n"
        let starts = lines.indices.filter { lines[$0].hasPrefix("@@ ") }
        return starts.enumerated().map { number, start in
            let end = number + 1 < starts.count ? starts[number + 1] : lines.count
            var text = lines[start..<end].joined(separator: "\n")
            if !text.hasSuffix("\n") { text += "\n" }
            return Self(id: number, header: lines[start], patch: preamble + text, context: context)
        }
    }
}

enum GitReviewAction {
    case stage(ChangedFile), unstage(ChangedFile), discard(ChangedFile)
    case stageHunk(GitReviewHunk), unstageHunk(GitReviewHunk), discardHunk(GitReviewHunk)
    case stageFiles([ChangedFile]), unstageFiles([ChangedFile])
    case commit(String), push(remote: String), pull(remote: String)
    case createPR(remote: String, base: String, title: String, body: String, draft: Bool)

    var title: String {
        switch self {
        case .stage: return "Stage file"
        case .unstage: return "Unstage file"
        case .discard: return "Discard unstaged file changes"
        case .stageHunk: return "Stage hunk"
        case .unstageHunk: return "Unstage hunk"
        case .discardHunk: return "Discard unstaged hunk"
        case .stageFiles: return "Stage visible files"
        case .unstageFiles: return "Unstage visible files"
        case .commit: return "Commit staged changes"
        case .push: return "Push branch"
        case .pull: return "Pull with fast-forward only"
        case .createPR: return "Create pull request"
        }
    }
}

/// Serializes all app Git mutations. Git still owns its index/ref locks; external agents
/// can race us, so we verify the complete reviewed revision immediately before each action.
enum GitReviewActions {
    static let queue = DispatchQueue(label: "hantuu.git.actions", qos: .userInitiated)
    struct Outcome {
        var message: String
        var backup: URL?
    }

    static func validate(_ snapshot: GitReviewSnapshot) throws {
        guard let current = RepoInfo.load(folder: snapshot.info.root), current.root == snapshot.info.root,
              current.branch == snapshot.info.branch else {
            throw GitReviewError(message: "The checkout or branch changed. Refresh before retrying.")
        }
        guard try GitReviewSnapshot.checkoutRevision(snapshot.info) == snapshot.revision else {
            throw GitReviewError(message: "The checkout changed since this review. Refresh and review the new revision before retrying.")
        }
        if snapshot.scope == .branch, let target = snapshot.selection.target, let oid = snapshot.selection.targetRevision,
           try GitReviewSnapshot.resolve(target, root: snapshot.info.root) != oid {
            throw GitReviewError(message: "The target branch moved. Refresh before retrying.")
        }
    }

    static func paths(_ files: [ChangedFile]) -> [String] {
        Array(Set(files.flatMap { [$0.oldPath, $0.path].compactMap { $0 } })).sorted()
    }

    static func run(_ action: GitReviewAction, snapshot: GitReviewSnapshot, file: ChangedFile? = nil) throws -> Outcome {
        try validate(snapshot)
        let root = snapshot.info.root
        func git(_ args: [String]) throws -> Git.Result { try GitReviewSnapshot.checked(args, root: root, timeout: 120) }
        func localScope(_ wanted: DiffBase) throws {
            guard snapshot.scope == wanted else { throw GitReviewError(message: "Switch to \(wanted.title) and review this change first.") }
        }
        func safeFiles(_ files: [ChangedFile]) throws {
            guard !files.isEmpty, files.allSatisfy({ $0.status != "U" && snapshot.files.contains($0) }) else {
                throw GitReviewError(message: "This selection changed or contains conflicts. Refresh and resolve conflicts first.")
            }
        }
        var backup: URL?
        var result: Git.Result
        switch action {
        case .stage(let f):
            try localScope(.unstaged); try safeFiles([f])
            result = try git(["add", "-A", "--"] + paths([f]))
        case .stageFiles(let files):
            try localScope(.unstaged); try safeFiles(files)
            result = try git(["add", "-A", "--"] + paths(files))
        case .unstage(let f):
            try localScope(.staged); try safeFiles([f])
            result = try unstage(paths([f]), snapshot: snapshot)
        case .unstageFiles(let files):
            try localScope(.staged); try safeFiles(files)
            result = try unstage(paths(files), snapshot: snapshot)
        case .discard(let f):
            try localScope(.unstaged); try safeFiles([f])
            backup = try preserve(files: [f], snapshot: snapshot)
            try validate(snapshot)
            if f.isUntracked {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: root).appendingPathComponent(f.path), resultingItemURL: nil)
                result = Git.Result(status: 0, out: Data(), err: "")
            } else { result = try git(["restore", "--worktree", "--"] + paths([f])) }
        case .stageHunk(let h), .unstageHunk(let h), .discardHunk(let h):
            guard let file else { throw GitReviewError(message: "Select the hunk's file first.") }
            try safeFiles([file])
            let current = try snapshot.diff(file, context: h.context)
            guard GitReviewHunk.parse(current, file: file, context: h.context).contains(h) else { throw GitReviewError(message: "This hunk is stale or needs a whole-file action. Refresh to review it again.") }
            var flags: [String]
            switch action {
            case .stageHunk: try localScope(.unstaged); flags = ["--cached"]
            case .unstageHunk: try localScope(.staged); flags = ["--cached", "--reverse"]
            default:
                try localScope(.unstaged); flags = ["--reverse"]
                backup = try preserve(files: [file], snapshot: snapshot)
            }
            let dir = Paths.dataDir.appendingPathComponent("review-patches")
            Paths.ensure(dir)
            let patch = dir.appendingPathComponent(UUID().uuidString + ".patch")
            try Data(h.patch.utf8).write(to: patch, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: patch.path)
            defer { try? FileManager.default.removeItem(at: patch) }
            _ = try git(["apply", "--check"] + flags + [patch.path])
            try validate(snapshot)
            result = try git(["apply"] + flags + [patch.path])
        case .commit(let message):
            guard !snapshot.staged.isEmpty, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitReviewError(message: "Stage files and enter a commit message first.") }
            result = try git(["commit", "-m", message])
        case .push(let remote), .pull(let remote):
            guard let branch = snapshot.info.branch, snapshot.remotes.contains(remote) else { throw GitReviewError(message: "Choose a remote and a named branch first.") }
            let currentURL = try git(["remote", "get-url", remote]).text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard currentURL == snapshot.remoteURLs[remote] else { throw GitReviewError(message: "The remote changed. Refresh and review its new URL first.") }
            switch action {
            case .push:
                let pushURL = try git(["remote", "get-url", "--push", "--all", remote]).text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard pushURL == snapshot.remotePushURLs[remote], pushURL.split(separator: "\n").count == 1 else {
                    throw GitReviewError(message: "The push destination changed or has multiple URLs. Choose a remote with one reviewed destination.")
                }
                let mirror = Git.run(["config", "--bool", "--get", "remote." + remote + ".mirror"], in: root)
                guard mirror.status <= 1, mirror.text.trimmingCharacters(in: .whitespacesAndNewlines) != "true" else {
                    throw GitReviewError(message: "This remote mirrors refs. Choose an ordinary remote for a single-branch push.")
                }
                // Pin the source OID so a concurrent agent commit cannot enter this push.
                result = try git(["push", "--no-follow-tags", "--", remote, snapshot.headRevision + ":refs/heads/" + branch])
                if snapshot.upstream == nil {
                    let trackingRef = "refs/remotes/" + remote + "/" + branch
                    let exists = Git.run(["rev-parse", "--verify", "--end-of-options", trackingRef], in: root).ok
                    if exists {
                        let tracking = Git.run(["branch", "--set-upstream-to=" + trackingRef, "--", branch], in: root)
                        result.out.append(tracking.out)
                        if !tracking.ok { result.err += "\nPushed successfully; upstream setup failed: " + tracking.err }
                    } else { result.err += "\nPushed successfully. The remote fetch mapping does not expose a tracking ref; upstream was not changed." }
                }
            default:
                guard snapshot.uncommitted.isEmpty else { throw GitReviewError(message: "Commit or stash local changes before pulling. Pull does not stash edits automatically.") }
                result = try git(["-c", "pull.rebase=false", "-c", "merge.autostash=false", "-c", "rebase.autoStash=false", "pull", "--ff-only", "--", remote, branch])
            }
        case .createPR(let remote, let base, let title, let body, let draft):
            guard let gh = GitHubCLI.path else { throw GitReviewError(message: "Install gh to create a pull request. No sign-in was started.") }
            guard let branch = snapshot.info.branch, snapshot.remotes.contains(remote), !base.isEmpty, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitReviewError(message: "Choose a remote, base, branch and PR title first.") }
            let remoteURL = try git(["remote", "get-url", remote]).text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard remoteURL == snapshot.remoteURLs[remote] else { throw GitReviewError(message: "The remote changed. Refresh and review its new URL first.") }
            let head = snapshot.headRevision
            let remoteHead = try git(["ls-remote", "--heads", remote, "refs/heads/" + branch]).text.split(whereSeparator: \.isWhitespace).first.map(String.init)
            guard remoteHead == head else { throw GitReviewError(message: "Push this branch first. PR creation never pushes implicitly.") }
            let dir = Paths.dataDir.appendingPathComponent("review-patches")
            Paths.ensure(dir)
            let bodyURL = dir.appendingPathComponent(UUID().uuidString + ".txt")
            try Data(body.utf8).write(to: bodyURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bodyURL.path)
            defer { try? FileManager.default.removeItem(at: bodyURL) }
            try validate(snapshot)
            var args = ["pr", "create", "--repo", remoteURL, "--head", branch, "--base", base, "--title", title, "--body-file", bodyURL.path]
            if draft { args.append("--draft") }
            var env = Git.environment
            env["GH_PROMPT_DISABLED"] = "1"
            env["GH_NO_UPDATE_NOTIFIER"] = "1"
            result = Process.capture(gh, args, in: root, env: env, timeout: 60)
            guard result.ok else { throw GitReviewError(message: result.err) }
        }
        let output = (result.text + "\n" + result.err).trimmingCharacters(in: .whitespacesAndNewlines)
        return Outcome(message: output.isEmpty ? action.title + " completed." : output, backup: backup)
    }

    private static func unstage(_ paths: [String], snapshot: GitReviewSnapshot) throws -> Git.Result {
        let args = snapshot.info.headExists ? ["restore", "--staged", "--source=HEAD", "--"] : ["rm", "--cached", "--quiet", "--"]
        return try GitReviewSnapshot.checked(args + paths, root: snapshot.info.root)
    }

    /// Keep the exact files and both patches before discard. Restoration is an explicit
    /// user decision because another process may have edited the checkout since then.
    static func preserve(files: [ChangedFile], snapshot: GitReviewSnapshot) throws -> URL {
        let fm = FileManager.default
        let folder = Paths.dataDir.appendingPathComponent("review-recovery").appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let selected = paths(files)
        for (i, path) in selected.enumerated() {
            let source = URL(fileURLWithPath: snapshot.info.root).appendingPathComponent(path)
            if (try? fm.attributesOfItem(atPath: source.path)) != nil { try fm.copyItem(at: source, to: folder.appendingPathComponent("file-\(i)")) }
        }
        let metadata = ["root": snapshot.info.root, "revision": snapshot.revision, "paths": selected.joined(separator: "\n")]
        try JSONEncoder().encode(metadata).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        for (name, args) in [("unstaged.patch", ["diff", "--binary", "--no-ext-diff", "--no-textconv", "--"]), ("staged.patch", ["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", "--"])] {
            try GitReviewSnapshot.checked(args + selected, root: snapshot.info.root).out.write(to: folder.appendingPathComponent(name), options: .atomic)
        }
        return folder
    }
}
