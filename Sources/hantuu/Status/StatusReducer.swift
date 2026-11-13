import Foundation

enum AgentKind: Equatable {
    case claude, codex, other
    init(agentID: String) {
        switch agentID {
        case "claude": self = .claude
        case "codex": self = .codex
        default: self = .other
        }
    }
}

struct StatusContext {
    var agent: AgentKind
    /// The chat is selected and hantuu is the active app.
    var focused: Bool
    var now: Date = Date()
    /// BackgroundWatch reports this chat's background work, so a turn's end waits for its next check.
    var watchesBackground = false
}

/// The facts behind a chat's state. `activity` and `detail` are derived from them, so the
/// order signals arrive in can't leave two flags disagreeing.
struct StatusState: Equatable {
    struct Wait: Equatable {
        enum Kind: Equatable { case permission, answer }
        var kind: Kind
        /// The tool call it waits on (Claude), so only that call's PostToolUse clears it.
        var toolUseID: String?
        var detail: String
        var at: Date
        /// Raised by a weaker source (a late Notification hook, the bell). Cleared more eagerly.
        var fallback = false
    }

    var ended = false
    var turnActive = false
    var workingDetail = "Thinking"
    var waits: [Wait] = []
    var finalQuestion: String?
    var unseen = false
    var doneAt: Date?
    /// Shown instead of "Done 2m ago": "Interrupted", "Stopped: API Error: ...".
    var idleNote: String?
    /// Timestamp of the last interruption for disambiguating a later transport's redraw.
    var interruptedAt: Date?
    var lastMessage: String?
    /// Claude tool calls between PreToolUse and PostToolUse, by tool_use_id.
    var running: [String: ToolCall] = [:]
    var runningOrder: [String] = []
    var codexOpen: Set<String> = []
    var codexDone: [String] = []
    /// A hook or notify line arrived, so terminal fallbacks no longer move the state.
    var structured = false
    var progressActive = false
    /// The latest command a tool ran this turn. Codex's approval notification cuts its command
    /// short, so the full one comes from here.
    var lastCommand: String?
    /// Subagents and background tasks still running after the main turn ended. While any
    /// are, the chat reads as running in background rather than done.
    var background = BackgroundSummary()
    /// The last of them just finished with the main agent idle. Claude Code hands each result
    /// to the agent as a new turn, so the chat waits this long for that turn before it's Done,
    /// rather than saying Done twice.
    var settleUntil: Date?
    var settleDoneAt: Date?
    var turnStartedAt: Date?
    /// The turn just ended. Agents it started in its last seconds may not be counted yet, so
    /// it reads Working until a background check that began after this time.
    var checkAfter: Date?

    var activity: AgentActivity {
        if ended { return .ended }
        if let w = waits.first { return w.kind == .permission ? .needsPermission : .needsAnswer }
        if turnActive { return .working }
        if finalQuestion != nil { return .needsAnswer }
        if checkAfter != nil { return .working }
        if background.count > 0 || settleUntil != nil { return .background }
        if unseen { return .doneUnseen }
        return .idle
    }

    /// The grey line under the chat title. Empty means "show Done Xm ago, or the agent name".
    var detail: String {
        if ended { return "Ended" }
        if let w = waits.first { return w.detail }
        if turnActive { return workingDetail }
        if let q = finalQuestion { return "Asks: \(q)" }
        if checkAfter != nil { return workingDetail }
        if background.count > 0 { return background.detail }
        if settleUntil != nil { return "Background work finished" }
        if let n = idleNote { return n }
        return ""
    }

    /// Changes whenever the chat enters a new state worth one notification.
    var headKey: String {
        switch activity {
        case .needsPermission, .needsAnswer:
            if let w = waits.first { return "\(activity.rawValue)|\(w.toolUseID ?? "")|\(w.detail)|\(w.at.timeIntervalSince1970)" }
            return "\(activity.rawValue)|q|\(doneAt?.timeIntervalSince1970 ?? 0)"
        case .doneUnseen:
            return "done|\(doneAt?.timeIntervalSince1970 ?? 0)"
        default:
            return activity.rawValue
        }
    }
}

