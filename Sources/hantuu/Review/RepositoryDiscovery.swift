import Darwin
import Foundation

/// Finds the git repositories inside a chat's folder when the folder isn't in one itself, for
/// Changes, Files and Overview. The walk only lists folders. It never opens a file, follows a
/// symlink or enters a folder iCloud has evicted, so it can't make iCloud Drive download
/// anything. Git is asked about a folder only once the walk has seen a .git entry in it.
enum RepositoryDiscovery {
    /// The chat's folder is depth 0, so a repository four folders down is the deepest found.
    static let maxDepth = 4
    static let maxDirectories = 10_000
    /// Dependency and build folders: often huge, and full of other people's repositories.
    static let skipped: Set<String> = ["node_modules", ".build", "build", "build.noindex", "vendor", "Pods", "DerivedData", ".venv", "dist"]

    struct Repository: Identifiable, Equatable {
        /// The repository's root as git reports it.
        var root: String
        /// The root relative to the chat's folder, for example "👻 hantuu/app.nosync".
        var relativePath: String
        /// Linked worktrees of this repository inside the chat's folder. They're counted
        /// rather than listed, so one repository doesn't show up five times.
        var worktreeCount: Int
        var id: String { root }
    }

    struct Result {
        var repositories: [Repository] = []
        var directoriesVisited = 0
        var truncated = false
    }

    /// What git says about a folder with a .git entry.
    private struct Found {
        var root: String
        var relativePath: String
        var gitDir: String
        var commonDir: String
    }

    /// Callers check first that the folder isn't inside a repository.
    static func discover(folder: String) -> Result {
        var result = Result()
        var found: [Found] = []
        func walk(_ path: String, relative: String, depth: Int) {
            guard result.directoriesVisited < maxDirectories else { result.truncated = true; return }
            // A folder that can't be read (permissions) is skipped.
            guard let dir = opendir(path) else { return }
            result.directoriesVisited += 1
            var children: [String] = []
            var hasGit = false
            while let entry = readdir(dir) {
                let type = entry.pointee.d_type
                let name = withUnsafeBytes(of: entry.pointee.d_name) {
                    String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
                }
                // A .git folder is a repository; a .git file is a worktree or a submodule.
                // Symlinks are never followed, so a link back up the tree can't loop.
                if name == ".git" { hasGit = type == DT_DIR || type == DT_REG; continue }
                guard depth < maxDepth, type == DT_DIR, !name.hasPrefix("."), !skipped.contains(name) else { continue }
                children.append(name)
            }
            closedir(dir)
            // Nothing inside a repository is searched: its submodules and nested checkouts
            // belong to it.
            if hasGit, let repo = identify(path, relative: relative) {
                found.append(repo)
                return
            }
            for name in children.sorted() {
                let child = (path as NSString).appendingPathComponent(name)
                if isEvicted(child) { continue }
                walk(child, relative: relative.isEmpty ? name : relative + "/" + name, depth: depth + 1)
            }
        }
        walk(folder, relative: "", depth: 0)

        // Worktrees share their main repository's common git dir.
        let inside = canonical(folder) + "/"
        for members in Dictionary(grouping: found, by: \.commonDir).values {
            guard let main = members.first(where: { $0.gitDir == $0.commonDir })
                    ?? members.min(by: { $0.relativePath < $1.relativePath }) else { continue }
            var worktrees = Set(members.map(\.root)).subtracting([main.root])
            // Git's own list also finds worktrees in hidden folders like .claude/worktrees,
            // which the walk skips.
            let listed = Git.run(["worktree", "list", "--porcelain", "-z"], in: main.root, timeout: 5)
            for field in GitParse.split0(listed.out) where field.hasPrefix("worktree ") {
                let path = canonical(String(field.dropFirst("worktree ".count)))
                guard path != main.root, path.hasPrefix(inside), isDirectory(path) else { continue }
                worktrees.insert(path)
            }
            result.repositories.append(Repository(root: main.root, relativePath: main.relativePath, worktreeCount: worktrees.count))
        }
        result.repositories.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return result
    }

    /// One git call. A broken .git (a deleted worktree's file, say) isn't a repository, and
    /// the walk carries on into the folder instead.
    private static func identify(_ path: String, relative: String) -> Found? {
        let r = Git.run(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"], in: path, timeout: 5)
        let lines = r.text.split(separator: "\n").map(String.init)
        guard r.ok, lines.count == 3, canonical(lines[0]) == canonical(path) else { return nil }
        return Found(root: lines[0], relativePath: relative, gitDir: canonical(lines[1]), commonDir: canonical(lines[2]))
    }

    /// An evicted iCloud folder would have to be downloaded before it could be listed.
    private static func isEvicted(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
    }

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// Discovery results per working folder. Only touched on ReviewCenter's serial queue. The
/// folder watcher and Refresh clear an entry; git status is read fresh on every refresh.
final class RepositoryDiscoveryCache {
    private var entries: [String: RepositoryDiscovery.Result] = [:]

    func invalidate(_ folder: String) { entries[folder] = nil }

    func result(folder: String) -> RepositoryDiscovery.Result {
        if let cached = entries[folder] { return cached }
        let result = RepositoryDiscovery.discover(folder: folder)
        if entries.count >= 32 { entries.removeAll() }
        entries[folder] = result
        return result
    }
}

/// One discovered repository as of the last refresh.
struct RepositoryChanges: Identifiable, Equatable {
    var repository: RepositoryDiscovery.Repository
    var info: RepoInfo
    var uncommitted: [ChangedFile]
    /// Everything since the branch left the default branch, or the uncommitted changes when
    /// there's no default branch to compare with.
    var branch: [ChangedFile]
    var id: String { repository.id }
    var hasChanges: Bool { !uncommitted.isEmpty || !branch.isEmpty }

    /// Reads the repository's branch and changed files through a private copy of its index,
    /// like the single-repository Changes tab. Nothing in the repository is written.
    static func scan(_ repository: RepositoryDiscovery.Repository) -> RepositoryChanges? {
        guard let info = RepoInfo.load(folder: repository.root) else { return nil }
        let env = Git.readOnlyIndex(root: info.root)
        let uncommitted = ChangeScanner.uncommitted(info, env: env)
        let branch = info.mergeBase.map { ChangeScanner.branch(info, base: $0, env: env) } ?? uncommitted
        return RepositoryChanges(repository: repository, info: info, uncommitted: uncommitted, branch: branch)
    }

    /// Repositories with changes first, then by path.
    static func ordered(_ entries: [RepositoryChanges]) -> [RepositoryChanges] {
        entries.sorted {
            if $0.hasChanges != $1.hasChanges { return $0.hasChanges }
            return $0.repository.relativePath.localizedStandardCompare($1.repository.relativePath) == .orderedAscending
        }
    }
}
