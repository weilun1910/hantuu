import Darwin
import Foundation

/// A TCP port something is listening on, from a process working inside the chat's folder.
struct ListeningPort: Equatable, Identifiable {
    var port: Int
    var pid: Int32
    var command: String
    var id: Int { port }
}

enum Ports {
    struct Listener: Equatable {
        var pid: Int32
        var command: String
        var port: Int
    }

    /// `lsof -nP -iTCP -sTCP:LISTEN -F pcn`: "p<pid>", "c<command>", "n<address:port>" lines.
    static func parseLsof(_ text: String) -> [Listener] {
        var out: [Listener] = []
        var pid: Int32 = 0
        var cmd = ""
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p": pid = Int32(value) ?? 0; cmd = ""
            case "c": cmd = String(value)
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]), pid > 0 else { continue }
                if seen.insert("\(pid):\(port)").inserted { out.append(Listener(pid: pid, command: cmd, port: port)) }
            default: break
            }
        }
        return out
    }

    /// True when `cwd` is the folder itself or somewhere inside it.
    static func isInside(_ cwd: String, folder: String) -> Bool {
        let f = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return cwd == f || cwd.hasPrefix(f + "/")
    }

    static func match(_ listeners: [Listener], folder: String, cwd: (Int32) -> String?) -> [ListeningPort] {
        let want = URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path
        var byPort: [Int: ListeningPort] = [:]
        for l in listeners where byPort[l.port] == nil {
            guard let dir = cwd(l.pid), isInside(dir, folder: want) else { continue }
            byPort[l.port] = ListeningPort(port: l.port, pid: l.pid, command: l.command)
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    /// A process's current working directory, straight from the kernel.
    static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    static func listening(in folder: String) -> [ListeningPort] {
        let r = Process.capture("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"], in: nil, timeout: 6)
        return match(parseLsof(r.text), folder: folder, cwd: cwd(of:))
    }
}