/// Precedence, one source of truth per state:
/// - Claude Code: hooks own Working, Needs permission, Needs answer and Done. The transcript
///   only adds the two things hooks never report: an interrupt and a declined prompt.
///   The terminal (bell, OSC 9/777, OSC 9;4) only counts until the first hook line arrives.
/// - Codex: the rollout owns Working and turn ends, `notify` also ends turns (both carry turn
///   ids, so they can't double up), and its OSC 9 notifications own the Needs states.
/// - Other agents: OSC 9;4 progress for Working, the bell and notifications for Needs.
/// - Ended always comes from the process exiting, outside this reducer.
enum StatusReducer {
    static func structured(_ st: StatusState, _ ctx: StatusContext) -> Bool { st.structured || ctx.agent == .codex }

    static func apply(_ s: OriginSignal, to st: inout StatusState, ctx: StatusContext) {
        guard !st.ended else { return }
        if s.origin == .hook || s.origin == .notify { st.structured = true }
        if s.origin == .terminal {
            terminal(s.signal, &st, ctx)
            return
        }
        switch s.signal {
        case .sessionStarted(let source):
            if source != "compact" { reset(&st) }

        case .promptSubmitted:
            beginTurn(&st, ctx)

        case .toolStarted(let id, let call):
            if let id, call.agentID != nil, !st.turnActive {
                // A background subagent working after the main turn ended (seen live: one ran
                // `cat` right after Stop). It doesn't make the chat Working, but a question
                // or a permission prompt from it still needs you.
                if st.running[id] == nil { st.runningOrder.append(id) }
                st.running[id] = call
                if call.isQuestion || call.isPlan { addWait(.answer, id: id, detail: call.askText, &st, ctx) }
                return
            }
            let wasActive = st.turnActive
            st.turnActive = true
            st.finalQuestion = nil
            st.unseen = false
            st.idleNote = nil
            if !wasActive {
                st.waits.removeAll { $0.fallback }
                st.turnStartedAt = ctx.now
                st.settleUntil = nil
                st.checkAfter = nil
            }
            if let id {
                if st.running[id] == nil { st.runningOrder.append(id) }
                st.running[id] = call
            }
            if call.isQuestion || call.isPlan {
                addWait(.answer, id: id, detail: call.askText, &st, ctx)
            } else {
                st.workingDetail = call.workingText
                if let c = call.command { st.lastCommand = c }
            }

        case .permissionRequested(let call):
            if call.agentID == nil || st.turnActive {
                st.turnActive = true
                st.finalQuestion = nil
                st.unseen = false
                st.idleNote = nil
            }
            let id = matchRunning(call, st)
            let answer = call.isQuestion || call.isPlan
            addWait(answer ? .answer : .permission, id: id, detail: answer ? call.askText : call.wantsText, &st, ctx)

        case .toolFinished(let id), .declined(let id):
            if let id {
                st.running[id] = nil
                st.runningOrder.removeAll { $0 == id }
                st.waits.removeAll { $0.toolUseID == id || $0.fallback }
            } else {
                st.waits.removeAll { $0.toolUseID == nil }
            }

        case .turnEnded(let last):
            endTurn(&st, ctx, last: last)

        case .turnFailed(let reason):
            endTurn(&st, ctx, last: reason)
            st.finalQuestion = nil
            st.idleNote = "Stopped: " + ToolCall.oneLine(reason)

        case .interrupted:
            interrupt(&st, at: ctx.now)

        case .notification(let type, let message):
            let text = ToolCall.oneLine(message)
            switch type {
            case "permission_prompt":
                // About six seconds late. Only fills in when no PermissionRequest arrived,
                // such as a sandboxed command's network request.
                if !st.waits.contains(where: { $0.kind == .permission }) {
                    addWait(.permission, id: nil, detail: text.isEmpty ? "Wants permission" : text, &st, ctx, fallback: true)
                }
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                if !st.waits.contains(where: { $0.kind == .answer }) {
                    addWait(.answer, id: nil, detail: text.isEmpty ? "Waiting for your input" : text, &st, ctx, fallback: true)
                }
            case "elicitation_complete", "elicitation_response":
                st.waits.removeAll { $0.fallback && $0.kind == .answer }
            case "idle_prompt":
                // A minute after a turn ended. Corrects a turn whose Stop never arrived.
                if st.turnActive && st.waits.isEmpty { endTurn(&st, ctx, last: nil) }
            default:
                break
            }

        case .sessionEnded(let reason):
            if reason == "clear" { reset(&st) }

        case .codexTurnStarted(let id):
            guard !st.codexDone.contains(id) else { return }
            st.codexOpen.insert(id)
            beginTurn(&st, ctx)

        case .codexTurnComplete(let id, let last):
            if let id {
                if st.codexDone.contains(id) { return }
                if !st.codexOpen.isEmpty && !st.codexOpen.contains(id) { return }
                st.codexOpen.remove(id)
                remember(id, &st)
            }
            if st.codexOpen.isEmpty { endTurn(&st, ctx, last: last) }

        case .codexTurnAborted(let id, let reason):
            if let id {
                if st.codexDone.contains(id) { return }
                st.codexOpen.remove(id)
                remember(id, &st)
            }
            if st.codexOpen.isEmpty {
                if reason == "interrupted" {
                    interrupt(&st, at: ctx.now)
                } else {
                    endTurn(&st, ctx, last: nil)
                    st.idleNote = "Stopped"
                }
            }

        case .terminalNotice, .progress:
            terminal(s.signal, &st, ctx)

        case .background(let summary):
            background(summary, &st, ctx)
        }
    }

