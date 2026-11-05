import Foundation

/// Reads complete new lines appended to a file, from a starting offset. Never writes.
/// The file may not exist yet; it's picked up once it does.
final class LineTail {
    let url: URL
    private(set) var offset: UInt64
    private var partial = Data()
    private var skipToNewline: Bool

    enum Start { case beginning, end, lastBytes(UInt64) }

    init(url: URL, from start: Start) {
        self.url = url
        let size = LineTail.size(of: url)
        switch start {
        case .beginning:
            offset = 0
            skipToNewline = false
        case .end:
            offset = size
            skipToNewline = false
        case .lastBytes(let n):
            offset = size > n ? size - n : 0
            // Starting mid-file: drop the first, probably partial, line.
            skipToNewline = offset > 0
        }
    }

    static func size(of url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// New complete lines since the last call. Reads at most `limit` bytes per call.
    func read(limit: Int = 16 << 20) -> [Data] {
        let size = LineTail.size(of: url)
        if size < offset {
            // Replaced or truncated: start again from the top.
            offset = 0
            partial = Data()
            skipToNewline = false
        }
        guard size > offset, let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        do { try h.seek(toOffset: offset) } catch { return [] }
        let want = Int(min(UInt64(limit), size - offset))
        guard let data = try? h.read(upToCount: want), !data.isEmpty else { return [] }
        offset += UInt64(data.count)
        var buf = partial + data
        if skipToNewline {
            guard let nl = buf.firstIndex(of: 0x0A) else { partial = Data(); return [] }
            buf = Data(buf[buf.index(after: nl)...])
            skipToNewline = false
        }
        var lines: [Data] = []
        var start = buf.startIndex
        while let nl = buf[start...].firstIndex(of: 0x0A) {
            if nl > start { lines.append(Data(buf[start..<nl])) }
            start = buf.index(after: nl)
        }
        partial = Data(buf[start...])
        return lines
    }
}
