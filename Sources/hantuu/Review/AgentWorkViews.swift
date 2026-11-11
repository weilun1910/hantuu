import AppKit
import SwiftUI

/// The Overview's Agents card: the subagents the chat started, running ones first with what
/// they're doing now, then the ones that finished. Clicking a row shows its task and report.
struct AgentsCard: View {
    let agents: [SubagentInfo]
    var now: Date? = nil
    @State private var expanded: Set<String> = []
    @State private var showAll = false
    var savedExpanded: Binding<Set<String>>?
    var savedShowAll: Binding<Bool>?
    static let finishedShown = 3

    init(agents: [SubagentInfo], now: Date? = nil, expanded: Set<String> = [], savedExpanded: Binding<Set<String>>? = nil, savedShowAll: Binding<Bool>? = nil) {
        self.agents = agents
        self.now = now
        _expanded = State(initialValue: expanded)
        self.savedExpanded = savedExpanded
        self.savedShowAll = savedShowAll
    }

    var body: some View {
        let expanded = savedExpanded ?? $expanded
        let showAll = savedShowAll ?? $showAll
        let ids = Set(agents.map(\.id))
        let top = agents.filter { a in a.parentID.map { !ids.contains($0) } ?? true }
        let running = top.filter { $0.state.isActive }.sorted { WorkOrder.started($0) < WorkOrder.started($1) }
        let finished = top.filter { !$0.state.isActive }.sorted { WorkOrder.ended($0) > WorkOrder.ended($1) }
        let shown = showAll.wrappedValue ? finished : Array(finished.prefix(Self.finishedShown))
        let active = agents.filter { $0.state.isActive }.count
        ReviewCard(title: "Agents", trailing: active > 0 ? "\(active) running" : "\(top.count) finished") {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(running) { a in AgentTree(agent: a, all: agents, depth: 0, expanded: expanded, now: now) }
                if !running.isEmpty && !shown.isEmpty { Spacer().frame(height: 5) }
                ForEach(shown) { a in AgentTree(agent: a, all: agents, depth: 0, expanded: expanded, now: now) }
                if finished.count > Self.finishedShown {
                    MoreToggle(more: finished.count - Self.finishedShown, showingAll: showAll)
                }
            }
        }
    }
}

enum WorkOrder {
    static func started(_ a: SubagentInfo) -> Date { a.startedAt ?? a.activeSince ?? .distantPast }
    static func ended(_ a: SubagentInfo) -> Date { a.endedAt ?? a.startedAt ?? .distantPast }
    static func started(_ t: BackgroundTaskInfo) -> Date { t.startedAt ?? .distantPast }
    static func ended(_ t: BackgroundTaskInfo) -> Date { t.endedAt ?? t.startedAt ?? .distantPast }
}

/// A row and, under it, the agents it started.
struct AgentTree: View {
    let agent: SubagentInfo
    let all: [SubagentInfo]
    let depth: Int
    @Binding var expanded: Set<String>
    var now: Date?

    var body: some View {
        let children = all.filter { $0.parentID == agent.id }
            .sorted { ($0.state.isActive ? 0 : 1, WorkOrder.started($0)) < ($1.state.isActive ? 0 : 1, WorkOrder.started($1)) }
        VStack(alignment: .leading, spacing: 1) {
            AgentRow(agent: agent, depth: depth, expanded: expanded.contains(agent.id), now: now) {
                if expanded.contains(agent.id) { expanded.remove(agent.id) } else { expanded.insert(agent.id) }
            }
            ForEach(children) { c in AgentTree(agent: c, all: all, depth: min(depth + 1, 3), expanded: $expanded, now: now) }
        }
    }
}

struct AgentRow: View {
    @EnvironmentObject var model: AppModel
    let agent: SubagentInfo
    let depth: Int
    let expanded: Bool
    var now: Date?
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkRowLayout(state: agent.state, title: agent.title, detail: detail, meta: WorkText.meta(type: agent.type, model: agent.model),
                          time: WorkTime.Span(start: agent.activeSince ?? agent.startedAt, end: agent.endedAt, duration: agent.duration, running: agent.state.isActive),
                          now: now, highlighted: hovering)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                .onHover { hovering = $0 }
                .help(expanded ? "Hide the task and report" : "Show the task and report")
            if expanded {
                AgentDetail(agent: agent)
                    .padding(.leading, WorkRowLayout.textInset - 6)
                    .padding(.trailing, 6)
                    .padding(.top, 3)
                    .padding(.bottom, 9)
            }
        }
        .padding(.leading, CGFloat(depth) * 16)
    }

    private var detail: String {
        switch agent.state {
        case .running: return agent.step ?? "Working"
        case .waiting: return "Waiting on its own agents"
        case .done: return WorkText.firstLine(agent.result) ?? "Done"
        case .failed: return WorkText.firstLine(agent.result).map { "Failed: " + $0 } ?? "Failed"
        case .stopped: return "Stopped"
        case .stale: return WorkText.quiet("No update", since: agent.lastUpdate)
        }
    }
}