    /// Background work changed. When the last of it finishes while the main agent is idle,
    /// the chat is done from when the work ended. Claude Code first hands the results to the
    /// agent as a turn of their own, so unless that turn already happened, wait for it.
    private static func background(_ s: BackgroundSummary, _ st: inout StatusState, _ ctx: StatusContext) {
        let was = st.background.count
        st.background = s
        if let after = st.checkAfter, (s.checkedAt ?? .distantPast) >= after || ctx.now.timeIntervalSince(after) > 10 {
            // The check the ended turn was waiting for: Done, or running in background.
            st.checkAfter = nil
        }
        if was > 0, s.count == 0, !st.turnActive {
            let handled = st.turnStartedAt.map { started in s.endedAt.map { started >= $0.addingTimeInterval(-2) } ?? false } ?? false
            if !handled {
                st.settleUntil = ctx.now.addingTimeInterval(ctx.agent == .claude ? 20 : 8)
                st.settleDoneAt = s.endedAt ?? ctx.now
            }
        }
        if let until = st.settleUntil, ctx.now >= until {
            // No turn came: done since the work ended.
            st.settleUntil = nil
            if !st.turnActive, st.background.count == 0 {
                st.doneAt = st.settleDoneAt ?? ctx.now
                st.unseen = !ctx.focused
                st.idleNote = nil
            }
        }
    }

    /// The bell, desktop notifications and OSC 9;4 progress.
    private static func terminal(_ signal: StatusSignal, _ st: inout StatusState, _ ctx: StatusContext) {
        switch signal {
        case .terminalNotice(let text):
            if ctx.agent == .codex {
                // Codex sends these on purpose (tui.notifications), so they own its Needs states.
                guard let text else { return }
                var (kind, detail) = TerminalNoticeText.classify(text)
                let prefix = "Wants to run "
                if kind == .permission, detail.hasPrefix(prefix), let full = st.lastCommand {
                    var shown = String(detail.dropFirst(prefix.count))
                    for tail in ["...", "…"] where shown.hasSuffix(tail) { shown = String(shown.dropLast(tail.count)) }
                    if full.hasPrefix(shown) { detail = prefix + ToolCall.oneLine(full) }
                }
                switch kind {
                case .permission: addWait(.permission, id: nil, detail: detail, &st, ctx)
                case .answer: addWait(.answer, id: nil, detail: detail, &st, ctx)
                case .done, .other: break
                }
                return
            }
            guard !structured(st, ctx) else { return }
            guard let text, !text.isEmpty else {
                addWait(.answer, id: nil, detail: "Waiting for you", &st, ctx, fallback: true)
                return
            }
            let (kind, detail) = TerminalNoticeText.classify(text)
            switch kind {
            case .permission: addWait(.permission, id: nil, detail: detail, &st, ctx, fallback: true)
            case .answer, .other: addWait(.answer, id: nil, detail: detail.isEmpty ? "Waiting for you" : detail, &st, ctx, fallback: true)
            case .done: endTurn(&st, ctx, last: nil)
            }

        case .progress(let active):
            guard !structured(st, ctx) else { return }
            if active {
                if !st.progressActive { beginTurn(&st, ctx); st.workingDetail = "Working" }
                st.progressActive = true
            } else if st.progressActive {
                st.progressActive = false
                endTurn(&st, ctx, last: nil)
            }

        default:
            break
        }
    }

