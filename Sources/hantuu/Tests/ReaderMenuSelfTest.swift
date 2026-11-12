import AppKit

extension SelfTest {
    /// Source-derived fixtures, NOT live terminal captures. Codex strings are pinned to
    /// rust-v0.167.1, codex-rs/tui/src/chatwidget/snapshots and bottom_pane/request_user_input/snapshots:
    /// https://github.com/openai/codex/tree/rust-v0.167.1/codex-rs/tui/src
    /// Claude glyphs follow installed 2.1.322 (❯, ☒, ☐). Fixture questions and labels are synthetic.
    static func readerMenus(_ dir: URL) {
        let command = "printf '%s\\n' 'menuprobe" + String(repeating: "a", count: 32) + "'"
        func commandJSON(_ command: String, background: Bool = false) -> String {
            let data = try! JSONSerialization.data(withJSONObject: ["command": command, "run_in_background": background])
            return String(decoding: data, as: UTF8.self)
        }
        check("menus live safety: only exact generated harmless command qualifies",
              LiveCheckRules.menuProbeCommandMatches(inputJSON: commandJSON(command), expected: command))
        check("menus live safety: suffixes, background execution and arbitrary expectations refuse",
              !LiveCheckRules.menuProbeCommandMatches(inputJSON: commandJSON(command + "; pwd"), expected: command) &&
              !LiveCheckRules.menuProbeCommandMatches(inputJSON: commandJSON(command, background: true), expected: command) &&
              !LiveCheckRules.menuProbeCommandMatches(inputJSON: commandJSON("pwd"), expected: "pwd"))
        let exec = """
        Would you like to run the following command?
        Reason: this is a test reason such as one that would be produced by the model
        $ echo hello world
        › 1. Yes, proceed (y)
          2. Yes, and don't ask again for commands that start with `echo hello world` (p)
          3. No, and tell Codex what to do differently (esc)
        Press enter to confirm or esc to cancel
        """
        let question = """
        Question 1/2 (2 unanswered)
        Choose an option.
        › 1. Option 1  First choice.
          2. Option 2  Second choice.
          3. Option 3  Third choice.
        tab to add notes | enter to submit answer | ←/→ to navigate questions | esc to interrupt
        """
        let effort = """
        Select Reasoning Level for GPT-5.5
          1. Low
          2. Medium (default)
        › 3. High (current)
          4. Extra high
          5. Persistent
          6. More reasoning…
        enter default · s session · esc back
        """
        // request_user_input_freeform, options_notes_visible and multi_question_last
        // snapshots from the same pinned tag. These are NOT live captures.
        let freeform = """
        Question 1/1 (1 unanswered)
        Share details.
          › Type your answer (optional)
        enter to submit answer | esc to interrupt
        """
        let notes = """
        Question 1/1 (1 unanswered)
        Choose an option.
        › 1. Option 1  First choice.
          2. Option 2  Second choice.
          › Add notes
        tab or esc to clear notes | enter to submit answer
        """
        let lastQuestion = """
        Question 2/2 (2 unanswered)
        Share details.
        › Type your answer (optional)
        enter to submit all | ⌃p / ⌃n change question | esc to interrupt
        """
        // Installed Claude slider geometry, source-derived rather than a live capture.
        func slider(_ selection: Int, count: Int = 5) -> String {
            let levels = ["low", "medium", "high", "xhigh", "max"]
            let starts = [0, 8, 19, 28, 39]
            let positions = [1, 10, 20, 30, 40]
            var labels = ""
            for index in 0..<count {
                labels += String(repeating: " ", count: starts[index] - labels.count) + levels[index]
            }
            var track = Array(repeating: Character("─"), count: max(starts[count - 1] + levels[count - 1].count, 14))
            track[positions[selection]] = "▲"
            return "Effort\n" + labels + "\n" + String(track) + "\nEnter to confirm, Left/Right to adjust, s for this session only, Esc to cancel"
        }
        func fixture(_ title: String, _ rows: String = "❯ 1. First\n  2. Second", footer: String = "Enter to confirm | Esc to cancel") -> String {
            title + "\n" + rows + "\n" + footer
        }
        let cases: [(String, String, String, ReaderMenu.Kind)] = [
            ("permission", "codex", exec, .permission),
            ("question", "codex", question, .question),
            ("freeform", "codex", freeform, .freeText),
            ("notes-input", "codex", notes, .freeText),
            ("last-question-input", "codex", lastQuestion, .freeText),
            ("effort-truncated-fallback", "codex", effort, .effort),
            ("choice", "claude", fixture("Choose a display style"), .choice),
            ("checkboxes", "claude", fixture("Choose preferences", "❯ 1. ☒ First\n  2. ☐ Second\n  3. Submit", footer: "Space to toggle | Enter to select | Esc to cancel"), .multiSelect),
            ("model", "claude", fixture("Select model"), .model),
            ("effort", "claude", fixture("Select effort"), .effort),
            ("effort-slider", "claude", slider(1), .effort),
            ("effort-slider-capped", "claude", slider(1, count: 2), .effort),
            ("search", "claude", fixture("Resume a past session\nSearch: fixture"), .search),
            ("settings", "claude", fixture("Settings"), .settings),
            ("trust", "claude", fixture("Do you trust this folder?"), .trust),
            ("update", "claude", fixture("Update available"), .update),
            ("color-only-fallback", "claude", fixture("Select model", "1. First\n2. Second"), .model)
        ]
        var parsed: [(String, ReaderMenu)] = []
        for (name, agent, screen, kind) in cases {
            let menu = ReaderMenuParser.parse(screen, agent: agent)
            check("menus parser: \(name) source-derived or synthetic fixture", menu?.kind == kind)
            if let menu { parsed.append((name, menu)) }
        }
        check("menus parser: two-pointer notes focus input without guessing option focus",
              ReaderMenuParser.parse(notes, agent: "codex")?.input == ReaderMenu.Input(value: "", placeholder: "Add notes") &&
              ReaderMenuParser.parse(notes, agent: "codex")?.actionable == true)
        check("menus parser: freeform preserves echoed single-line input",
              ReaderMenuParser.parse(freeform.replacingOccurrences(of: "Type your answer (optional)", with: "Fixture answer"), agent: "codex")?.input?.value == "Fixture answer")
        check("menus parser: remapped submit key does not claim Enter support",
              ReaderMenuParser.parse(freeform.replacingOccurrences(of: "enter to submit answer", with: "⌃j to submit answer"), agent: "codex") == nil)
        check("menus parser: approval preserves exact command", parsed.first?.1.context.contains("$ echo hello world") == true)
        check("menus parser: color-only and truncated choices refuse action", parsed.filter { $0.0.contains("fallback") }.allSatisfy { !$0.1.actionable && $0.1.refusal != nil })
        check("menus parser: ordinary prose and slash suggestions are not menus",
              ReaderMenuParser.parse("1. First\n2. Second\nDone", agent: "claude") == nil &&
              ReaderMenuParser.parse("❯ /model\n/model Choose model\n? for shortcuts", agent: "claude") == nil)
        check("menus parser: duplicate labels refuse", ReaderMenuParser.parse(fixture("Select model", "❯ 1. Same\n2. Same"), agent: "claude")?.actionable == false)
        check("menus parser: multiple highlighted rows refuse", ReaderMenuParser.parse(fixture("Select model", "❯ 1. First\n❯ 2. Second"), agent: "claude")?.actionable == false)
        check("menus parser: missing cancel and unknown providers refuse", ReaderMenuParser.parse(fixture("Select model", footer: "Enter to select"), agent: "claude") == nil && ReaderMenuParser.parse(exec, agent: "other") == nil)
        guard let original = ReaderMenuParser.parse(exec, agent: "codex") else { return }
        if var effortMenu = parsed.first(where: { $0.0 == "model" })?.1 {
            effortMenu.allowsHorizontal = true
            effortMenu.context = "Current effort: medium"
            check("menus live effort: explicit current effort recognized", LiveCheckRules.currentClaudeEffort(effortMenu) == "medium")
            effortMenu.context = "Available effort levels: low medium high"
            check("menus live effort: available levels cannot stand in for current value", LiveCheckRules.currentClaudeEffort(effortMenu) == nil)
        }
        let sliderMenu = ReaderMenuParser.parse(slider(1), agent: "claude")
        check("menus parser: slider has exact current label and horizontal selection",
              sliderMenu?.selected == "medium" && sliderMenu?.horizontalSelection == true && sliderMenu?.allowsSessionConfirm == true)
        check("menus parser: capped slider preserves only available options",
              ReaderMenuParser.parse(slider(1, count: 2), agent: "claude")?.options.map(\.label) == ["low", "medium"])
        check("menus parser: slider without triangle or with corrupt track refuses",
              ReaderMenuParser.parse(slider(1).replacingOccurrences(of: "▲", with: "─"), agent: "claude") == nil &&
              ReaderMenuParser.parse(slider(1).replacingOccurrences(of: "─", with: "-"), agent: "claude") == nil)
        check("menus parser: slider with wrong triangle position refuses",
              ReaderMenuParser.parse(slider(1).replacingOccurrences(of: "──────────▲", with: "─────────▲─"), agent: "claude") == nil)
        if let sliderMenu, let sliderHigh = ReaderMenuParser.parse(slider(2), agent: "claude") {
            check("menus parser: moving triangle preserves menu form", sliderMenu.sameForm(as: sliderHigh))
            var higher = ReaderMenuSelection(menu: sliderMenu, label: "high", confirm: false)
            check("menus selection: higher slider label sends Right", higher.observe(sliderMenu, closed: false) == .key(.right))
            check("menus selection: slider waits for exact label before completing", higher.observe(sliderMenu, closed: false) == .wait && higher.observe(sliderHigh, closed: false) == .done)
            var lower = ReaderMenuSelection(menu: sliderHigh, label: "medium", confirm: false)
            check("menus selection: lower slider label sends Left", lower.observe(sliderHigh, closed: false) == .key(.left) && lower.observe(sliderMenu, closed: false) == .done)
            check("menus live effort: slider triangle establishes current value", LiveCheckRules.currentClaudeEffort(sliderMenu) == "medium")
        }
        let bounded = "1. Old prose\n2. Old prose\n" + fixture("Select model")
        check("menus parser: last heading excludes earlier numbered prose", ReaderMenuParser.parse(bounded, agent: "claude")?.options.map(\.label) == ["First", "Second"])
        let target = original.options[2].label
        var selection = ReaderMenuSelection(menu: original, label: target)
        check("menus selection: move one row without number shortcut", selection.observe(original, closed: false) == .key(.down))
        check("menus selection: unchanged screen waits without extra keys", selection.observe(original, closed: false) == .wait)
        var middle = original
        middle.selected = original.options[1].label
        check("menus selection: observed intermediate highlight permits next arrow", selection.observe(middle, closed: false) == .key(.down))
        var selected = original
        selected.selected = target
        check("menus selection: first exact target read waits", selection.observe(selected, closed: false) == .wait)
        check("menus selection: second exact target read sends Enter once", selection.observe(selected, closed: false) == .key(.enter))
        check("menus selection: confirmed screen never retries Enter", selection.observe(selected, closed: false) == .wait && selection.observe(nil, closed: false) == .wait && selection.observe(selected, closed: false) == .wait)
        check("menus selection: observed closure finishes", selection.observe(nil, closed: true) == .done)
        var moved = ReaderMenuSelection(menu: original, label: original.selected!)
        _ = moved.observe(original, closed: false)
        _ = moved.observe(original, closed: false)
        check("menus selection: post-confirm move finishes without replay", moved.observe(middle, closed: false) == .done)
        func refuses(_ effect: ReaderMenuSelection.Effect) -> Bool { if case .refuse = effect { return true }; return false }
        for field in ["command", "title", "labels", "refusal"] {
            var reducer = ReaderMenuSelection(menu: original, label: original.selected!)
            _ = reducer.observe(original, closed: false)
            var changed = original
            switch field {
            case "command": changed.context = "$ different-command"
            case "title": changed.title = "Different request"
            case "labels": changed.options[0].label = "Different option"
            default: changed.refusal = "Unverified"
            }
            check("menus selection: changed \(field) refuses before Enter", refuses(reducer.observe(changed, closed: false)))
        }
        var sessionMenu = original
        sessionMenu.kind = .effort
        sessionMenu.footer = "enter default | s session | esc back"
        var sessionSelection = ReaderMenuSelection(menu: sessionMenu, label: sessionMenu.selected!, sessionOnly: true)
        check("menus selection: session confirmation still requires two exact reads", sessionSelection.observe(sessionMenu, closed: false) == .wait && sessionSelection.observe(sessionMenu, closed: false) == .key(.session))
        check("menus selection: session confirmation is never retried", sessionSelection.observe(sessionMenu, closed: false) == .wait)
        var unsupportedSession = ReaderMenuSelection(menu: original, label: original.selected!, sessionOnly: true)
        _ = unsupportedSession.observe(original, closed: false)
        check("menus selection: session key requires explicit footer support", refuses(unsupportedSession.observe(original, closed: false)))
        var consecutive = ReaderMenuSelection(menu: original, label: original.selected!)
        _ = consecutive.observe(original, closed: false)
        check("menus selection: target departure starts corrective navigation", consecutive.observe(middle, closed: false) == .key(.up))
        check("menus selection: returning target requires two fresh consecutive reads", consecutive.observe(original, closed: false) == .wait && consecutive.observe(original, closed: false) == .key(.enter))
        var unexpected = ReaderMenuSelection(menu: original, label: target)
        _ = unexpected.observe(original, closed: false)
        check("menus selection: unexpected highlight refuses", refuses(unexpected.observe(selected, closed: false)))
        var noConfirm = ReaderMenuSelection(menu: original, label: original.selected!, confirm: false)
        check("menus selection: navigation-only never confirms", noConfirm.observe(original, closed: false) == .done)
        if let checkbox = parsed.first(where: { $0.0 == "checkboxes" })?.1 {
            var toggle = ReaderMenuSelection(menu: checkbox, label: checkbox.options[0].label)
            _ = toggle.observe(checkbox, closed: false)
            check("menus selection: checkbox uses Space once", toggle.observe(checkbox, closed: false) == .key(.space) && toggle.observe(checkbox, closed: false) == .wait)
            var submitMenu = checkbox
            submitMenu.selected = "Submit"
            var submit = ReaderMenuSelection(menu: submitMenu, label: "Submit")
            _ = submit.observe(submitMenu, closed: false)
            check("menus selection: explicit Submit uses Enter", submit.observe(submitMenu, closed: false) == .key(.enter))
        }
        if let inputMenu = ReaderMenuParser.parse(freeform, agent: "codex") {
            check("menus input: control characters and destructive replacement refuse",
                  ReaderMenuTextSubmission.suffix(for: "line\nline", menu: inputMenu) == nil)
            var typed = inputMenu
            typed.input?.value = "Typed answer"
            check("menus input: existing text is never erased", ReaderMenuTextSubmission.suffix(for: "Replacement", menu: typed) == nil)
            var answer = ReaderMenuTextSubmission(menu: inputMenu, text: "Typed answer")
            check("menus input: unpainted paste waits", answer.observe(inputMenu, closed: false) == .wait)
            check("menus input: exact echo must be observed twice", answer.observe(typed, closed: false) == .wait && answer.observe(typed, closed: false) == .key(.enter))
            check("menus input: Return is never replayed", answer.observe(typed, closed: false) == .wait && answer.observe(nil, closed: true) == .done)
            var mismatch = ReaderMenuTextSubmission(menu: inputMenu, text: "Different answer")
            check("menus input: mismatched echo refuses Return", refuses(mismatch.observe(typed, closed: false)))
            var changed = inputMenu
            changed.context = "A different question"
            var stale = ReaderMenuTextSubmission(menu: inputMenu, text: "Typed answer")
            check("menus input: changed question refuses Return", refuses(stale.observe(changed, closed: false)))
        }
        let output = dir.appendingPathComponent("reader-menus", isDirectory: true)
        Paths.ensure(output)
        for (name, menu) in parsed {
            for dark in [false, true] {
                let view = ReaderMenuCard(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                view.update(menu: menu)
                view.frame.size.height = max(1, view.preferredHeight)
                view.layoutSubtreeIfNeeded()
                check("menus card: \(name) retains displayed menu", view.displayedMenu == menu && view.preferredHeight > 0)
                let filename = "\(name)-\(dark ? "dark" : "light").png"
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { check("menus snapshot: \(filename)", false); continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                do {
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { check("menus snapshot encoding", false); continue }
                    try png.write(to: output.appendingPathComponent(filename))
                    check("menus snapshot: \(filename)", true)
                } catch { check("menus snapshot: \(filename)", false, String(describing: error)) }
                view.update(menu: nil)
                check("menus card: clears stale menu", view.displayedMenu == nil)
            }
        }
    }
}
