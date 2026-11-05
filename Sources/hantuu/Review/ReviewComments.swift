import Foundation

/// A line comment left on the diff, waiting to be sent to the chat's agent.
struct ReviewComment: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var root: String          // repository root the path is relative to
    var path: String
    var side: String          // "new" (context or added lines) or "old" (removed lines)
    var start: Int
    var end: Int
    var quoted: [String]
    var body: String
    var created = Date()

    var lineLabel: String { start == end ? "\(start)" : "\(start)-\(end)" }
}

enum CommentMessage {
    static let maxQuotedLines = 6

    /// The single message typed into the chat for a batch of comments. Paths are relative to
    /// the agent's working folder when the file is inside it, otherwise absolute.
    static func build(_ comments: [ReviewComment], folder: String) -> String {
        var out = [comments.count == 1
            ? "Please address this review comment on your changes:"
            : "Please address these \(comments.count) review comments on your changes:"]
        let ordered = comments.sorted { ($0.path, $0.start) < ($1.path, $1.start) }
        for (i, c) in ordered.enumerated() {
            var head = "\(i + 1). \(displayPath(c, folder: folder)):\(c.lineLabel)"
            if c.side == "old" { head += c.start == c.end ? " (removed line)" : " (removed lines)" }
            var block = [head]
            let lines = c.quoted.map { clean($0).replacingOccurrences(of: "\n", with: " ") }
            for q in lines.prefix(maxQuotedLines) {
                let t = q.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                block.append(t.isEmpty ? ">" : "> \(t)")
            }
            if lines.count > maxQuotedLines { block.append("> …") }
            block.append(clean(c.body).trimmingCharacters(in: .whitespacesAndNewlines))
            out.append(block.joined(separator: "\n"))
        }
        return out.joined(separator: "\n\n")
    }

    static func displayPath(_ c: ReviewComment, folder: String) -> String {
        let abs = (c.root as NSString).appendingPathComponent(c.path)
        let f = folder.hasSuffix("/") ? folder : folder + "/"
        if abs.hasPrefix(f) { return String(abs.dropFirst(f.count)) }
        return c.root == folder ? c.path : abs
    }

    /// Drops control characters (including ESC, so text can't end a bracketed paste early),
    /// keeping newlines and tabs.
    static func clean(_ s: String) -> String {
        String(String.UnicodeScalarView(s.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.filter { u in
            u == "\n" || u == "\t" || !(u.value < 0x20 || u.value == 0x7F || (0x80...0x9F).contains(u.value))
        }))
    }
}

/// Comments and viewed marks, kept in the data folder so they survive a relaunch until sent.
struct ReviewSavedState: Codable {
    var comments: [String: [ReviewComment]] = [:]   // chat id -> comments
    var viewed: [String: String] = [:]              // "<root>|<base>|<path>" -> diff hash

    static var url: URL { Paths.dataDir.appendingPathComponent("review.json") }

    static func load() -> ReviewSavedState {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder.hantuu.decode(ReviewSavedState.self, from: data) else { return ReviewSavedState() }
        return s
    }

    func save() {
        Paths.ensure(Paths.dataDir)
        if let data = try? JSONEncoder.hantuu.encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }
}
