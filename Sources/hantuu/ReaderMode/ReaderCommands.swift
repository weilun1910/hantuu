import Foundation

/// A completion and its provenance. Higher precedence wins when two sources use one name.
struct ReaderCommand: Equatable {
    enum Peek: Equatable { case never, always, withoutArguments }
    var name: String
    var description: String
    var source = ""
    var argumentHint = ""
    var sigil = "/"
    var precedence = 0
    var peek: Peek = .never
    var userInvocable = true
    /// Codex hides aliases from the unfiltered menu but offers them when searching.
    var aliasOf: String? = nil
    var token: String { sigil + name }

    func opensTerminal(arguments: String) -> Bool {
        peek == .always || (peek == .withoutArguments && arguments.isEmpty)
    }
}

enum ReaderCommandLogic {
    struct Query: Equatable {
        var range: NSRange
        var sigil: String
        var text: String
    }

    /// Only a leading slash is a command. Codex skill mentions can occur within a message.
    /// Requiring the caret at the token's end keeps editing earlier arguments ordinary text.
    static func query(_ text: String, selection: NSRange, skills: Bool) -> Query? {
        let ns = text as NSString
        guard selection.length == 0, selection.location <= ns.length else { return nil }
        let before = ns.substring(to: selection.location)
        let after = ns.substring(from: selection.location)
        guard after.isEmpty else { return nil }
        let leading = before.prefix(while: { $0.isWhitespace })
        let trimmed = String(before.dropFirst(leading.count))
        if trimmed.hasPrefix("/"), !trimmed.contains(where: { $0.isWhitespace }) {
            return Query(range: NSRange(location: (String(leading) as NSString).length, length: (trimmed as NSString).length), sigil: "/", text: String(trimmed.dropFirst()))
        }
        if skills {
            let word = before.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
            if word.hasPrefix("$"), before.hasSuffix(word) {
                return Query(range: NSRange(location: ns.length - (word as NSString).length, length: (word as NSString).length), sigil: "$", text: String(word.dropFirst()))
            }
        }
        return nil
    }

    static func ranked(_ commands: [ReaderCommand], query: Query) -> [ReaderCommand] {
        let needle = query.text.lowercased()
        func score(_ name: String) -> Int? {
            let name = name.lowercased()
            if name == needle { return 0 }
            if name.hasPrefix(needle) { return 1 }
            if name.contains(needle) { return 2 }
            var remaining = needle[...]
            for c in name where remaining.first == c { remaining = remaining.dropFirst() }
            return remaining.isEmpty ? 3 : nil
        }
        return commands.filter { $0.sigil == query.sigil && ($0.aliasOf == nil || !needle.isEmpty) }.compactMap { c -> (ReaderCommand, Int)? in
            score(c.name).map { (c, $0) }
        }.sorted { a, b in
            a.1 == b.1 ? a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending : a.1 < b.1
        }.map { $0.0 }
    }

    static func merged(_ commands: [ReaderCommand]) -> [ReaderCommand] {
        var byName: [String: ReaderCommand] = [:]
        for c in commands where !c.name.isEmpty && !c.name.contains(where: { $0.isWhitespace }) {
            if let previous = byName[c.token], previous.precedence > c.precedence { continue }
            byName[c.token] = c
        }
        return byName.values.filter(\.userInvocable).sorted { $0.token < $1.token }
    }

    static func shouldSend(query: Query, selected: ReaderCommand) -> Bool {
        query.sigil == "/" && query.text == selected.name
    }

    static func invocation(_ text: String) -> (name: String, arguments: String)? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("/"), !s.contains("\n") else { return nil }
        let pieces = s.dropFirst().split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let name = pieces.first, !name.isEmpty, !name.contains("/") else { return nil }
        return (String(name), pieces.count > 1 ? String(pieces[1]) : "")
    }

    static func autoPeek(sentAt: Date?, now: Date, menu: ScreenMenu?) -> Bool {
        guard let sentAt, menu != nil else { return false }
        return (0...6).contains(now.timeIntervalSince(sentAt))
    }
}

/// The small YAML subset used by command metadata. Bodies are never executed or expanded.
enum CommandFrontmatter {
    static func parse(_ markdown: String) -> (fields: [String: String], body: String) {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], markdown)
        }
        var fields: [String: String] = [:]
        var block: String?
        for line in lines[1..<end] {
            if let key = block, line.hasPrefix(" ") || line.hasPrefix("\t") {
                let value = line.trimmingCharacters(in: .whitespaces)
                fields[key, default: ""] += (fields[key, default: ""].isEmpty ? "" : " ") + value
                continue
            }
            block = nil
            guard !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if ["|", ">", "|-", ">-", "|+", ">+"].contains(value) { block = key; value = "" }
            if value.count >= 2, (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            } else if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
            fields[key] = value
        }
        return (fields, lines.dropFirst(end + 1).joined(separator: "\n"))
    }
}

