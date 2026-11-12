import AppKit

enum ComposerAgentControlAction: Int, CaseIterable {
    case model, effort, permissions, plan

    var label: String {
        switch self {
        case .model: return "Model"
        case .effort: return "Effort"
        case .permissions: return "Permissions"
        case .plan: return "Plan"
        }
    }

    /// These open native controls. They never select an option or write configuration.
    /// Claude /plan enters Plan mode; it is deliberately not represented as a toggle.
    func command(for provider: TranscriptKind) -> String {
        switch self {
        case .model: return "/model"
        case .effort: return provider == .claude ? "/effort" : "/model"
        case .permissions: return "/permissions"
        case .plan: return "/plan"
        }
    }
}

struct ComposerAgentControlValue: Equatable {
    enum Evidence: String {
        case lastTranscript = "Last recorded in this session; the next turn may use different settings"
        case terminalFooter = "Shown in the current native terminal footer"
    }
    let text: String
    let evidence: Evidence
}

struct ComposerAgentControlsState: Equatable {
    let provider: TranscriptKind
    let sessionID: String?
    var model: ComposerAgentControlValue?
    var effort: ComposerAgentControlValue?
    var permissions: ComposerAgentControlValue?
    var plan: ComposerAgentControlValue?

    func value(for action: ComposerAgentControlAction) -> ComposerAgentControlValue? {
        switch action {
        case .model: return model
        case .effort: return effort
        case .permissions: return permissions
        case .plan: return plan
        }
    }

    /// A known active Claude Plan mode must be exited through the real terminal UI.
    var planNeedsTerminal: Bool { provider == .claude && plan?.text == "On" }
}

/// A pure snapshot of supplied records, never a reader of user configuration or credentials.
/// The caller owns the records and must bind them to the currently followed session.
/// Recompute after session/provider changes, transcript truncation, and terminal refresh.
enum ComposerAgentControlsParser {
    static func snapshot(provider: TranscriptKind, sessionID: String?, records: [Data] = [],
                         screen: String = "") -> ComposerAgentControlsState {
        var state = ComposerAgentControlsState(provider: provider, sessionID: sessionID)
        guard let sessionID, !sessionID.isEmpty else { return state }
        var codexSessionMatches = false
        for data in records {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let type = object["type"] as? String
            if provider == .codex {
                let payload = object["payload"] as? [String: Any] ?? [:]
                if type == "session_meta" {
                    codexSessionMatches = payload["id"] as? String == sessionID
                    // A new session boundary invalidates every old field, including missing ones.
                    state = ComposerAgentControlsState(provider: provider, sessionID: sessionID)
                }
                guard codexSessionMatches, type == "turn_context" else { continue }
                state.model = recorded(payload["model"])
                state.effort = recorded(payload["effort"])
                let sandbox = payload["sandbox_policy"] as? [String: Any]
                let approval = clean(payload["approval_policy"])
                let access = clean(sandbox?["type"])
                state.permissions = [access, approval].compactMap { $0 }.isEmpty ? nil
                    : recorded([access, approval].compactMap { $0 }.joined(separator: " / "))
                let mode = (payload["collaboration_mode"] as? [String: Any])?["mode"] as? String
                state.plan = mode == "plan" ? recorded("On") : mode == "default" ? recorded("Off") : nil
            } else {
                guard object["sessionId"] as? String == sessionID,
                      object["isSidechain"] as? Bool != true else { continue }
                if type == "assistant", object["isApiErrorMessage"] as? Bool != true,
                   let message = object["message"] as? [String: Any],
                   let value = recorded(message["model"]), value.text != "<synthetic>" {
                    state.model = value
                }
                // Claude transcript prose, tool names, and proposed plans do not establish
                // effort or permission mode. Leave them unknown until a real footer does.
            }
        }
        // Only recognize native Claude footer syntax, never arbitrary conversation mentions
        // of "plan mode". Missing footer clears current evidence on the next snapshot.
        if provider == .claude {
            for raw in screen.split(whereSeparator: \.isNewline).suffix(3) {
                let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
                guard line.contains("(shift+tab to cycle)") else { continue }
                let modes: [(String, String)] = [("plan mode on", "Plan"), ("accept edits on", "Accept edits"),
                                                ("bypass permissions on", "Bypass permissions"), ("auto mode on", "Auto"),
                                                ("manual mode on", "Manual"), ("don't ask on", "Don't ask")]
                for (marker, label) in modes where line.hasPrefix(marker) || line.hasPrefix("⏵⏵ " + marker) || line.hasPrefix("⏸ " + marker) {
                    state.permissions = ComposerAgentControlValue(text: label, evidence: .terminalFooter)
                    state.plan = ComposerAgentControlValue(text: label == "Plan" ? "On" : "Off", evidence: .terminalFooter)
                }
            }
        }
        return state
    }

    private static func clean(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return trimmed
    }

    private static func recorded(_ value: Any?) -> ComposerAgentControlValue? {
        clean(value).map { ComposerAgentControlValue(text: $0, evidence: .lastTranscript) }
    }
}

/// A compact native strip. The controller retains drafts and performs all transport and
/// readiness rechecks. This view never sends keys and never changes state optimistically.
final class ComposerAgentControlsView: NSView {
    var onAction: ((ComposerAgentControlAction) -> Void)?
    private(set) var displayedState: ComposerAgentControlsState?
    private var buttons: [NSButton] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        for action in ComposerAgentControlAction.allCases {
            let button = NSButton(title: action.label, target: self, action: #selector(activate(_:)))
            button.tag = action.rawValue
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.lineBreakMode = .byTruncatingTail
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.setAccessibilityIdentifier("composer-agent-\(action.label.lowercased())")
            row.addArrangedSubview(button)
            buttons.append(button)
        }
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 26) }

    func update(state: ComposerAgentControlsState, enabled: Bool, disabledReason: String? = nil) {
        displayedState = state
        for action in ComposerAgentControlAction.allCases {
            let button = buttons[action.rawValue]
            let value = state.value(for: action)
            let suffix = value.map { "\($0.text)\($0.evidence == .lastTranscript ? " (last)" : "")" }
            button.title = suffix.map { "\(action.label): \($0)" } ?? "\(action.label)…"
            button.isEnabled = enabled
            let operation: String
            if action == .plan {
                operation = state.planNeedsTerminal ? "Open terminal to change Plan mode" : "Enter Plan mode in the native agent"
            } else if action == .permissions && state.provider == .claude {
                operation = "Open Claude's permission rules dialog"
            } else {
                operation = "Open native \(action.label.lowercased()) control"
            }
            let evidence = value?.evidence.rawValue ?? "Current value unavailable; check the native control"
            button.toolTip = [operation, evidence, enabled ? nil : disabledReason].compactMap { $0 }.joined(separator: ". ")
            button.setAccessibilityLabel("\(action.label): \(suffix ?? "unknown")")
            button.setAccessibilityHelp(button.toolTip)
        }
    }

    @objc private func activate(_ sender: NSButton) {
        guard sender.isEnabled, let action = ComposerAgentControlAction(rawValue: sender.tag) else { return }
        onAction?(action)
    }
}
