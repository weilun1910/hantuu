import AppKit
import Combine

// The usage rings in the sidebar footer show how much of each agent's weekly plan limit is
// left. Everything here only reads what the agents already report locally:
//
// - Codex writes its limits into every rollout, as `event_msg` lines of type `token_count`
//   with `payload.rate_limits`. hantuu reads the end of the newest rollouts.
// - Claude Code hands its limits to the status line command as `rate_limits` in the JSON on
//   stdin, and to nothing else an interactive session exposes. hantuu's per-chat `--settings`
//   can add a status line that saves that part to a file and then runs the user's own status
//   line. Claude Code hides its footer hints ("esc to interrupt", "? for shortcuts") whenever
//   any status line is set, even one that prints nothing. So this is on by default only for
//   people who already have a status line of their own, and a setting turns it on for others.
//
// hantuu never reads either agent's login and never calls a usage API itself.

/// One usage-limit window as an agent reports it, like Codex's weekly window or Claude's
/// 5-hour one.
struct UsageWindow: Equatable {
    var usedPercent: Double
    /// The window's length. Codex says it in `window_minutes`; Claude's `five_hour` and
    /// `seven_day` are 300 and 10080.
    var minutes: Int?
    var resetsAt: Date?

    static let weekMinutes = 7 * 24 * 60
    static let fiveHourMinutes = 5 * 60

    /// Between 6 and 8 days counts as the weekly window.
    var isWeekly: Bool { minutes.map { (6 * 1440)...(8 * 1440) ~= $0 } ?? false }
    /// Between 4 and 6 hours counts as the 5-hour window.
    var isFiveHour: Bool { minutes.map { 240...360 ~= $0 } ?? false }

    func hasReset(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }

    /// What's left, 0 to 100. Once the window has reset since the reading, it starts over.
    func leftPercent(at now: Date) -> Double {
        hasReset(at: now) ? 100 : max(0, min(100, 100 - usedPercent))
    }

    /// "weekly", "5-hour", "24-hour", "30-day".
    var name: String {
        if isWeekly { return "weekly" }
        if isFiveHour { return "5-hour" }
        guard let m = minutes, m > 0 else { return "usage" }
        if m % 1440 == 0 { return "\(m / 1440)-day" }
        if m % 60 == 0 { return "\(m / 60)-hour" }
        return "\(m)-minute"
    }
}

/// The limits one agent reported at one moment.
struct UsageReading: Equatable {
    var windows: [UsageWindow]
    /// When the agent last heard them from its server, as near as hantuu can tell.
    var observedAt: Date
    var plan: String?

    var weekly: UsageWindow? { windows.first(where: \.isWeekly) }
    var fiveHour: UsageWindow? { windows.first(where: \.isFiveHour) }

    /// What the ring shows: the weekly window, or the longest one when there's no weekly.
    var ringWindow: UsageWindow? {
        weekly ?? windows.max { ($0.minutes ?? 0) < ($1.minutes ?? 0) }
    }

    /// The other windows for the tooltip, shortest first.
    var otherWindows: [UsageWindow] {
        let ring = ringWindow
        return windows.filter { $0 != ring }.sorted { ($0.minutes ?? 0) < ($1.minutes ?? 0) }
    }
}

/// The agents hantuu can read limits for. Others get no ring.
enum UsageSource: String, CaseIterable {
    case claude, codex

    init?(agentID: String) { self.init(rawValue: agentID) }

    /// The letters inside the ring. Both names start with C, so each gets two.
    var glyph: String {
        switch self {
        case .claude: return "Cl"
        case .codex: return "Co"
        }
    }

    var displayName: String { AgentCatalog.definition(rawValue).name }

    /// The tooltip line when there's no reading yet.
    var noReadingReason: String {
        switch self {
        case .claude:
            return "No reading yet. A Claude chat started or resumed with this on reports its limits after its next reply. Only Claude subscription plans have them."
        case .codex:
            return "No reading yet. It shows once a Codex turn finishes."
        }
    }
}

/// How the ring is coloured.
enum UsageLevel: Equatable {
    case normal, low, critical, unknown

    static let lowBelow = 15.0
    static let criticalBelow = 5.0

    static func of(leftPercent: Double?) -> UsageLevel {
        guard let left = leftPercent else { return .unknown }
        if left < criticalBelow { return .critical }
        if left < lowBelow { return .low }
        return .normal
    }
}

// MARK: Words

enum UsageFormat {
    /// After this long the tooltip says how old the reading is.
    static let staleAfter: TimeInterval = 15 * 60

