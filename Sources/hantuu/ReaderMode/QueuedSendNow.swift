import AppKit

/// Native queue actions, rather than resending text that the terminal already owns.
enum QueuedSendNow {
    enum Scope: Equatable { case all, message }
    struct Action {
        var label: String
        var scope: Scope
        var keys: [TerminalKeyStroke]
    }

    static func available(agentID: String, screen: String) -> Bool {
        guard action(agentID: agentID) != nil else { return false }
        let normalized = screen.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if agentID == "codex" {
            // A pending transcript acknowledgement alone does not prove Codex still owns a
            // steer. Its queue hint is the evidence that Esc promotes rather than just stops.
            return normalized.contains("esc to interrupt and send immediately")
        }
        return normalized.contains("ctrl+enter to send now") || normalized.contains("ctrl+x ctrl+s to send now")
    }

    static func action(agentID: String) -> Action? {
        switch agentID {
        case "claude":
            // Claude documents this chord as the equivalent of Ctrl-Return in terminals
            // without extended key reporting. It sends the entire queue and terminal draft.
            return Action(label: "Send queue now", scope: .all, keys: [
                TerminalKeyStroke(keyCode: 7, codepoint: 120, modifiers: .control),
                TerminalKeyStroke(keyCode: 1, codepoint: 115, modifiers: .control),
            ])
        case "codex":
            // Enter steers are promoted together by interrupting the current turn. Tab's
            // deferred queue is a separate path and is not used by the reader composer.
            return Action(label: "Send queue now", scope: .all, keys: [
                TerminalKeyStroke(keyCode: 53, codepoint: 27),
            ])
        default: return nil
        }
    }
}