/// The task an agent was given and what it reported, under its row.
struct AgentDetail: View {
    @EnvironmentObject var model: AppModel
    let agent: SubagentInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let p = agent.prompt?.nilIfBlank {
                VStack(alignment: .leading, spacing: 3) {
                    label("Task")
                    Text(p.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.hSecondary)
                        .lineLimit(4)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if let r = agent.result?.nilIfBlank {
                VStack(alignment: .leading, spacing: 4) {
                    label(agent.state == .failed ? "Error" : "Report")
                    ReportText(markdown: r, maxBlocks: Self.inlineBlocks)
                    if MarkdownLite.blocks(r).count > Self.inlineBlocks || r.count > 1800 {
                        openInCode(r)
                    }
                }
            } else if agent.state.isActive {
                Text("Its report shows here when it finishes.").font(.system(size: 11.5)).foregroundStyle(Color.hTertiary)
            } else if agent.prompt?.nilIfBlank == nil {
                Text("Nothing to show.").font(.system(size: 11.5)).foregroundStyle(Color.hTertiary)
            }
        }
    }

    static let inlineBlocks = 12

    /// The whole report as a page, for reports longer than the card shows.
    private func openInCode(_ r: String) -> some View {
        Button { WorkReport.open(title: agent.title, text: r, model: model) } label: {
            HStack(spacing: 4) {
                Text("Open the whole report")
                Image(systemName: "arrow.up.right").font(.system(size: 9.5, weight: .semibold))
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.hLink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .help("Open it as a page in the Code tab")
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.hTertiary)
    }
}

/// The Overview's Background tasks card: background commands and monitors (Claude Code) or
/// terminals that kept running (Codex). Clicking one opens its output in the Code tab.
struct BackgroundTasksCard: View {
    let tasks: [BackgroundTaskInfo]
    var now: Date? = nil
    @State private var showAll = false
    var savedShowAll: Binding<Bool>? = nil

    var body: some View {
        let showAll = savedShowAll ?? $showAll
        let running = tasks.filter { $0.state.isActive }.sorted { WorkOrder.started($0) < WorkOrder.started($1) }
        let finished = tasks.filter { !$0.state.isActive }.sorted { WorkOrder.ended($0) > WorkOrder.ended($1) }
        let shown = showAll.wrappedValue ? finished : Array(finished.prefix(AgentsCard.finishedShown))
        ReviewCard(title: "Background tasks", trailing: running.isEmpty ? "\(finished.count) finished" : "\(running.count) running") {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(running) { t in TaskRow(task: t, now: now) }
                if !running.isEmpty && !shown.isEmpty { Spacer().frame(height: 5) }
                ForEach(shown) { t in TaskRow(task: t, now: now) }
                if finished.count > AgentsCard.finishedShown {
                    MoreToggle(more: finished.count - AgentsCard.finishedShown, showingAll: showAll)
                }
            }
        }
    }
}

struct TaskRow: View {
    @EnvironmentObject var model: AppModel
    let task: BackgroundTaskInfo
    var now: Date?
    @State private var hovering = false

    var body: some View {
        let output = task.outputFile.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        WorkRowLayout(state: task.state, title: task.title, detail: detail, meta: meta,
                      time: WorkTime.Span(start: task.startedAt, end: task.endedAt, duration: task.duration, running: task.state.isActive),
                      now: now, highlighted: hovering && output != nil)
            .contentShape(Rectangle())
            .onTapGesture { if let output { model.openFile(output, line: nil) } }
            .onHover { hovering = $0 }
            .help(output != nil ? "Open its output in the Code tab" : (task.command ?? task.title))
    }

    private var meta: String? {
        switch task.kind {
        case .shell: return nil
        case .monitor: return "Monitor"
        case .terminal: return "Terminal"
        }
    }