    /// Rounded down, so 100% only ever means nothing was used.
    static func percent(_ left: Double) -> String { "\(Int(max(0, min(100, left)).rounded(.down)))%" }

    /// "just now", "5m ago", "3h ago", "2d ago".
    static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 48 * 3600 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86400))d ago"
    }

    /// "2h 10m", "25m", "1m".
    static func span(_ seconds: TimeInterval) -> String {
        let m = max(1, Int((seconds / 60).rounded(.up)))
        if m < 60 { return "\(m)m" }
        let h = m / 60, rest = m % 60
        return rest == 0 ? "\(h)h" : "\(h)h \(rest)m"
    }

    /// Under a day away: "resets in 2h 10m". Further: "resets Thu 9:13 AM", or "tomorrow"
    /// instead of the day. Already passed: "reset 25m ago".
    static func reset(_ date: Date?, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let date else { return nil }
        let delta = date.timeIntervalSince(now)
        if delta <= 0 { return "reset \(age(-delta))" }
        if delta < 24 * 3600 { return "resets in \(span(delta))" }
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = calendar.timeZone
        time.setLocalizedDateFormatFromTemplate("jmm")
        // Tooltips are plain text: no narrow no-break space before AM.
        let clock = time.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "resets tomorrow \(clock)"
        }
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = calendar.timeZone
        day.setLocalizedDateFormatFromTemplate("EEE")
        return "resets \(day.string(from: date)) \(clock)"
    }

    /// Plain text for the ring's tooltip, one fact per line:
    ///
    ///     Codex: 73% of weekly left, resets Thu 9:13 AM
    ///     5-hour: 40% left, resets in 2h 10m
    ///     As of 3h ago
    static func tooltip(_ source: UsageSource, _ reading: UsageReading?, now: Date, off: Bool = false,
                        calendar: Calendar = .current, locale: Locale = .current) -> String {
        source.displayName + ": " + details(source, reading, now: now, off: off, calendar: calendar, locale: locale)
            .joined(separator: "\n")
    }

    /// The hover card and accessibility label share the same detail lines.
    static func details(_ source: UsageSource, _ reading: UsageReading?, now: Date, off: Bool = false,
                        calendar: Calendar = .current, locale: Locale = .current) -> [String] {
        guard let reading, let ring = reading.ringWindow else {
            return [off && source == .claude ? ClaudeUsage.offReason : source.noReadingReason]
        }
        func line(_ w: UsageWindow, head: String) -> String {
            var s = head
            if let r = reset(w.resetsAt, now: now, calendar: calendar, locale: locale) { s += ", \(r)" }
            return s
        }
        var lines = [line(ring, head: "\(percent(ring.leftPercent(at: now))) of \(ring.name) left")]
        for w in reading.otherWindows {
            let label = w.name.prefix(1).uppercased() + w.name.dropFirst()
            lines.append(line(w, head: "\(label): \(percent(w.leftPercent(at: now))) left"))
        }
        let old = now.timeIntervalSince(reading.observedAt)
        if old >= staleAfter { lines.append("As of \(age(old))") }
        return lines
    }
}

// MARK: Codex

/// Reads Codex's limits from the `token_count` events in its rollouts. Never writes.
enum CodexUsage {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    /// One window: `{"used_percent": 27.0, "window_minutes": 10080, "resets_at": 1794419611}`.
    /// Older Codex builds sent `resets_in_seconds` instead of `resets_at`.
    static func window(_ v: Any?, at: Date) -> UsageWindow? {
        guard let w = v as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let minutes = (w["window_minutes"] as? NSNumber)?.intValue
        var resets: Date?
        if let r = (w["resets_at"] as? NSNumber)?.doubleValue, r > 0 {
            resets = Date(timeIntervalSince1970: r)
        } else if let s = (w["resets_in_seconds"] as? NSNumber)?.doubleValue, s >= 0 {
            resets = at.addingTimeInterval(s)
        }
        return UsageWindow(usedPercent: used, minutes: minutes, resetsAt: resets)
    }

    /// `payload.rate_limits` from a `token_count` event. Windows are told apart by their
    /// length, not by whether Codex calls them primary or secondary.
    static func reading(rateLimits v: Any?, at: Date) -> (reading: UsageReading, limitID: String?)? {
        guard let rl = v as? [String: Any] else { return nil }
        let windows = [rl["primary"], rl["secondary"]].compactMap { window($0, at: at) }
        guard !windows.isEmpty else { return nil }
        return (UsageReading(windows: windows, observedAt: at, plan: rl["plan_type"] as? String), rl["limit_id"] as? String)
    }

