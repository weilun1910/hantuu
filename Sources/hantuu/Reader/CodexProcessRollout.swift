import Darwin
import Foundation

/// Finds rollouts held for writing by this terminal's main Codex process.
/// No file contents, arguments, environment variables, or unrelated processes are read.
enum CodexProcessRollout {
    private static let maximumProcesses = 32
    private static let maximumDepth = 4
    private static let maximumDescriptors = 4096

    struct ProcessIdentity: Equatable {
        var pid: Int32
        var parentPID: Int32
        var executable: String
        var startSeconds: UInt64
        var startMicroseconds: UInt64
    }

    static func paths(rootPID: Int32, sessionsRoot: URL) -> [URL] {
        let processes = mainProcesses(rootPID: rootPID, identity: identity, children: children)
        // An unexpected launcher tree is not sufficient evidence to switch chats.
        guard processes.count == 1, let process = processes.first else { return [] }
        let paths = writablePaths(pid: process.pid, sessionsRoot: sessionsRoot)
        // Discard a snapshot if the PID exited, was reused, or exec'd during inspection.
        guard identity(process.pid) == process else { return [] }
        return paths
    }

    /// Injectable process snapshots keep traversal behavior testable without real processes.
    static func mainProcesses(
        rootPID: Int32,
        identity: (Int32) -> ProcessIdentity?,
        children: (Int32) -> [Int32]
    ) -> [ProcessIdentity] {
        guard rootPID > 0 else { return [] }
        var queue: [(pid: Int32, parent: Int32?, depth: Int)] = [(rootPID, nil, 0)]
        var seen = Set<Int32>()
        var result: [ProcessIdentity] = []
        var index = 0
        while index < queue.count, index < maximumProcesses {
            let entry = queue[index]
            index += 1
            guard seen.insert(entry.pid).inserted,
                  let process = identity(entry.pid), process.pid == entry.pid,
                  entry.parent == nil || process.parentPID == entry.parent else { continue }
            let name = URL(fileURLWithPath: process.executable).lastPathComponent
            if isCodexExecutable(name) {
                result.append(process)
                // Codex's tools and subagents are never traversed.
                continue
            }
            guard isLauncherExecutable(name), entry.depth < maximumDepth else { continue }
            let descendants = children(entry.pid).filter { $0 > 0 && !seen.contains($0) }
            guard queue.count + descendants.count <= maximumProcesses else { return [] }
            queue.append(contentsOf: descendants.map { ($0, entry.pid, entry.depth + 1) })
        }
        return result
    }

    static func isCodexExecutable(_ name: String) -> Bool {
        ["codex", "codex-aarch64-apple-darwin", "codex-x86_64-apple-darwin"].contains(name)
    }

    static func isLauncherExecutable(_ name: String) -> Bool {
        ["node", "nodejs", "sh", "bash", "zsh", "dash", "fish", "env"].contains(name)
    }

    static func rolloutPath(_ path: String, openFlags: UInt32, sessionsRoot: URL) -> URL? {
        // libproc reports kernel FREAD/FWRITE bits, not open(2)'s O_ACCMODE.
        guard openFlags & UInt32(FWRITE) != 0, path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let root = sessionsRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard url.path.hasPrefix(prefix),
              url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else { return nil }
        return url
    }

    private static func identity(_ pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var path = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
        let count = path.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard count > 0, path.contains(0) else { return nil }
        return ProcessIdentity(pid: pid, parentPID: Int32(info.pbi_ppid),
                               executable: String(cString: path),
                               startSeconds: info.pbi_start_tvsec,
                               startMicroseconds: info.pbi_start_tvusec)
    }

    private static func children(_ pid: Int32) -> [Int32] {
        var pids = [Int32](repeating: 0, count: maximumProcesses)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), $0.baseAddress, Int32($0.count))
        }
        // Reject truncated snapshots instead of choosing an arbitrary branch.
        guard bytes > 0, bytes < Int32(pids.count * MemoryLayout<Int32>.stride) else { return [] }
        return Array(pids.prefix(Int(bytes) / MemoryLayout<Int32>.stride)).filter { $0 > 0 }
    }

    private static func writablePaths(pid: Int32, sessionsRoot: URL) -> [URL] {
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: maximumDescriptors)
        let bytes = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        let stride = MemoryLayout<proc_fdinfo>.stride
        guard bytes > 0, bytes < Int32(descriptors.count * stride) else { return [] }
        var paths = Set<URL>()
        for descriptor in descriptors.prefix(Int(bytes) / stride)
            where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path: String? = withUnsafeBytes(of: &info.pvip.vip_path) { bytes in
                guard let end = bytes.firstIndex(of: 0) else { return nil }
                return String(bytes: bytes[..<end], encoding: .utf8)
            }
            if let path, let url = rolloutPath(path, openFlags: info.pfi.fi_openflags, sessionsRoot: sessionsRoot) {
                paths.insert(url)
            }
        }
        return paths.sorted { $0.path < $1.path }
    }
}
