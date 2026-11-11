import AppKit
import UniformTypeIdentifiers

enum FileKind: String, Codable {
    case image, pdf, text, directory, other
}

struct DetectedPath: Codable, Equatable {
    var match: String     // the text as it appears
    var path: String      // absolute, existing
    var line: Int?
    var kind: FileKind
}

/// Finds file paths in agent output that exist on disk. Handles absolute paths with spaces
/// and emoji (iCloud Drive projects live under ".../Mobile Documents/com~apple~CloudDocs/..."),
/// ~/ paths, file:// URLs, relative paths against the project folder, and :line suffixes.
enum PathDetector {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "svg", "ico", "avif"]
    static let textExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "rs", "go", "zig", "py", "rb", "js", "mjs", "cjs", "ts", "tsx", "jsx",
        "java", "kt", "kts", "scala", "cs", "php", "lua", "pl", "r", "jl", "dart", "ex", "exs", "erl", "hs", "ml", "clj", "sql",
        "sh", "bash", "zsh", "fish", "ps1", "md", "markdown", "mdx", "txt", "rst", "tex", "bib", "json", "jsonl", "yaml", "yml",
        "toml", "ini", "cfg", "conf", "xml", "plist", "html", "htm", "css", "scss", "less", "vue", "svelte", "csv", "tsv", "log",
        "gradle", "cmake", "make", "mk", "dockerfile", "env", "gitignore", "lock", "patch", "diff", "zon", "ipynb", "proto",
        "graphql", "gql", "nix", "tf", "hcl", "vim", "el", "ghostty", "strings", "entitlements", "pbxproj", "xcconfig",
    ]

    private static let spanStops: Set<Character> = ["\n", "\r", "`", "\"", "<", ">", "|", "*", "\t"]
    private static let tokenStarts: Set<Character> = [" ", "\n", "\t", "(", "[", "<", "\"", "'", "`", "*", "="]

    static func detect(in text: String, base: String?) -> [DetectedPath] {
        var found: [DetectedPath] = []
        var seen = Set<String>()
        let chars = Array(text)
        var i = 0
        var checks = 0
        // Pass 1: rooted paths (/..., ~/..., file://...), which may contain spaces.
        while i < chars.count && checks < 600 {
            let atStart = i == 0 || tokenStarts.contains(chars[i - 1])
            let c = chars[i]
            let rooted = c == "/" || (c == "~" && i + 1 < chars.count && chars[i + 1] == "/")
            let fileURL = c == "f" && text.count - i > 7 && String(chars[i..<min(i + 7, chars.count)]) == "file://"
            guard atStart, rooted || fileURL else { i += 1; continue }
            var end = i
            while end < chars.count && end - i < 600 && !spanStops.contains(chars[end]) { end += 1 }
            // Candidate ends: before each space, and the span end. Longest first.
            var cuts: [Int] = [end]
            var k = end - 1
            while k > i { if chars[k] == " " { cuts.append(k) }; k -= 1 }
            var matched = false
            for cut in cuts {
                checks += 1
                let raw = String(chars[i..<cut])
                if let (m, r) = resolveCandidate(raw, base: base) {
                    if seen.insert(m + "|" + r.path).inserted {
                        found.append(DetectedPath(match: m, path: r.path, line: r.line, kind: r.kind))
                    }
                    i += m.count
                    matched = true
                    break
                }
            }
            if !matched { i += 1 }
        }
        // Pass 2: relative tokens without spaces (src/app.swift, ./x, README.md:12).
        let separators = CharacterSet(charactersIn: " \n\t`\"'()[]<>,;*|")
        for token in text.components(separatedBy: separators) where checks < 1200 {
            guard !token.isEmpty, !token.hasPrefix("/"), !token.hasPrefix("~"), !token.contains("://") else { continue }
            guard token.contains("/") || token.range(of: #"\.[A-Za-z0-9]{1,10}(:\d+)?(:\d+)?[.:]?$"#, options: .regularExpression) != nil else { continue }
            checks += 1
            if let (m, r) = resolveCandidate(token, base: base), seen.insert(m + "|" + r.path).inserted {
                found.append(DetectedPath(match: m, path: r.path, line: r.line, kind: r.kind))
            }
        }
        return found
    }

    /// Strips trailing punctuation and a :line suffix, then resolves. Returns the matched
    /// text (as it appears) and the resolved file.
    private static func resolveCandidate(_ raw: String, base: String?) -> (String, (path: String, kind: FileKind, line: Int?))? {
        var m = raw
        while let last = m.last, ".,;:!?'".contains(last) { m.removeLast() }
        if m.hasSuffix(")") && !m.contains("(") { m.removeLast() }
        guard m.count >= 2, m != "~/" else { return nil }
        guard let r = resolve(m, base: base) else { return nil }
        if r.path == "/" { return nil }
        return (m, r)
    }

    /// Resolves a path-ish string to an existing absolute path, with an optional line.
    static func resolve(_ input: String, base: String?) -> (path: String, kind: FileKind, line: Int?)? {
        var s = input.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("file://") {
            guard let u = URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else { return nil }
            s = u.path
        }
        var line: Int?
        if let r = s.range(of: #":(\d+)(:\d+)?$"#, options: .regularExpression) {
            let digits = s[r].dropFirst().split(separator: ":").first.map(String.init) ?? ""
            line = Int(digits)
            s = String(s[..<r.lowerBound])
        } else if let r = s.range(of: #"#L(\d+)(-L?\d+)?$"#, options: .regularExpression) {
            line = Int(s[r].dropFirst(2).split(separator: "-").first ?? "")
            s = String(s[..<r.lowerBound])
        }
        if s.hasPrefix("~/") { s = Paths.home.path + String(s.dropFirst(1)) }
        if !s.hasPrefix("/") {
            guard let base else { return nil }
            s = (base as NSString).appendingPathComponent(s)
        }
        s = (s as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: s, isDirectory: &isDir) else { return nil }
        return (s, isDir.boolValue ? .directory : kind(of: s), line)
    }

    static func kind(of path: String) -> FileKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if textExtensions.contains(ext) { return .text }
        let name = (path as NSString).lastPathComponent
        if ["Makefile", "Dockerfile", "LICENSE", "README", "Package.resolved", ".gitignore", ".zshrc", ".env"].contains(name) { return .text }
        if !ext.isEmpty, let ut = UTType(filenameExtension: ext) {
            if ut.conforms(to: .image) { return .image }
            if ut.conforms(to: .sourceCode) || ut.conforms(to: .plainText) || ut.conforms(to: .json) || ut.conforms(to: .xml) { return .text }
            if ut.conforms(to: .text) && !ut.conforms(to: .rtf) && !ut.conforms(to: .html) { return .text }
            if ut.conforms(to: .html) { return .text }
        }
        return looksLikeText(path) ? .text : .other
    }

    /// Small files with no NUL bytes in the first 8 KB and valid UTF-8 count as text.
    static func looksLikeText(_ path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.intValue, size < 5_000_000,
              let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 8192)) ?? Data()
        if head.isEmpty { return true }
        if head.contains(0) { return false }
        return String(data: head, encoding: .utf8) != nil
    }
}