    /// One rollout line, if it's a `token_count` event with limits in it.
    static func parse(line: Data) -> (reading: UsageReading, limitID: String?)? {
        guard line.range(of: Data("token_count".utf8)) != nil, line.range(of: Data("rate_limits".utf8)) != nil,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              obj["type"] as? String == "event_msg",
              let p = obj["payload"] as? [String: Any], p["type"] as? String == "token_count",
              let at = date(obj["timestamp"] as? String) else { return nil }
        return reading(rateLimits: p["rate_limits"], at: at)
    }

    /// The newest reading in a rollout, from its last 256 KB, or its last 4 MB when a long tool
    /// output pushed the last `token_count` further back. Codex's main limit (`limit_id`
    /// "codex") wins over any other one it reports.
    static func latest(in url: URL, tails: [UInt64] = [256 << 10, 4 << 20]) -> UsageReading? {
        let size = LineTail.size(of: url)
        guard size > 0 else { return nil }
        for (n, tail) in tails.enumerated() {
            guard let data = read(url, last: tail, size: size) else { return nil }
            var other: UsageReading?
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            // A read that starts mid-file starts mid-line too.
            if tail < size, !lines.isEmpty { lines.removeFirst() }
            for line in lines.reversed() {
                guard let found = parse(line: Data(line)) else { continue }
                if found.limitID == nil || found.limitID == "codex" { return found.reading }
                if other == nil { other = found.reading }
            }
            if let other { return other }
            if tail >= size || n == tails.count - 1 { break }
        }
        return nil
    }

    private static func read(_ url: URL, last n: UInt64, size: UInt64) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let start = size > n ? size - n : 0
        do { try h.seek(toOffset: start) } catch { return nil }
        return try? h.read(upToCount: Int(size - start))
    }

    /// Rollouts that may hold the newest reading: those in the date folders of the last
    /// `days` days, plus `extra` (the rollouts hantuu's own Codex chats are following, which
    /// can sit in an older folder after `codex resume`). Newest first by modification time.
    static func candidates(sessions: URL, extra: [String], now: Date, days: Int = 10,
                           calendar: Calendar = .current) -> [(url: URL, size: UInt64, modified: Date)] {
        var paths = Set(extra)
        let fm = FileManager.default
        for back in -1...days {
            guard let d = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: d)
            guard let y = c.year, let m = c.month, let day = c.day else { continue }
            let dir = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", y, m, day), isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".jsonl") {
                paths.insert(dir.appendingPathComponent(name).path)
            }
        }
        var out: [(url: URL, size: UInt64, modified: Date)] = []
        for p in paths {
            guard let a = try? fm.attributesOfItem(atPath: p), let mod = a[.modificationDate] as? Date else { continue }
            out.append((URL(fileURLWithPath: p), (a[.size] as? NSNumber)?.uint64Value ?? 0, mod))
        }
        return out.sorted { $0.modified > $1.modified }
    }
}

// MARK: Claude Code

/// Claude Code's limits, from the JSON its status line command gets on stdin.
enum ClaudeUsage {
    /// Set per chat, like HANTUU_EVENTS: `<data dir>/usage/claude-<chat id>.json`.
    static let envKey = "HANTUU_USAGE"

    static var dir: URL { Paths.dataDir.appendingPathComponent("usage", isDirectory: true) }
    static func file(for chatID: UUID, in dir: URL = ClaudeUsage.dir) -> URL {
        dir.appendingPathComponent("claude-\(chatID.uuidString).json")
    }

