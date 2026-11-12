import AppKit

let args = CommandLine.arguments
if args.contains(ReaderRequestBridge.flag) { exit(ReaderRequestBridge.runHook()) }
let known: Set<String> = ["--self-test", "--workdir", "--data-dir", "--no-pmset", "--open-project", "--new-chat"]
let valueFlags: Set<String> = ["--workdir", "--data-dir", "--open-project", "--new-chat"]

var i = 1
while i < args.count {
    let a = args[i]
    if a.hasPrefix("-psn_") { i += 1; continue } // Finder's process serial number
    if a.hasPrefix("--") && !known.contains(a) {
        print("Unknown flag \(a). Flags: --self-test [--workdir <dir>], --data-dir <dir>, --no-pmset, --open-project <folder>, --new-chat <agent>")
        exit(2)
    }
    i += valueFlags.contains(a) ? 2 : 1
}

// Started from inside another agent session (a terminal running Claude Code, `open` from an
// agent's shell), the app inherits that session's markers, and every chat would too. Claude
// Code then treats itself as a child session: it stops saving transcripts (so the reader goes
// blank) and turns off terminal titles. Chats run under a login shell, which re-applies the
// user's own exports, so dropping these here loses nothing.
let inheritedAgentPrefixes = ["CLAUDE", "ANTHROPIC_", "CODEX_", "MCP_", "AI_AGENT"]
for key in ProcessInfo.processInfo.environment.keys where inheritedAgentPrefixes.contains(where: { key.hasPrefix($0) }) {
    unsetenv(key)
}

if args.contains("--self-test") {
    var workdir = FileManager.default.temporaryDirectory.appendingPathComponent("hantuu-selftest", isDirectory: true)
    if let w = args.firstIndex(of: "--workdir"), w + 1 < args.count {
        workdir = URL(fileURLWithPath: args[w + 1], isDirectory: true)
    }
    // Keep the self test's own log out of the user's data folder.
    if !args.contains("--data-dir") && ProcessInfo.processInfo.environment["HANTUU_DATA_DIR"] == nil {
        Paths.dataDir = workdir.appendingPathComponent("data", isDirectory: true)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let code = MainActor.assumeIsolated { SelfTest.run(workdir: workdir) }
    exit(code)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
