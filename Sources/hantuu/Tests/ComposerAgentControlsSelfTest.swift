import AppKit

extension SelfTest {
    /// Synthetic values in provider record envelopes. No personal transcripts are fixtures.
    static func composerAgentControls(_ dir: URL) {
        func data(_ lines: [String]) -> [Data] { lines.map { Data($0.utf8) } }
        let claude = data([
            #"{"type":"assistant","sessionId":"c1","message":{"model":"claude-example","content":[]}}"#,
            #"{"type":"assistant","sessionId":"c1","isSidechain":true,"message":{"model":"child-model"}}"#,
            #"{"type":"assistant","sessionId":"other","message":{"model":"wrong-session"}}"#
        ])
        let codex = data([
            #"{"type":"session_meta","payload":{"id":"x1"}}"#,
            #"{"type":"turn_context","payload":{"model":"codex-example","effort":"low","approval_policy":"on-request","sandbox_policy":{"type":"workspace-write"},"collaboration_mode":{"mode":"plan"}}}"#
        ])
        let c = ComposerAgentControlsParser.snapshot(provider: .claude, sessionID: "c1", records: claude)
        check("controls: Claude model comes from matching main session", c.model?.text == "claude-example")
        check("controls: historical model is explicitly historical", c.model?.evidence == .lastTranscript)
        check("controls: no invented Claude effort or mode", c.effort == nil && c.permissions == nil && c.plan == nil)
        let x = ComposerAgentControlsParser.snapshot(provider: .codex, sessionID: "x1", records: codex)
        check("controls: Codex turn settings", x.model?.text == "codex-example" && x.effort?.text == "low")
        check("controls: Codex permission policy kept explicit", x.permissions?.text == "workspace-write / on-request")
        check("controls: Codex collaboration mode distinct from checklist", x.plan?.text == "On")
        let wrong = ComposerAgentControlsParser.snapshot(provider: .codex, sessionID: "different", records: codex)
        check("controls: old session cannot populate new controls", wrong.model == nil && wrong.plan == nil)
        let noID = ComposerAgentControlsParser.snapshot(provider: .claude, sessionID: nil, records: claude,
                                                        screen: "⏸ plan mode on (shift+tab to cycle)")
        check("controls: unresolved session clears every value", noID.model == nil && noID.plan == nil)
        let noMode = ComposerAgentControlsParser.snapshot(provider: .codex, sessionID: "x1", records: codex + data([
            #"{"type":"turn_context","payload":{"model":"next"}}"#
        ]))
        check("controls: missing newer fields invalidate old settings", noMode.model?.text == "next" && noMode.effort == nil && noMode.plan == nil)
        let prose = ComposerAgentControlsParser.snapshot(provider: .claude, sessionID: "c1", records: data([
            #"{"type":"assistant","sessionId":"c1","message":{"content":[{"type":"tool_use","name":"EnterPlanMode"}]}}"#
        ]), screen: "I will enter plan mode on your request.")
        check("controls: attempted tool and prose cannot confirm Plan", prose.plan == nil)
        let footer = ComposerAgentControlsParser.snapshot(provider: .claude, sessionID: "c1", records: claude,
                                                          screen: "prompt\n⏸ plan mode on (shift+tab to cycle)")
        check("controls: native footer confirms Plan", footer.plan?.text == "On" && footer.plan?.evidence == .terminalFooter)
        check("controls: active Claude Plan opens terminal to exit", footer.planNeedsTerminal)
        let gone = ComposerAgentControlsParser.snapshot(provider: .claude, sessionID: "c1", records: claude, screen: "prompt")
        check("controls: missing footer never leaves old current evidence", gone.plan == nil)
        let auto = ComposerAgentControlsParser.snapshot(provider: .claude, sessionID: "c1", screen: "⏵⏵ auto mode on (shift+tab to cycle)")
        check("controls: native Auto is not Plan", auto.permissions?.text == "Auto" && auto.plan?.text == "Off")
        check("controls: effort routes through each provider's real control", ComposerAgentControlAction.effort.command(for: .claude) == "/effort" && ComposerAgentControlAction.effort.command(for: .codex) == "/model")
        check("controls: Claude permissions opens rules", ComposerAgentControlAction.permissions.command(for: .claude) == "/permissions")

        let view = ComposerAgentControlsView(frame: NSRect(x: 0, y: 0, width: 700, height: 30))
        view.update(state: footer, enabled: true)
        view.update(state: wrong, enabled: false, disabledReason: "Wait until the agent is ready")
        check("controls: view replaces state across provider and session changes", view.displayedState == wrong)
        let output = dir.appendingPathComponent("composer-agent-controls", isDirectory: true)
        do { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        catch { check("controls: snapshot directory", false, String(describing: error)); return }
        for (name, state) in [("claude", footer), ("codex", x), ("unknown", wrong)] {
            for dark in [false, true] {
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor(white: dark ? 0.12 : 0.98, alpha: 1).cgColor
                view.update(state: state, enabled: name != "unknown", disabledReason: "Waiting for session")
                view.layoutSubtreeIfNeeded()
                let filename = "\(name)-\(dark ? "dark" : "light").png"
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    check("controls: \(filename) render", false); continue
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = bitmap.representation(using: .png, properties: [:])
                do {
                    guard let png else { check("controls: \(filename) encoding", false); continue }
                    try png.write(to: output.appendingPathComponent(filename))
                    check("controls: \(filename) snapshot", true)
                } catch { check("controls: \(filename) write", false, String(describing: error)) }
            }
        }
    }
}