/// One place that decides what opening a link means, for the terminal and the reader alike:
/// web URLs go to the browser, and files go to the Code tab, which shows text, code, images,
/// PDFs, video, audio and anything Quick Look can preview. Folders, and files nothing can
/// preview, are revealed in Finder.
final class FileRouter {
    static let shared = FileRouter()

    enum Route: Equatable {
        case browser(URL)
        /// Open in the Code tab, at a line for text.
        case code(String, Int?)
        case finder(String)
        case system(URL)
    }

    /// Set by the app model: shows a file in the Code tab.
    var openInCode: ((String, Int?) -> Void)?
    /// When set (self test), routes are recorded instead of performed.
    var recorder: ((Route) -> Void)?

    func route(for raw: String, base: String?, trusted: Bool = true) -> Route? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = URL(string: s)?.scheme?.lowercased()
        if let u = URL(string: s), scheme == "http" || scheme == "https" { return .browser(u) }
        if let u = URL(string: s), scheme == "mailto" { return trusted ? .system(u) : nil }
        // Paths first: "README.md:12" parses as a URL with scheme "readme.md".
        if let r = PathDetector.resolve(s, base: base) {
            if r.kind == .directory { return .finder(r.path) }
            return FileKinds.kind(of: r.path).opensInPanel ? .code(r.path, r.line) : .finder(r.path)
        }
        if trusted, let u = URL(string: s), let scheme, scheme != "file", !scheme.contains("."),
           !["javascript", "data", "about", "blob"].contains(scheme) {
            return .system(u)
        }
        return nil
    }

    func perform(_ route: Route) {
        if let recorder { recorder(route); return }
        switch route {
        case .browser(let u), .system(let u): NSWorkspace.shared.open(u)
        case .code(let p, let line):
            if let openInCode { openInCode(p, line) } else { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
        case .finder(let p): NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        }
    }

    func open(_ raw: String, base: String?) {
        guard let r = route(for: raw, base: base) else {
            Log.write("router: nothing to open for \(raw)")
            return
        }
        perform(r)
    }

    /// Cmd-click in a terminal. OSC 8 targets come from program output, so only web and
    /// file links are followed for those.
    func openFromTerminal(_ url: String, isOSC8: Bool, base: String?) {
        guard let r = route(for: url, base: base, trusted: !isOSC8) else {
            Log.write("router: ignored terminal link \(url)")
            return
        }
        perform(r)
    }
}