    /// The status line hantuu adds to each Claude chat's `--settings`. It reads the JSON on
    /// stdin, saves `rate_limits` and `transcript_path` to $HANTUU_USAGE (two lines, swapped in
    /// whole), then runs the user's own status line with the same JSON and prints what it
    /// prints. Their command is looked up on every run, the way Claude Code would pick it:
    /// the project's settings.local.json, then its settings.json, then the user's
    /// settings.json. Without one it prints nothing. It only ever reads those files.
    static let statusLineCommand = #"""
    i=$(cat); x(){ printf '%s' "$i" | /usr/bin/plutil -extract "$1" "$2" -o - - 2>/dev/null; }; if [ -n "$HANTUU_USAGE" ]; then r=$(x rate_limits json); if [ -n "$r" ]; then t=$(x transcript_path raw); printf '%s\n%s\n' "$r" "$t" > "$HANTUU_USAGE.$$" && mv -f "$HANTUU_USAGE.$$" "$HANTUU_USAGE"; fi; fi 2>/dev/null; d=$(x workspace.project_dir raw) || d=$PWD; c=; for f in "$d/.claude/settings.local.json" "$d/.claude/settings.json" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; do if [ -z "$c" ] && [ -f "$f" ]; then c=$(/usr/bin/plutil -extract statusLine.command raw -o - "$f" 2>/dev/null); fi; done; if [ -n "$c" ]; then printf '%s' "$i" | /bin/sh -c "$c"; else exit 0; fi
    """#

    /// The `statusLine` value for `claude --settings`. Claude Code deep-merges it with the
    /// user's own, so their padding and refreshInterval still apply.
    static var statusLineSettings: [String: Any] { ["type": "command", "command": statusLineCommand] }

    static let offReason = "Off. Claude Code shares its limits only with a status line, and any status line hides its footer hints, like esc to interrupt. You can turn it on in Settings, under Usage Limits."

    /// Whether new Claude chats get hantuu's status line: when the setting is on, or when the
    /// user already has a status line, since then nothing they see changes.
    static var statusLineEnabled: Bool { UsageSettings.shared.claudeStatusLine || hasOwnStatusLine() }

    static var userSettingsFile: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("settings.json")
        }
        return Paths.home.appendingPathComponent(".claude/settings.json")
    }

    private static var ownCache: (Bool, Date)?

    /// Reads (never writes) the user's settings.json for a status line command of their own.
    /// Cached for a few seconds, because menus ask for launch arguments while they draw.
    static func hasOwnStatusLine(_ url: URL = userSettingsFile) -> Bool {
        if url == userSettingsFile, let (value, at) = ownCache, Date().timeIntervalSince(at) < 10 { return value }
        var value = false
        if let data = try? Data(contentsOf: url), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let sl = obj["statusLine"] as? [String: Any], let c = sl["command"] as? String {
            value = !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if url == userSettingsFile { ownCache = (value, Date()) }
        return value
    }

    /// `{"five_hour": {"used_percentage": 41, "resets_at": 1794419611}, "seven_day": {...}}`
    static func reading(rateLimits v: Any?, observedAt: Date) -> UsageReading? {
        guard let rl = v as? [String: Any] else { return nil }
        var windows: [UsageWindow] = []
        for (key, minutes) in [("five_hour", UsageWindow.fiveHourMinutes), ("seven_day", UsageWindow.weekMinutes)] {
            guard let w = rl[key] as? [String: Any], let used = (w["used_percentage"] as? NSNumber)?.doubleValue else { continue }
            let resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            windows.append(UsageWindow(usedPercent: used, minutes: minutes, resetsAt: resets))
        }
        return windows.isEmpty ? nil : UsageReading(windows: windows, observedAt: observedAt)
    }

    /// One saved file: the `rate_limits` JSON, then the transcript path.
    static func parse(file data: Data) -> (rateLimits: Any, transcript: String?)? {
        let parts = data.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let obj = try? JSONSerialization.jsonObject(with: Data(first)) else { return nil }
        let t = parts.count > 1 ? String(decoding: parts[1], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (obj, t.isEmpty ? nil : t)
    }

    /// The newest reading among the saved files. The status line also runs when nothing new
    /// came back from the server (a redraw, a prompt you typed), and then it saves the same
    /// numbers again. So a reading counts as no newer than the transcript's last write, which
    /// is when the last reply arrived.
    static func latest(in dir: URL = ClaudeUsage.dir, now: Date = Date(), prune: Bool = false) -> UsageReading? {
        let fm = FileManager.default
        var best: UsageReading?
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("claude-") && name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            guard let mod = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { continue }
            // Past a week and a day, every window in it has reset.
            if prune, now.timeIntervalSince(mod) > 8 * 86400 { try? fm.removeItem(at: url); continue }
            guard let data = try? Data(contentsOf: url), let saved = parse(file: data) else { continue }
            var at = mod
            if let t = saved.transcript, let tmod = (try? fm.attributesOfItem(atPath: t))?[.modificationDate] as? Date { at = min(at, tmod) }
            guard let r = reading(rateLimits: saved.rateLimits, observedAt: at) else { continue }
            if best == nil || r.observedAt > best!.observedAt { best = r }
        }
        return best
    }
}

// MARK: Settings

/// Settings > Usage Limits. Stored in `<data dir>/usage-settings.json`.
final class UsageSettings: ObservableObject {
    static let shared = UsageSettings()

    /// Add hantuu's status line to Claude chats so their limits reach the rings. Off by
    /// default, because any status line hides Claude Code's footer hints.
    @Published var claudeStatusLine = false { didSet { save() } }

    private struct Stored: Codable { var claudeStatusLine: Bool? }
    private var loading = false
    private var file: URL { Paths.dataDir.appendingPathComponent("usage-settings.json") }

    init() {
        loading = true
        if let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            claudeStatusLine = s.claudeStatusLine ?? false
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        Paths.ensure(Paths.dataDir)
        if let data = try? JSONEncoder.hantuu.encode(Stored(claudeStatusLine: claudeStatusLine)) { try? data.write(to: file, options: .atomic) }
    }
}

// MARK: The engine

/// Keeps the newest reading for each agent. It refreshes when a chat's turn ends, every
/// 20 seconds (a few stat calls, and a read only for files that changed), and on demand.
final class UsageCenter: ObservableObject {
    static let shared = UsageCenter()

    @Published private(set) var readings: [UsageSource: UsageReading] = [:]
    /// Ticks with each refresh, so tooltips that say "resets in 2h 10m" stay right.
    @Published private(set) var now = Date()

    var codexSessions: URL = Paths.codexSessions
    var claudeDir: URL = ClaudeUsage.dir
    static let interval: TimeInterval = 20

    private weak var model: AppModel?
    private let queue = DispatchQueue(label: "hantuu.usage", qos: .utility)
    /// Codex rollouts already read, by path. Touched only on `queue`.
    private var cache: [String: (size: UInt64, modified: Date, reading: UsageReading?)] = [:]
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var chatSubs: [UUID: AnyCancellable] = [:]
    private var pending: DispatchWorkItem?
    private var lastPrune = Date.distantPast

    func start(model: AppModel) {
        self.model = model
        Paths.ensure(claudeDir)
        model.$chats
            .sink { [weak self] chats in self?.watch(chats) }
            .store(in: &bag)
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    /// A turn that just ended has fresh limits: Codex writes a `token_count` as the reply
    /// finishes and Claude redraws its status line.
    private func watch(_ chats: [Chat]) {
        let ids = Set(chats.map(\.id))
        for id in chatSubs.keys where !ids.contains(id) { chatSubs[id] = nil }
        for chat in chats where chatSubs[chat.id] == nil && UsageSource(agentID: chat.agentID) != nil {
            var was = chat.activity
            chatSubs[chat.id] = chat.$activity.sink { [weak self] now in
                if was == .working && now != .working { self?.refreshSoon() }
                was = now
            }
        }
    }

    func refreshSoon(after delay: TimeInterval = 1.5) {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Reads on a background queue and publishes on the main one.
    func refresh() {
        let extra = (model?.chats ?? []).filter { $0.agentID == UsageSource.codex.rawValue }.compactMap(\.transcriptPath)
        let sessions = codexSessions, claude = claudeDir
        let prune = Date().timeIntervalSince(lastPrune) > 3600
        if prune { lastPrune = Date() }
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            let codex = self.newestCodex(sessions: sessions, extra: extra, now: now)
            let claude = ClaudeUsage.latest(in: claude, now: now, prune: prune)
            DispatchQueue.main.async {
                var r = self.readings
                // A reading that's gone from disk is still the last one known, so keep it.
                if let codex, codex != r[.codex] { r[.codex] = codex }
                if let claude, claude != r[.claude] { r[.claude] = claude }
                if r != self.readings { self.readings = r }
                self.now = now
            }
        }
    }

    /// The newest of the readings in the three most recently written rollouts.
    private func newestCodex(sessions: URL, extra: [String], now: Date) -> UsageReading? {
        let files = CodexUsage.candidates(sessions: sessions, extra: extra, now: now)
        var best: UsageReading?
        for f in files.prefix(3) {
            let r: UsageReading?
            if let c = cache[f.url.path], c.size == f.size, c.modified == f.modified {
                r = c.reading
            } else {
                r = CodexUsage.latest(in: f.url)
                cache[f.url.path] = (f.size, f.modified, r)
            }
            if let r, best == nil || r.observedAt > best!.observedAt { best = r }
        }
        if cache.count > 64 {
            let keep = Set(files.prefix(16).map(\.url.path))
            cache = cache.filter { keep.contains($0.key) }
        }
        return best
    }

    func reading(for source: UsageSource) -> UsageReading? { readings[source] }

    /// Stops the timer and the turn watching. Only the self test needs it.
    func stop() {
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        bag.removeAll()
        chatSubs.removeAll()
    }

    /// For snapshots and the self test: fixed readings and a fixed clock.
    func preview(_ readings: [UsageSource: UsageReading], now: Date) {
        self.readings = readings
        self.now = now
    }
}
