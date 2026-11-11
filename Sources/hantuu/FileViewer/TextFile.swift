import Darwin
import Foundation

/// Enough of a file's identity to notice that it changed on disk: its inode (an atomic save
/// makes a new one), size and modification time.
struct FileFingerprint: Equatable {
    var inode: UInt64
    var size: Int64
    var mtime: timespec

    static func == (a: FileFingerprint, b: FileFingerprint) -> Bool {
        a.inode == b.inode && a.size == b.size && a.mtime.tv_sec == b.mtime.tv_sec && a.mtime.tv_nsec == b.mtime.tv_nsec
    }

    /// Follows a symlink to the file it points at. Nil when there's no file.
    static func of(_ path: String) -> FileFingerprint? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return FileFingerprint(inode: UInt64(st.st_ino), size: Int64(st.st_size), mtime: st.st_mtimespec)
    }
}

/// Why a text file opens read-only.
enum ReadOnlyReason: Equatable {
    /// Bigger than the editor takes. Holds the file's size; only the start is shown.
    case large(Int64)
    /// Has NUL bytes.
    case binary
    /// Not UTF-8. Saving would change its encoding, so it isn't offered.
    case encoding
}

/// A text file as read from disk: what the editor starts from and what Save compares against.
struct TextLoad: Equatable {
    var text: String
    var readOnly: ReadOnlyReason?
    /// It started with a UTF-8 byte order mark, which saving keeps.
    var bom = false
    /// "\r\n" when the file uses Windows line endings, so the editor keeps them.
    var eol = "\n"
    var fingerprint: FileFingerprint?
}

enum TextFile {
    /// Files up to this size open in the editor.
    static let editableLimit: Int64 = 4_000_000
    /// How much of a bigger file is shown, read-only.
    static let previewBytes = 2_000_000

    static func read(_ path: String) -> TextLoad? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let fp = FileFingerprint.of(path)
        let size = fp?.size ?? 0
        let large = size > editableLimit
        guard var data = try? h.read(upToCount: large ? previewBytes : Int(editableLimit) + 1) else { return nil }
        var load = TextLoad(text: "", fingerprint: fp)
        if large { load.readOnly = .large(size) }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            load.bom = true
            data = data.dropFirst(3)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            load.text = String(data: data, encoding: .utf16) ?? ""
            load.readOnly = load.readOnly ?? .encoding
        } else if data.prefix(8192).contains(0) {
            load.text = String(decoding: data, as: UTF8.self)
            load.readOnly = load.readOnly ?? .binary
        } else if let s = utf8(data, cut: large) {
            load.text = s
        } else {
            load.text = String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
            load.readOnly = load.readOnly ?? .encoding
        }
        load.eol = lineEnding(of: load.text)
        return load
    }

    /// Strict UTF-8. A file cut short for its size may end partway through a character.
    private static func utf8(_ data: Data, cut: Bool) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        guard cut else { return nil }
        for trim in 1...3 where data.count > trim {
            if let s = String(data: data.dropLast(trim), encoding: .utf8) { return s }
        }
        return nil
    }

    /// The file's line ending: Windows if most lines end in CR LF.
    static func lineEnding(of text: String) -> String {
        var crlf = 0
        var lf = 0
        var prev: UInt8 = 0
        for b in text.utf8.prefix(1_000_000) {
            if b == 0x0A { if prev == 0x0D { crlf += 1 } else { lf += 1 } }
            prev = b
        }
        return crlf > lf ? "\r\n" : "\n"
    }

    /// The path with every symlink resolved. A file that doesn't exist (yet) resolves through
    /// its folder.
    static func realPath(_ path: String) -> String {
        if let r = Darwin.realpath(path, nil) {
            defer { free(r) }
            return String(cString: r)
        }
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let r = Darwin.realpath(dir, nil) else { return path }
        defer { free(r) }
        return (String(cString: r) as NSString).appendingPathComponent(name)
    }

    enum SaveError: LocalizedError {
        case linkMoved(String)
        case notAFile
        case system(String)

        var errorDescription: String? {
            switch self {
            case .linkMoved(let p): return "The link now points somewhere else (\(p)), so nothing was saved."
            case .notAFile: return "It isn't a plain file anymore."
            case .system(let s): return s
            }
        }
    }

    /// Writes `text` atomically: into a new file next to the real one, then renamed over it, so
    /// a crash or a full disk never leaves half a file. Through a symlink, it writes the file
    /// the link pointed at when the tab opened (`realPath`), and refuses if the link has moved
    /// since. It never replaces the link itself with a copy. Keeps the file's permissions and
    /// extended attributes. Returns the new fingerprint.
    @discardableResult
    static func save(_ text: String, bom: Bool, to path: String, realPath expected: String) throws -> FileFingerprint? {
        let real = realPath(path)
        guard real == expected else { throw SaveError.linkMoved(real) }
        var st = stat()
        let exists = lstat(real, &st) == 0
        if exists && (st.st_mode & S_IFMT) != S_IFREG { throw SaveError.notAFile }
        var data = Data()
        if bom { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(contentsOf: Array(text.utf8))

        let dir = (real as NSString).deletingLastPathComponent
        let name = (real as NSString).lastPathComponent
        var template = Array("\(dir)/.\(name).hantuu-XXXXXX".utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { throw SaveError.system(String(cString: strerror(errno))) }
        let tmp = String(cString: template)
        var ok = false
        defer { if !ok { unlink(tmp) } }
        let written = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        let err = written ? 0 : errno
        if written { fsync(fd) }
        let mode = exists ? st.st_mode & 0o7777 : 0o644
        fchmod(fd, mode)
        close(fd)
        guard written else { throw SaveError.system(String(cString: strerror(err))) }
        if exists {
            // Extended attributes and ACLs, so tags and quarantine flags survive the save.
            _ = copyfile(real, tmp, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL))
        }
        guard rename(tmp, real) == 0 else { throw SaveError.system(String(cString: strerror(errno))) }
        ok = true
        return FileFingerprint.of(real)
    }
}