    /// The chat was looked at: Done becomes Idle. Needs states stay until the agent resumes,
    /// except a terminal fallback, which is all an unstructured agent ever gives.
    static func markSeen(_ st: inout StatusState, ctx: StatusContext) {
        st.unseen = false
        if !structured(st, ctx) { st.waits.removeAll { $0.fallback } }
    }

    // MARK: Helpers

    private static func beginTurn(_ st: inout StatusState, _ ctx: StatusContext) {
        let wasActive = st.turnActive
        st.turnActive = true
        st.finalQuestion = nil
        st.unseen = false
        st.idleNote = nil
        if !wasActive {
            st.turnStartedAt = ctx.now
            st.settleUntil = nil
            st.checkAfter = nil
            st.workingDetail = "Thinking"
            st.lastCommand = nil
            st.waits.removeAll()
            st.running.removeAll()
            st.runningOrder.removeAll()
        }
    }

    private static func endTurn(_ st: inout StatusState, _ ctx: StatusContext, last: String?) {
        st.checkAfter = st.turnActive && ctx.watchesBackground ? ctx.now : nil
        st.turnActive = false
        st.settleUntil = nil
        st.progressActive = false
        st.waits.removeAll()
        st.running.removeAll()
        st.runningOrder.removeAll()
        st.doneAt = ctx.now
        st.lastMessage = last
        st.finalQuestion = StatusText.finalQuestion(last)
        st.idleNote = nil
        st.unseen = !ctx.focused
    }

    private static func interrupt(_ st: inout StatusState, at time: Date) {
        st.turnActive = false
        st.progressActive = false
        st.waits.removeAll()
        st.running.removeAll()
        st.runningOrder.removeAll()
        st.finalQuestion = nil
        st.unseen = false
        st.idleNote = "Interrupted"
        st.interruptedAt = time
    }

    private static func reset(_ st: inout StatusState) {
        let structured = st.structured
        let background = st.background
        st = StatusState()
        st.structured = structured
        // Comes from the transcript, not the turn, so a new session keeps it until it's re-read.
        st.background = background
    }

    private static func remember(_ id: String, _ st: inout StatusState) {
        st.codexDone.append(id)
        if st.codexDone.count > 64 { st.codexDone.removeFirst(st.codexDone.count - 64) }
    }

    private static func addWait(_ kind: StatusState.Wait.Kind, id: String?, detail: String,
                                _ st: inout StatusState, _ ctx: StatusContext, fallback: Bool = false) {
        if let id, st.waits.contains(where: { $0.toolUseID == id }) { return }
        if id == nil, st.waits.contains(where: { $0.toolUseID == nil && $0.kind == kind && $0.detail == detail }) { return }
        st.waits.append(.init(kind: kind, toolUseID: id, detail: detail, at: ctx.now, fallback: fallback))
    }

    /// PermissionRequest carries no tool_use_id. Match it to the newest running call with the
    /// same tool and input (and subagent), so a parallel subagent's PostToolUse can't clear it.
    private static func matchRunning(_ call: ToolCall, _ st: StatusState) -> String? {
        let waited = Set(st.waits.compactMap(\.toolUseID))
        let candidates = st.runningOrder.reversed().filter { !waited.contains($0) }
        if let id = candidates.first(where: { st.running[$0]?.name == call.name && st.running[$0]?.inputKey == call.inputKey && st.running[$0]?.agentID == call.agentID }) {
            return id
        }
        return candidates.first(where: { st.running[$0]?.name == call.name && st.running[$0]?.agentID == call.agentID })
    }
}
