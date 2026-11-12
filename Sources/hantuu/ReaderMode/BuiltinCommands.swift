import Foundation

extension ReaderCommandCatalog {
    /// Checked against Claude's commands reference and Codex rust-v0.167.1 on 2026-11-11.
    /// The popup omits debug commands. The agent still handles manually typed names.
    /// This is a fallback until a complete live menu supplies the current account gates.
    static func builtins(agent: String) -> [ReaderCommand] {
        let rows: [(String, String)]
        let panels: Set<String>
        let noArguments: Set<String>
        if agent == "claude" {
            rows = [
                ("add-dir", "Grant directory access"), ("advisor", "Choose advisor"),
                ("autocompact", "Adjust compaction window"),
                ("background", "Detach session"), ("branch", "Branch conversation"),
                ("btw", "Ask aside"), ("bug", "Report problem"), ("cd", "Change directory"),
                ("chrome", "Browser integration"), ("clear", "Start fresh"),
                ("color", "Prompt color"), ("compact", "Summarize context"),
                ("config", "Preferences"), ("context", "Context breakdown"),
                ("copy", "Copy answer"), ("diff", "Inspect edits"),
                ("effort", "Reasoning level"), ("exit", "Close session"),
                ("export", "Save conversation"), ("fast", "Toggle speed"),
                ("feedback", "Product feedback"), ("fork", "Copy session"),
                ("goal", "Set objective"), ("help", "Command reference"),
                ("hooks", "Hook settings"), ("ide", "Editor integration"),
                ("import", "Import configuration"), ("init", "Create project instructions"),
                ("insights", "Session analysis"), ("keybindings", "Keyboard settings"),
                ("list-agents", "Reachable agents"), ("login", "Sign in"), ("logout", "Sign out"),
                ("mcp", "Server connections"), ("memory", "Manage memory"),
                ("model", "Choose model"), ("output-style", "Response style"),
                ("permissions", "Tool rules"), ("plan", "Planning mode"),
                ("plugin", "Manage plugins"), ("privacy-settings", "Privacy controls"),
                ("rate-limit-options", "Usage options"), ("recap", "Session summary"),
                ("release-notes", "Version changes"), ("reload-plugins", "Refresh plugins"),
                ("reload-skills", "Refresh skills"), ("remote-control", "Remote access"),
                ("rename", "Rename session"), ("restart", "Restart CLI"),
                ("resume", "Reopen conversation"), ("rewind", "Restore checkpoint"),
                ("sandbox", "Sandbox settings"), ("status", "Session information"),
                ("tasks", "Background work"), ("theme", "Terminal appearance"),
                ("usage", "Account usage"),
                ("focus", "Focus mode"), ("statusline", "Configure status line"),
                ("terminal-setup", "Configure terminal"), ("upgrade", "Account upgrade"),
                ("usage-credits", "Usage credits"), ("voice", "Voice input"),
                ("skills", "Available skills"), ("install-github-app", "GitHub integration"),
                ("install-slack-app", "Slack integration"), ("mobile", "Mobile access"),
                ("remote-env", "Remote environment"), ("scroll-speed", "Scrolling speed"),
                ("teleport", "Move session"), ("tui", "Terminal interface"),
                ("web-setup", "Web setup"), ("desktop", "Desktop integration"),
                ("artifacts", "Artifact settings"), ("auto-mode-setup", "Configure auto mode"),
                ("autofix-pr", "Fix pull request"), ("design-login", "Design sign-in"),
                ("powerup", "Session tools"), ("radio", "Audio controls"),
                ("skill-doctor", "Check skills"), ("stickers", "Sticker settings"),
                ("subtask", "Manage subtask"), ("ultrareview", "Review code"),
                ("workflows", "Manage workflows"),
            ]
            panels = ["bug", "chrome", "context", "copy", "diff", "feedback", "help", "hooks", "ide", "import", "keybindings", "list-agents", "login", "memory", "permissions", "privacy-settings", "rate-limit-options", "release-notes", "remote-control", "rewind", "sandbox", "status", "tasks", "theme", "usage", "skills", "upgrade", "usage-credits", "terminal-setup", "desktop", "mobile"]
            noArguments = ["advisor", "autocompact", "btw", "config", "effort", "export", "goal", "mcp", "model", "output-style", "plugin", "resume"]
        } else if agent == "codex" {
            rows = [
                ("model", "Model and reasoning"), ("presets", "Reusable prompts"),
                ("daybreak", "Toggle Daybreak"), ("ide", "Editor context"),
                ("permissions", "Tool permissions"), ("keymap", "Keyboard settings"),
                ("vim", "Vim editing"), ("experimental", "Feature settings"),
                ("approve", "Retry denied action"), ("memories", "Memory settings"),
                ("skills", "Choose skill"), ("import", "Import configuration"),
                ("hooks", "Lifecycle hooks"), ("review", "Review edits"),
                ("rename", "Rename chat"), ("new", "New conversation"),
                ("archive", "Archive session"), ("delete", "Delete session"),
                ("resume", "Reopen chat"), ("fork", "Branch chat"),
                ("worktree", "Worktree picker"), ("app", "Continue in desktop app"), ("init", "Project instructions"),
                ("compact", "Summarize context"), ("config", "Preferences"),
                ("recap", "Conversation summary"), ("plan", "Planning mode"),
                ("voice", "Voice input"), ("goal", "Task objective"),
                ("agents", "Agent center"), ("side", "Side conversation"), ("btw", "Ask aside"),
                ("copy", "Copy answer"), ("export", "Save conversation"),
                ("raw", "Plain scrollback"), ("tui", "Terminal mode"),
                ("diff", "Inspect edits"), ("mention", "Choose file"),
                ("status", "Session information"), ("daemon", "Background server"),
                ("warnings", "Diagnostic messages"), ("cd", "Change directory"),
                ("pwd", "Current directory"), ("usage", "Account usage"),
                ("title", "Window title"),
                ("statusline", "Footer settings"), ("theme", "Syntax colors"),
                ("pets", "Terminal companion"), ("mcp", "Server tools"),
                ("plugins", "Manage plugins"),
                ("logout", "Sign out"), ("quit", "Close session"), ("exit", "Close session"),
                ("feedback", "Report problem"), ("ps", "Background terminals"),
                ("stop", "Stop background terminals"), ("clear", "Start fresh"),
                ("subagents", "Switch subagent"),
            ]
            panels = ["presets", "ide", "keymap", "experimental", "memories", "skills", "import", "hooks", "delete", "worktree", "config", "agents", "side", "btw", "copy", "tui", "diff", "mention", "status", "daemon", "warnings", "pwd", "theme", "plugins", "feedback", "ps", "subagents"]
            noArguments = ["model", "permissions", "review", "resume", "new", "fork", "goal", "voice", "export", "usage", "title", "statusline", "pets", "mcp"]
        } else { return [] }
        var commands = rows.map { name, description in
            ReaderCommand(name: name, description: description, source: "CLI fallback",
                          peek: panels.contains(name) ? .always : (noArguments.contains(name) ? .withoutArguments : .never))
        }
        if agent == "codex" {
            for index in commands.indices {
                if commands[index].name == "btw" { commands[index].aliasOf = "side" }
                if commands[index].name == "quit" { commands[index].aliasOf = "exit" }
            }
        }
        if agent == "claude" {
            let bundled = [
                ("batch", "Parallel changes"), ("claude-api", "API guidance"),
                ("code-review", "Find defects"), ("debug", "Diagnose session"),
                ("doctor", "Check configuration"), ("loop", "Repeat prompt"),
                ("run", "Exercise application"),
                ("security-review", "Security assessment"), ("simplify", "Clean up code"),
                ("verify", "Verify application"),
                ("artifact-capabilities", "Artifact guidance"), ("artifact-diagramming", "Artifact diagrams"),
                ("claude-in-chrome", "Browser guidance"), ("dataviz", "Data visualization"),
                ("design", "Design guidance"), ("design-sync", "Synchronize design"),
                ("fewer-permission-prompts", "Configure permissions"), ("run-skill-generator", "Generate skill"),
                ("schedule", "Schedule work"), ("send-to-project", "Send to project"),
                ("slides", "Presentation guidance"), ("update-config", "Update configuration"),
                ("workflow-authoring", "Create workflow"), ("team-onboarding", "Team onboarding"),
                ("plugin-authoring", "Create plugin"),
            ]
            commands += bundled.map { ReaderCommand(name: $0.0, description: $0.1, source: "bundled skill") }
        }
        return commands
    }
}
