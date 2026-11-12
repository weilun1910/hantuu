import Foundation

/// Every delayed transport step checks current evidence, not the state at button-down.
enum ReaderSubmissionGuard {
    static func refusal(screen: String, waiting: Bool, command: String?) -> String? {
        if waiting { return "The agent is waiting for an answer in the terminal." }
        let tail = screen.split(whereSeparator: \.isNewline).suffix(16).joined(separator: "\n")
        // Claude's /pe suggestions include /fewer-permission-prompts with the
        // description "Pre-approve safe read-only commands". That is catalogue text,
        // not an approval request. Exempt only described slash rows during a command;
        // an actual trust/update/approval prompt on another line must still block.
        let suggestionPattern = #"^\s*[›❯>]?\s*/[A-Za-z][A-Za-z0-9_:-]*[ \t]{2,}\S"#
        let hasSuggestions = command != nil && tail.split(separator: "\n").contains {
            $0.range(of: suggestionPattern, options: .regularExpression) != nil
        }
        let lower = tail.split(separator: "\n").filter {
            !hasSuggestions || $0.range(of: suggestionPattern, options: .regularExpression) == nil
        }.joined(separator: "\n").lowercased()
        let approval = ["allow once", "yes, allow", "do you want to proceed", "would you like to run", "approve", "permission required", "sign in", "log in"]
        if approval.contains(where: lower.contains) { return "Answer the permission or sign-in dialog in the terminal." }
        let state = TerminalScreen.analyze(screen)
        guard let menu = state.menu else { return nil }
        if menu.kind == .menu, hasSuggestions { return nil }
        return menu.title(agent: "Agent") + ". Input was held."
    }
}

/// A local waiting message drains only at its own agent's ready boundary.
enum ReaderQueueDrain {
    static func canStart(screen: TerminalScreen.State, activity: AgentActivity,
                         waiting: Bool, turnActive: Bool, identityWaiting: Bool, paused: Bool,
                         inputNeedsReview: Bool, editing: Bool, transportBusy: Bool) -> Bool {
        screen.ready && !screen.busy && screen.menu == nil &&
            activity != .working && activity != .ended && !activity.isNeeds &&
            !waiting && !turnActive && !identityWaiting && !paused && !inputNeedsReview &&
            !editing && !transportBusy
    }
}

/// Tracks an observed empty input after Return before inferring a later native restore.
/// Merely waiting longer cannot distinguish a slow CLI from a restored prompt.
struct ReaderInputRestoration {
    var terminal: ObjectIdentifier
    var sessionID: String?
    var pendingID: String
    private var observedEmpty = false

    init(terminal: ObjectIdentifier, sessionID: String?, pendingID: String = "") {
        self.terminal = terminal
        self.sessionID = sessionID
        self.pendingID = pendingID
    }

    mutating func observe(empty: Bool, matches: Bool, eligible: Bool) -> Bool {
        if empty { observedEmpty = true }
        return observedEmpty && !empty && matches && eligible
    }
}
