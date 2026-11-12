import Foundation

/// The Files tab's tree. In a git repo it's what git tracks plus untracked files git doesn't
/// ignore; elsewhere it's a directory listing that skips the usual heavy folders.
final class FileNode: Identifiable {
    let name: String
    let path: String           // relative to the tree's root folder
    let isDirectory: Bool
    var children: [FileNode] = []
    var id: String { path }

    init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }
}

struct FileTree {
    let root: String
    let top: [FileNode]
    let fileCount: Int
    let truncated: Bool
    let fromGit: Bool

    static let maxFiles = 20_000
    static let skippedFolders: Set<String> = [".git", "node_modules", ".build"]

    /// Compatibility helpers for existing callers. UI reads use the throwing API.
    static func listFiles(folder: String, inRepo: Bool) -> (paths: [String], truncated: Bool) {
        (try? listFilesChecked(folder: folder, inRepo: inRepo)) ?? ([], false)
    }

    static func listFilesChecked(folder: String, inRepo: Bool) throws -> (paths: [String], truncated: Bool) {
        if inRepo {
            func read(_ args: [String]) throws -> Data {
                let result = Git.run(args, in: folder, timeout: 20)
                guard result.ok else { throw GitReviewError(message: result.err.isEmpty ? "Git could not list files." : result.err) }
                return result.out
            }
            let data = try read(["ls-files", "-co", "--exclude-standard", "-z"])
            var seen = Set(GitParse.split0(try read(["ls-files", "-d", "-z"])))
            let paths = GitParse.split0(data).filter { seen.insert($0).inserted }
            return (Array(paths.prefix(maxFiles)), paths.count > maxFiles)
        }
        return try walkChecked(folder)
    }

    static func walk(_ folder: String) -> (paths: [String], truncated: Bool) {
        (try? walkChecked(folder)) ?? ([], false)
    }

    static func walkChecked(_ folder: String) throws -> (paths: [String], truncated: Bool) {
        let base = URL(fileURLWithPath: folder, isDirectory: true)
        // Validate the root as well: enumeration can report nothing for a missing root.
        let attrs = try FileManager.default.attributesOfItem(atPath: folder)
        guard (attrs[.type] as? FileAttributeType) == .typeDirectory else {
            throw GitReviewError(message: "The selected folder is unavailable.")
        }
        var readError: Error?
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [], errorHandler: { _, error in
            readError = error
            return false
        }) else { throw GitReviewError(message: "Could not list this folder.") }
        var out: [String] = []
        let prefix = base.standardizedFileURL.path.count + 1
        for case let url as URL in e {
            let name = url.lastPathComponent
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true {
                if skippedFolders.contains(name) || values.isSymbolicLink == true { e.skipDescendants() }
                continue
            }
            if name == ".DS_Store" { continue }
            let path = url.standardizedFileURL.path
            guard path.count > prefix else { continue }
            out.append(String(path.dropFirst(prefix)))
            if out.count >= maxFiles { return (out, true) }
        }
        if let readError { throw readError }
        return (out, false)
    }

    static func build(root: String, paths: [String], truncated: Bool, fromGit: Bool) -> FileTree {
        let top = FileNode(name: "", path: "", isDirectory: true)
        var dirs: [String: FileNode] = ["": top]
        func dir(_ path: String) -> FileNode {
            if let d = dirs[path] { return d }
            let parent = dir((path as NSString).deletingLastPathComponent)
            let d = FileNode(name: (path as NSString).lastPathComponent, path: path, isDirectory: true)
            parent.children.append(d)
            dirs[path] = d
            return d
        }
        for p in paths where !p.isEmpty {
            let parent = dir((p as NSString).deletingLastPathComponent)
            parent.children.append(FileNode(name: (p as NSString).lastPathComponent, path: p, isDirectory: false))
        }
        func sort(_ n: FileNode) {
            n.children.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            for c in n.children where c.isDirectory { sort(c) }
        }
        sort(top)
        return FileTree(root: root, top: top.children, fileCount: paths.count, truncated: truncated, fromGit: fromGit)
    }

    struct Row: Identifiable, Equatable {
        var node: FileNode
        var depth: Int
        var id: String { node.path }
        static func == (a: Row, b: Row) -> Bool { a.node === b.node && a.depth == b.depth }
    }

    /// The rows to draw: expanded folders open, the rest closed.
    func rows(expanded: Set<String>) -> [Row] {
        var out: [Row] = []
        func add(_ nodes: [FileNode], _ depth: Int) {
            for n in nodes {
                out.append(Row(node: n, depth: depth))
                if n.isDirectory, expanded.contains(n.path) { add(n.children, depth + 1) }
            }
        }
        add(top, 0)
        return out
    }

    /// Files whose path contains every word of the filter, best matches (name hits) first.
    func matches(_ filter: String, limit: Int = 400) -> [FileNode] {
        let words = filter.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var nameHits: [FileNode] = [], pathHits: [FileNode] = []
        func visit(_ nodes: [FileNode]) {
            for n in nodes {
                if n.isDirectory { visit(n.children); continue }
                let p = n.path.lowercased()
                guard words.allSatisfy({ p.contains($0) }) else { continue }
                if words.allSatisfy({ n.name.lowercased().contains($0) }) { nameHits.append(n) } else { pathHits.append(n) }
            }
        }
        visit(top)
        let byDepth: (FileNode, FileNode) -> Bool = { ($0.path.count, $0.path) < ($1.path.count, $1.path) }
        return Array((nameHits.sorted(by: byDepth) + pathHits.sorted(by: byDepth)).prefix(limit))
    }
}
