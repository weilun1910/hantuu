import Foundation

/// Every delayed transport step checks current evidence, not the state at button-down.
enum ReaderSubmissionGuard {
    static func refusal(screen: String, waiting: Bool, command: String?) -> String? {
        if waiting { return "The agent is waiting for an answer in the terminal." }
        let tail = screen.split(whereSeparator: \.isNewline).suffix(16).joined(separator: "\n")
        let lower = tail.lowercased()
        let approval = ["allow once", "yes, allow", "do you want to proceed", "would you like to run", "approve", "permission required", "sign in", "log in"]
        if approval.contains(where: lower.contains) { return "Answer the permission or sign-in dialog in the terminal." }
        let state = TerminalScreen.analyze(screen)
        guard let menu = state.menu else { return nil }
        if menu.kind == .menu, command != nil {
            let suggestion = tail.range(of: #"(?m)^\s*[›❯>]?\s*/[A-Za-z][A-Za-z0-9_:-]*[ \t]{2,}\S"#, options: .regularExpression) != nil
            if suggestion { return nil }
        }
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