/// All disk work happens on one worker. Callers get an immediate built-in list, then a
/// cached catalogue on main. A session's listing is included without reading its prose.
final class ReaderCommandCatalog {
    struct Context: Hashable {
        var agent: String
        var folder: String
        var transcript: String?
    }
    private let queue = DispatchQueue(label: "hantuu.reader.commands", qos: .utility)
    private let home: URL
    private var cache: [Context: (Date, [ReaderCommand])] = [:]
    private var listings: [String: SkillListingTail] = [:]
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    func load(_ context: Context, completion: @escaping ([ReaderCommand]) -> Void) {
        queue.async { [self] in
            let now = Date()
            let commands: [ReaderCommand]
            if let entry = cache[context], now.timeIntervalSince(entry.0) < 5 { commands = entry.1 }
            else {
                var session: [ReaderCommand] = []
                if context.agent == "claude", let path = context.transcript {
                    if listings[path] == nil { listings[path] = SkillListingTail() }
                    session = listings[path]?.read(URL(fileURLWithPath: path)) ?? []
                }
                commands = Self.read(context, home: home, session: session)
                if cache.count > 32 { cache.removeAll() }
                cache[context] = (now, commands)
            }
            DispatchQueue.main.async { completion(commands) }
        }
    }

    static func read(_ context: Context, home: URL, session: [ReaderCommand] = []) -> [ReaderCommand] {
        let project = URL(fileURLWithPath: context.folder)
        var result = builtins(agent: context.agent)
        if context.agent == "claude" {
            let personal = home.appendingPathComponent(".claude")
            result += commands(at: personal.appendingPathComponent("commands"), source: "personal", precedence: 10)
            result += skills(at: personal.appendingPathComponent("skills"), source: "personal skill", precedence: 20)
            result += pluginCommands(personal: personal, project: project)
            result += commands(at: project.appendingPathComponent(".claude/commands"), source: "project", precedence: 40)
            result += skills(at: project.appendingPathComponent(".claude/skills"), source: "project skill", precedence: 50)
            result += session
        } else if context.agent == "codex" {
            result += commands(at: home.appendingPathComponent(".codex/prompts"), source: "personal prompt", precedence: 10, namespace: "prompts", recursive: false)
            result += skills(at: home.appendingPathComponent(".codex/skills"), source: "personal skill", precedence: 20, sigil: "$")
            result += skills(at: home.appendingPathComponent(".agents/skills"), source: "personal skill", precedence: 25, sigil: "$")
            result += skills(at: project.appendingPathComponent(".agents/skills"), source: "project skill", precedence: 50, sigil: "$")
        }
        return ReaderCommandLogic.merged(result)
    }

    private static func markdown(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1024 * 1024 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func commands(at root: URL, source: String, precedence: Int, namespace: String = "", recursive: Bool = true) -> [ReaderCommand] {
        let fm = FileManager.default
        let urls: [URL]
        if root.pathExtension.lowercased() == "md" { urls = [root] }
        else if recursive {
            let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            urls = enumerator?.allObjects as? [URL] ?? []
        } else { urls = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] }
        return urls.sorted { $0.path < $1.path }.compactMap { url in
            guard url.pathExtension.lowercased() == "md", let text = markdown(url) else { return nil }
            let metadata = CommandFrontmatter.parse(text)
            let relative = root == url ? url.deletingPathExtension().lastPathComponent : String(url.deletingPathExtension().path.dropFirst(root.path.count + 1)).replacingOccurrences(of: "/", with: ":")
            let name = namespace.isEmpty ? relative : namespace + ":" + relative
            let description = metadata.fields["description"] ?? metadata.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Custom command"
            return ReaderCommand(name: name, description: description, source: source, argumentHint: metadata.fields["argument-hint"] ?? "", precedence: precedence, userInvocable: metadata.fields["user-invocable"]?.lowercased() != "false")
        }
    }

    static func skills(at root: URL, source: String, precedence: Int, namespace: String = "", sigil: String = "/") -> [ReaderCommand] {
        let dirs = FileManager.default.fileExists(atPath: root.appendingPathComponent("SKILL.md").path) ? [root] : ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
        return dirs.sorted { $0.path < $1.path }.flatMap { dir -> [ReaderCommand] in
            // Codex's bundled skills live one level below .system.
            if dir.lastPathComponent == ".system", sigil == "$" { return skills(at: dir, source: source, precedence: precedence, sigil: sigil) }
            guard let text = markdown(dir.appendingPathComponent("SKILL.md")) else { return [] }
            let metadata = CommandFrontmatter.parse(text)
            let name = metadata.fields["name"] ?? dir.lastPathComponent
            return [ReaderCommand(name: namespace.isEmpty ? name : namespace + ":" + name,
                                  description: metadata.fields["description"] ?? metadata.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Skill",
                                  source: source, argumentHint: metadata.fields["argument-hint"] ?? "", sigil: sigil, precedence: precedence,
                                  userInvocable: metadata.fields["user-invocable"]?.lowercased() != "false")]
        }
    }