    private var detail: String {
        let cmd = task.command.map(ToolCall.oneLine)
        let showCommand = cmd != nil && cmd != task.title
        switch task.state {
        case .running, .waiting:
            if let ev = task.lastEvent { return "Last event: " + ToolCall.oneLine(ev) }
            return showCommand ? cmd! : "Running"
        case .done:
            if task.kind == .monitor { return task.lastEvent.map { "Last event: " + ToolCall.oneLine($0) } ?? "Ended" }
            return task.exitCode.map { "Exit code \($0)" } ?? "Finished"
        case .failed:
            return task.exitCode.map { "Failed with exit code \($0)" } ?? "Failed"
        case .stopped:
            return "Stopped"
        case .stale:
            return WorkText.quiet("No output", since: task.lastUpdate)
        }
    }
}

/// One row: the state on the left, the title and a grey detail line, and the time and a
/// short meta on the right. Agents and tasks share it so the two cards line up.
struct WorkRowLayout: View {
    let state: WorkState
    let title: String
    let detail: String
    let meta: String?
    let time: WorkTime.Span
    var now: Date?
    var highlighted = false
    static let textInset: CGFloat = 6 + 14 + 8

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            WorkIndicator(state: state).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(state.isActive ? Color.hText : Color.hSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    WorkElapsed(span: time, now: now)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.hTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    if let meta {
                        Text(meta).font(.system(size: 11)).foregroundStyle(Color.hTertiary).lineLimit(1).fixedSize()
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(highlighted ? Color.hHover : .clear))
        .padding(.horizontal, -6)
    }
}

/// Running: the sidebar's pulsing dot. Waiting on its own agents: the idle ring. Finished:
/// the same symbols the Overview uses for checks and plan steps.
struct WorkIndicator: View {
    let state: WorkState

