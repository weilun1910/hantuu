import AppKit

let args = CommandLine.arguments
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