    private static func object(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    static func pluginCommands(personal: URL, project: URL) -> [ReaderCommand] {
        var enabled = object(personal.appendingPathComponent("settings.json"))["enabledPlugins"] as? [String: Bool] ?? [:]
        for name in ["settings.json", "settings.local.json"] {
            let overrides = object(project.appendingPathComponent(".claude/" + name))["enabledPlugins"] as? [String: Bool] ?? [:]
            enabled.merge(overrides) { _, new in new }
        }
        let installed = object(personal.appendingPathComponent("plugins/installed_plugins.json"))["plugins"] as? [String: Any] ?? [:]
        var result: [ReaderCommand] = []
        for key in enabled.keys.sorted() where enabled[key] == true {
            let entries = installed[key] as? [[String: Any]] ?? (installed[key] as? [String: Any]).map { [$0] } ?? []
            for entry in entries {
                if let folder = entry["projectPath"] as? String, URL(fileURLWithPath: folder).standardizedFileURL != project.standardizedFileURL { continue }
                guard let path = entry["installPath"] as? String else { continue }
                let root = URL(fileURLWithPath: path)
                let name = String(key.split(separator: "@").first ?? Substring(key))
                let manifest = object(root.appendingPathComponent(".claude-plugin/plugin.json"))
                func paths(_ value: Any?) -> [String] {
                    if let s = value as? String { return [s] }
                    return value as? [String] ?? []
                }
                if let custom = manifest["commands"] {
                    for path in paths(custom) { result += commands(at: root.appendingPathComponent(path), source: name, precedence: 30, namespace: name) }
                    if let definitions = custom as? [String: [String: Any]] {
                        for key in definitions.keys.sorted() {
                            guard let definition = definitions[key] else { continue }
                            let source = (definition["source"] as? String).flatMap { markdown(root.appendingPathComponent($0)) } ?? definition["content"] as? String ?? ""
                            let meta = CommandFrontmatter.parse(source)
                            result.append(ReaderCommand(name: name + ":" + key, description: definition["description"] as? String ?? meta.fields["description"] ?? "Plugin command", source: name, argumentHint: definition["argumentHint"] as? String ?? meta.fields["argument-hint"] ?? "", precedence: 30, userInvocable: meta.fields["user-invocable"]?.lowercased() != "false"))
                        }
                    }
                } else { result += commands(at: root.appendingPathComponent("commands"), source: name, precedence: 30, namespace: name) }
                result += skills(at: root.appendingPathComponent("skills"), source: name + " skill", precedence: 30, namespace: name)
                for path in paths(manifest["skills"]) { result += skills(at: root.appendingPathComponent(path), source: name + " skill", precedence: 30, namespace: name) }
            }
        }
        return result
    }

    static func listing(_ text: String) -> [ReaderCommand] {
        text.components(separatedBy: "\n").compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("- "), let split = s.range(of: ": ") else { return nil }
            let name = String(s[s.index(s.startIndex, offsetBy: 2)..<split.lowerBound])
            return ReaderCommand(name: name, description: String(s[split.upperBound...]), source: "session skill", precedence: 5)
        }
    }
}

/// Reads each transcript byte once. Long prose and image lines are skipped without decoding.
/// The first scan and subsequent tail reads are always on the catalogue's worker queue.
final class SkillListingTail {
    private var offset: UInt64 = 0
    private var pending = Data()
    private var commands: [ReaderCommand] = []
    private var skipping = false
    private var fileID: UInt64?

    func read(_ url: URL) -> [ReaderCommand] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return commands }
        defer { try? handle.close() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let id = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        guard let size = try? handle.seekToEnd() else { return commands }
        if size < offset || id != fileID {
            offset = 0; pending = Data(); commands = []; skipping = false; fileID = id
        }
        try? handle.seek(toOffset: offset)
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            offset += UInt64(chunk.count)
            for byte in chunk {
                if byte == 10 {
                    if !skipping, pending.range(of: Data("skill_listing".utf8)) != nil,
                       let obj = try? JSONSerialization.jsonObject(with: pending) as? [String: Any],
                       obj["type"] as? String == "attachment", obj["isSidechain"] as? Bool != true,
                       let attachment = obj["attachment"] as? [String: Any], attachment["type"] as? String == "skill_listing",
                       let content = attachment["content"] as? String {
                        commands = ReaderCommandLogic.merged(commands + ReaderCommandCatalog.listing(content))
                    }
                    pending.removeAll(keepingCapacity: true)
                    skipping = false
                } else if !skipping {
                    if pending.count < 1024 * 1024 { pending.append(byte) }
                    else { pending.removeAll(keepingCapacity: true); skipping = true }
                }
            }
        }
        return commands
    }
}