    var body: some View {
        Group {
            switch state {
            case .running: ActivityDot(activity: .working)
            case .waiting: ActivityDot(activity: .idle)
            case .done: Image(systemName: "checkmark.circle").font(.system(size: 11)).foregroundStyle(Color.hAdded)
            case .failed: Image(systemName: "xmark.circle").font(.system(size: 11)).foregroundStyle(Color.hRemoved)
            case .stopped: Image(systemName: "minus.circle").font(.system(size: 11)).foregroundStyle(Color.hTertiary)
            case .stale: ActivityDot(activity: .idle)
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// How long it's been running, ticking every second, or how long it took.
struct WorkElapsed: View {
    let span: WorkTime.Span
    var now: Date?

    var body: some View {
        if span.running, span.start != nil {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in text(span.seconds(now: now ?? ctx.date)) }
        } else {
            text(span.seconds(now: now ?? Date()))
        }
    }

    @ViewBuilder private func text(_ s: TimeInterval?) -> some View {
        if let s {
            Text(WorkTime.short(s)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.hTertiary).lineLimit(1).fixedSize()
        }
    }
}

extension WorkTime {
    struct Span: Equatable {
        var start: Date?
        var end: Date?
        var duration: TimeInterval?
        var running: Bool

        func seconds(now: Date) -> TimeInterval? {
            if running { return start.map { now.timeIntervalSince($0) } }
            if let duration { return duration }
            if let start, let end { return end.timeIntervalSince(start) }
            return nil
        }
    }
}

/// "Show 4 more" under the finished rows.
struct MoreToggle: View {
    let more: Int
    @Binding var showingAll: Bool
    @State private var hovering = false

    var body: some View {
        Button { showingAll.toggle() } label: {
            Text(showingAll ? "Show fewer" : "Show \(more) more")
                .font(.system(size: 11.5))
                .foregroundStyle(hovering ? Color.hSecondary : Color.hTertiary)
                .padding(.leading, WorkRowLayout.textInset - 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

enum WorkText {
    /// "No output for 45m": work that never reported back and went quiet.
    static func quiet(_ what: String, since: Date?, now: Date = Date()) -> String {
        guard let since else { return what + " for a while" }
        return "\(what) for \(WorkTime.short(now.timeIntervalSince(since)))"
    }

    /// "Explore  haiku", "opus 5.5". The general-purpose type is the default, so it's left out.
    static func meta(type: String?, model: String?) -> String? {
        var parts: [String] = []
        if let t = type, !t.isEmpty, t != "general-purpose" { parts.append(t) }
        if let m = model.flatMap(shortModel) { parts.append(m) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    /// "claude-opus-5-5" -> "opus 5.5". Aliases like "opus" and Codex names stay as they are.
    static func shortModel(_ m: String) -> String? {
        let t = m.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != "inherit" else { return nil }
        if t.hasPrefix("claude-") {
            let parts = t.dropFirst("claude-".count).split(separator: "-").map(String.init)
            if let family = parts.first {
                let version = parts.dropFirst().prefix { Int($0) != nil }
                return version.isEmpty ? family : "\(family) \(version.joined(separator: "."))"
            }
        }
        return t
    }

    /// The first line of a report that says something, without Markdown marks.
    static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = StatusText.plain(raw.trimmingCharacters(in: .whitespaces))
            if line.isEmpty || line.hasPrefix("```") || line == "---" || line.hasPrefix("|") { continue }
            return ToolCall.oneLine(line)
        }
        return nil
    }
}

/// Writes a report to a temporary Markdown file and opens it as a page in the Code tab.
enum WorkReport {
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("hantuu-reports", isDirectory: true) }

    static func fileName(for title: String) -> String {
        let cleaned = title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" ? Character($0) : " " }
        let name = String(cleaned).split(separator: " ").joined(separator: " ").prefix(80)
        return (name.isEmpty ? "Report" : String(name)) + ".md"
    }

    static func open(title: String, text: String, model: AppModel) {
        Paths.ensure(folder)
        let url = folder.appendingPathComponent(fileName(for: title))
        let body = "# \(title)\n\n" + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard (try? body.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        // Opening the same report again shows the new text.
        if let i = model.codeTabs.firstIndex(where: { $0.path == url.path }) { model.closeCodeTab(model.codeTabs[i].id) }
        model.openFile(url.path, line: nil)
    }
}

// MARK: - A little Markdown

/// Renders the parts of Markdown that agents' reports use, in SwiftUI: headings, lists,
/// paragraphs, code blocks and inline styles. The full page is one click away in Code.
struct ReportText: View {
    let markdown: String
    var maxBlocks = 16

    var body: some View {
        let blocks = MarkdownLite.blocks(markdown)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.prefix(maxBlocks).enumerated()), id: \.offset) { _, b in block(b) }
            if blocks.count > maxBlocks {
                Text("…").font(.system(size: 12)).foregroundStyle(Color.hTertiary)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func block(_ b: MarkdownLite.Block) -> some View {
        switch b {
        case .heading(let t):
            Text(MarkdownLite.inline(t)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.hText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        case .item(let marker, let t, let level):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.hTertiary)
                Text(MarkdownLite.inline(t)).font(.system(size: 12)).foregroundStyle(Color.hText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(level) * 14)
        case .paragraph(let t):
            Text(MarkdownLite.inline(t)).font(.system(size: 12)).foregroundStyle(Color.hText)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let t):
            Text(t).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.hSecondary)
                .lineLimit(14)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.hInk(0.04)))
        case .rule:
            Rectangle().fill(Color.hDivider).frame(height: 1).padding(.vertical, 2)
        }
    }
}

enum MarkdownLite {
    enum Block: Equatable {
        case heading(String)
        case item(marker: String, text: String, level: Int)
        case paragraph(String)
        case code(String)
        case rule
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]? = nil
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))) }
            para = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix("```") {
                    out.append(.code(code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(raw)
                }
                continue
            }
            if trimmed.hasPrefix("```") { flush(); code = []; continue }
            if trimmed.isEmpty { flush(); continue }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { flush(); out.append(.rule); continue }
            if trimmed.hasPrefix("#") {
                let h = trimmed.drop { $0 == "#" }
                if h.first == " " { flush(); out.append(.heading(h.trimmingCharacters(in: .whitespaces))); continue }
            }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            let level = min(indent / 2, 3)
            if let r = trimmed.range(of: #"^([-*+]|\d{1,3}[.)])\s+"#, options: .regularExpression) {
                flush()
                let m = trimmed[r].trimmingCharacters(in: .whitespaces)
                let marker = m.first.map { "-*+".contains($0) } == true ? "•" : m
                out.append(.item(marker: marker, text: String(trimmed[r.upperBound...]), level: level))
                continue
            }
            if trimmed.hasPrefix("|") {
                // Tables keep their shape as monospaced lines.
                flush()
                if case .code(let prev)? = out.last, prev.hasPrefix("|") { out[out.count - 1] = .code(prev + "\n" + trimmed) } else { out.append(.code(trimmed)) }
                continue
            }
            para.append(trimmed)
        }
        if let code { out.append(.code(code.joined(separator: "\n"))) }
        flush()
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
