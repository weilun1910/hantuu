import AppKit
import GhosttyKit
import SwiftUI

/// Self-test checks for sessions and worktrees. Every session here lives in the self test's
/// own socket folder (keyed by its throwaway data folder), is tracked by id, and is stopped at
/// the end. The only process signalled directly is a session server this test started. Git
/// work happens only in scratch repos inside the workdir.
extension SelfTest {
    private static var testSessions: [String] = []

    static func sessions(_ dir: URL) {
        guard let helper = SessionHelper.executable else {
            check("sessions: hantuu-session built next to the app", false, "missing next to \(CommandLine.arguments[0])")
            return
        }
        check("sessions: hantuu-session built next to the app", true)
        SessionHelper.prepare()
        sessionCommands(helper)
        sessionReplay(helper)
        if GhosttyApp.shared != nil {
            sessionSurvivesAndReattaches(helper, dir)
            sessionResize(helper, dir)
            sessionEnds(helper, dir)
        }
        sessionListAndKill(dir)
        sessionStaleSocket(dir)
        worktrees(dir)
        sessionCleanup()
        snapshots(dir)
    }

    // MARK: Commands and paths

    static func sessionCommands(_ helper: String) {
        let long = URL(fileURLWithPath: "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/Desktop/🫣 Solo Projects/👻 hantuu/app.nosync/.claude/worktrees/agent-a1be3120d75d278b3/tmp/appdata")
        let d = SessionHelper.socketDir(for: long)
        let sock = d + "/" + UUID().uuidString + ".sock"
        check("sessions: socket path fits in sun_path even for a long emoji data folder", sock.utf8.count < 104, "\(sock.utf8.count) bytes")
        check("sessions: each data folder gets its own socket folder",
              d == SessionHelper.socketDir(for: long) && d != SessionHelper.socketDir(for: long.appendingPathComponent("other")))
        var st = stat()
        let ok = lstat(SessionHelper.socketDir, &st) == 0 && st.st_uid == getuid() && st.st_mode & 0o077 == 0
        check("sessions: socket folder is private to this user", ok && SessionHelper.socketDir.hasPrefix("/tmp/hantuu-\(getuid())/"))
        let pointer = (try? String(contentsOf: SessionHelper.dataFolder.appendingPathComponent("socket-dir"), encoding: .utf8)) ?? ""
        check("sessions: data folder records where the sockets are", pointer.trimmingCharacters(in: .whitespacesAndNewlines) == SessionHelper.socketDir)

        let id = UUID()
        let cmd = LoginShell.surfaceCommand(["claude", "--session-id", "abc"], session: SessionLaunch(chatID: id, mode: .create(cwd: "/a b/🫣")))
        let inner = "printf '\\033[H\\033[2J'; exec " + [helper, "attach", "--socket-dir", SessionHelper.socketDir, "--id", id.uuidString,
                                                          "--create", "--cwd", "/a b/🫣", "--", "claude", "--session-id", "abc"]
            .map(ShellEscape.quote).joined(separator: " ")
        check("sessions: chats launch inside hantuu-session, through the login shell",
              cmd == "\(ShellEscape.quote(LoginShell.path)) -l -i -c \(ShellEscape.quote(inner))", cmd)
        let re = LoginShell.surfaceCommand([], session: SessionLaunch(chatID: id, mode: .attach))
        check("sessions: reattaching only attaches, never starts a new agent", re.contains(" attach ") && !re.contains("--create") && !re.contains(" -- "))
        check("sessions: no permission-bypass flags", ![cmd, re].contains { $0.contains("dangerously") || $0.contains("bypass") || $0.contains("--yolo") || $0.contains("full-auto") })
    }

    // MARK: Replay

    static func runHelper(_ helper: String, _ args: [String], input: Data) -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helper)
        p.arguments = args
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return Data() }
        inPipe.fileHandleForWriting.write(input)
        try? inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return out
    }

    static func sessionReplay(_ helper: String) {
        let e = "\u{1b}"
        // Modes and a title set early (they fall out of a 4 KB buffer), then queries, a bell,
        // a notification and a terminfo request, then ordinary output.
        let stream = "\(e)[?2004h\(e)[>1u\(e)]2;old title\u{07}line one\n\(e)[?1049hscreen\n" + String(repeating: "x", count: 5000) + "\n"
            + "\(e)[c\(e)[6n\(e)]11;?\u{07}\u{07}\(e)]9;done\u{07}\(e)P+q544e\(e)\\kept \(e)[1mbold\(e)[0m\n"
        let out = String(decoding: runHelper(helper, ["debug-replay", "--ring", "4096"], input: Data(stream.utf8)), as: UTF8.self)
        check("replay: restores modes set before the buffer (alt screen, bracketed paste, kitty keys, title)",
              out.hasPrefix("\(e)[?1049h") && out.contains("\(e)[?2004h") && out.contains("\(e)[>1u") && out.contains("\(e)]2;old title\u{07}"),
              out.prefix(80).debugDescription)
        check("replay: keeps ordinary output and colours", out.contains("kept \(e)[1mbold\(e)[0m"))
        check("replay: drops queries so a new terminal doesn't answer them into the agent",
              !out.contains("\(e)[c") && !out.contains("\(e)[6n") && !out.contains("]11;?") && !out.contains("\(e)P"))
        check("replay: drops old bells and notifications", out.filter { $0 == "\u{07}" }.count == 1 && !out.contains("]9;"))
        let first = String(decoding: runHelper(helper, ["debug-replay", "--ring", "4096", "--first"], input: Data(stream.utf8)), as: UTF8.self)
        check("replay: the creating client gets the output untouched", first.contains("\(e)[6n"))
    }

    // MARK: Live sessions in Ghostty surfaces

    static func newSessionID() -> String {
        let id = "selftest-" + UUID().uuidString.prefix(8).lowercased()
        testSessions.append(id)
        return id
    }

    static func attachCommand(_ helper: String, id: String, cwd: String, script: String?) -> String {
        var c = "\(ShellEscape.quote(helper)) attach --socket-dir \(ShellEscape.quote(SessionHelper.socketDir)) --id \(id)"
        if let script { c += " --create --cwd \(ShellEscape.quote(cwd)) -- /bin/sh -c \(ShellEscape.quote(script))" }
        return c
    }

    static func sessionSurface(_ command: String, cwd: String, env: [String: String] = [:], width: CGFloat? = nil) -> (TerminalView, Recorder) {
        let w = makeWindow()
        let rec = Recorder()
        let v = TerminalView(app: GhosttyApp.shared!.app, launch: .init(workingDirectory: cwd, command: command, environment: env), handlesChildExit: true)
        v.events = rec
        var f = w.contentView!.bounds
        if let width { f.size.width = width }
        v.frame = f
        w.contentView!.addSubview(v)
        return (v, rec)
    }

    static func info(_ id: String) -> SessionInfo? { SessionHelper.list().first { $0.id == id } }

    static func maxNumber(after word: String, in text: String) -> Int {
        let re = try! NSRegularExpression(pattern: word + #" (\d+)"#)
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { Int(ns.substring(with: $0.range(at: 1))) }.max() ?? 0
    }

    static func parentPID(_ pid: Int32) -> Int32 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return -1 }
        return info.kp_eproc.e_ppid
    }

    static func alive(_ pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    static func sessionSurvivesAndReattaches(_ helper: String, _ dir: URL) {
        let id = newSessionID()
        let script = #"i=0; while :; do i=$((i+1)); echo "tick $i $HANTUU_CHAT_ID $HANTUU_SELFTEST_VAR"; sleep 0.2; done"#
        let (v1, _) = sessionSurface(attachCommand(helper, id: id, cwd: dir.path, script: script), cwd: dir.path,
                                     env: ["HANTUU_CHAT_ID": id, "HANTUU_SELFTEST_VAR": "env-passes-through"])
        check("sessions: agent output reaches the terminal through the helper", waitUntil(10) { maxNumber(after: "tick", in: v1.screenText()) >= 3 },
              String(v1.screenText().suffix(300)))
        check("sessions: the agent gets the chat's environment", v1.screenText().contains("\(id) env-passes-through"))
        let first = info(id)
        check("sessions: list shows the session, attached", first?.attached == true && first?.cwd == dir.path, "\(String(describing: first))")
        if let s = first {
            check("sessions: server is in its own session, reparented away from the app",
                  getsid(s.pid) > 0 && getsid(s.pid) != getsid(0) && getpgid(s.pid) != getpgid(0) && parentPID(s.pid) == 1,
                  "sid=\(getsid(s.pid)) app=\(getsid(0)) ppid=\(parentPID(s.pid))")
        }
        let before = maxNumber(after: "tick", in: v1.screenText())
        v1.destroy() // what quitting or crashing does to the client
        check("sessions: session survives its client being killed", waitUntil(5) { info(id)?.attached == false })
        check("sessions: agent keeps running with no client", alive(first?.child ?? -1))
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        let (v2, _) = sessionSurface(attachCommand(helper, id: id, cwd: dir.path, script: nil), cwd: dir.path)
        check("sessions: reattach shows what it printed while detached", waitUntil(8) { maxNumber(after: "tick", in: v2.screenText()) >= before + 5 },
              "before=\(before) now=\(maxNumber(after: "tick", in: v2.screenText()))")
        let replayed = maxNumber(after: "tick", in: v2.screenText())
        check("sessions: output keeps flowing after reattach", waitUntil(5) { maxNumber(after: "tick", in: v2.screenText()) >= replayed + 3 })
        check("sessions: list shows it attached again", info(id)?.attached == true)
        v2.destroy()
    }

    struct SizeLine { let n: Int, rows: Int, cols: Int }

    static func sizeLines(_ text: String) -> [SizeLine] {
        let re = try! NSRegularExpression(pattern: #"size#(\d+) (\d+) (\d+)"#)
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            SizeLine(n: Int(ns.substring(with: $0.range(at: 1)))!, rows: Int(ns.substring(with: $0.range(at: 2)))!, cols: Int(ns.substring(with: $0.range(at: 3)))!)
        }
    }

    static func sessionResize(_ helper: String, _ dir: URL) {
        let id = newSessionID()
        let script = #"n=0; trap 'n=$((n+1)); echo "size#$n $(stty size)"' WINCH; echo "size#0 $(stty size)"; while :; do sleep 0.1; done"#
        let (v1, _) = sessionSurface(attachCommand(helper, id: id, cwd: dir.path, script: script), cwd: dir.path)
        guard waitUntil(10, { !sizeLines(v1.screenText()).isEmpty }) else {
            check("sessions: resize test agent started", false, String(v1.screenText().suffix(300)))
            v1.destroy()
            return
        }
        _ = waitUntil(1.0) { false } // let the first layout settle
        let wide = sizeLines(v1.screenText()).last!
        v1.frame = NSRect(x: 0, y: 0, width: 460, height: v1.frame.height)
        check("sessions: window size changes reach the agent (SIGWINCH forwarded)",
              waitUntil(5) { (sizeLines(v1.screenText()).last?.cols ?? 999) < wide.cols },
              "wide=\(wide.cols) lines=\(sizeLines(v1.screenText()).map { "\($0.n):\($0.cols)" })")
        let narrow = sizeLines(v1.screenText()).last!
        let lastN = sizeLines(v1.screenText()).map(\.n).max() ?? 0
        v1.destroy()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        // Same size as before: the helper nudges the size so the agent still hears about it.
        let (v2, _) = sessionSurface(attachCommand(helper, id: id, cwd: dir.path, script: nil), cwd: dir.path, width: 460)
        check("sessions: reattaching nudges the agent to redraw at the right size",
              waitUntil(6) { let l = sizeLines(v2.screenText()); return (l.map(\.n).max() ?? 0) > lastN && l.last?.cols == narrow.cols },
              "lastN=\(lastN) narrow=\(narrow.cols) lines=\(sizeLines(v2.screenText()).map { "\($0.n):\($0.cols)" })")
        v2.destroy()
    }

    static func sessionEnds(_ helper: String, _ dir: URL) {
        let w = makeWindow()
        let id = newSessionID()
        let (v1, rec) = sessionSurface(attachCommand(helper, id: id, cwd: dir.path, script: #"echo ready; read -r x; echo "bye $x"; exit 7"#), cwd: dir.path)
        _ = waitUntil(8) { v1.screenText().contains("ready") }
        w.makeFirstResponder(v1)
        type("abc\r", into: v1, window: w)
        check("sessions: typed input reaches the agent", waitUntil(5) { v1.screenText().contains("bye abc") }, String(v1.screenText().suffix(200)))
        check("sessions: the terminal's process exits when the agent does", waitUntil(5) { rec.exitCode != nil })
        let sock = SessionHelper.socketDir + "/" + id + ".sock"
        check("sessions: the session ends and removes its socket", waitUntil(3) { !FileManager.default.fileExists(atPath: sock) && info(id) == nil })
        v1.destroy()

        let quick = newSessionID()
        let (v2, rec2) = sessionSurface(attachCommand(helper, id: quick, cwd: dir.path, script: "echo quick-exit-marker"), cwd: dir.path)
        check("sessions: output of an agent that exits straight away still shows",
              waitUntil(8) { v2.screenText().contains("quick-exit-marker") && rec2.exitCode != nil }, String(v2.screenText().suffix(200)))
        v2.destroy()
    }

    // MARK: list and kill

    static func sessionListAndKill(_ dir: URL) {
        let id = newSessionID()
        let d = SessionHelper.socketDir
        let create = ["create", "--socket-dir", d, "--id", id, "--cwd", dir.path, "--", "/bin/sh", "-c", "while :; do sleep 1; done"]
        check("sessions: create starts a detached session", SessionHelper.run(create).code == 0)
        let s = info(id)
        check("sessions: list shows it, detached, with its agent", s?.attached == false && alive(s?.child ?? -1), "\(String(describing: s))")
        check("sessions: create refuses an id that's already running", SessionHelper.run(create).code == 3)
        check("sessions: kill stops it", SessionHelper.run(["kill", "--socket-dir", d, "--id", id]).code == 0)
        check("sessions: after kill it's gone from list, with its agent", info(id) == nil && waitUntil(3) { !alive(s?.child ?? -1) && !alive(s?.pid ?? -1) })
        check("sessions: kill of a missing session says so", SessionHelper.run(["kill", "--socket-dir", d, "--id", id]).code == 1)

        // What quitting with "Keep agents running" off does: stop several at once.
        let ids = [UUID(), UUID()]
        for u in ids {
            testSessions.append(u.uuidString)
            SessionHelper.run(["create", "--socket-dir", d, "--id", u.uuidString, "--cwd", dir.path, "--", "/bin/sh", "-c", "while :; do sleep 1; done"])
        }
        let started = ids.allSatisfy { SessionHelper.isAlive($0) }
        SessionHelper.killAll(ids)
        check("sessions: stopping all agents on quit stops each one", started && ids.allSatisfy { !SessionHelper.isAlive($0) })
    }

    static func sessionStaleSocket(_ dir: URL) {
        let id = newSessionID()
        let d = SessionHelper.socketDir
        let create = ["create", "--socket-dir", d, "--id", id, "--cwd", dir.path, "--", "/bin/sh", "-c", "while :; do sleep 1; done"]
        SessionHelper.run(create)
        guard let s = info(id) else { check("sessions: stale-socket test session started", false); return }
        // This test's own server, by the pid it reported: as if it had crashed.
        kill(s.pid, SIGKILL)
        _ = waitUntil(3) { !alive(s.pid) }
        let agentGone = waitUntil(3) { !alive(s.child) }
        if !agentGone { kill(s.child, SIGKILL) } // started by this test's session
        check("sessions: the agent goes with its server (pty hangup)", agentGone)
        let sock = d + "/" + id + ".sock"
        let stale = FileManager.default.fileExists(atPath: sock)
        check("sessions: a socket left by a crashed server is cleared and reused", stale && SessionHelper.run(create).code == 0 && info(id) != nil)
        SessionHelper.run(["kill", "--socket-dir", d, "--id", id])
    }

    static func sessionCleanup() {
        let d = SessionHelper.socketDir
        for id in testSessions { SessionHelper.run(["kill", "--socket-dir", d, "--id", id]) }
        let left = SessionHelper.list().filter { testSessions.contains($0.id) }
        check("sessions: no test sessions left running", left.isEmpty, "\(left.map(\.id))")
        testSessions.removeAll()
        if let items = try? FileManager.default.contentsOfDirectory(atPath: d) {
            for f in items where f.hasSuffix(".lock") { unlink(d + "/" + f) }
        }
        rmdir(d)
    }

    // MARK: Worktrees

    @discardableResult
    static func git(_ args: [String], _ dir: String) -> (code: Int32, out: String, err: String) {
        Worktrees.run(["-c", "user.email=selftest@hantuu.invalid", "-c", "user.name=hantuu selftest", "-c", "commit.gpgsign=false"] + args, in: dir)
    }

    static func worktrees(_ dir: URL) {
        // Git never looks above the workdir, so nothing here can touch hantuu's own checkout.
        Worktrees.ceilingDirectories = dir.path
        defer { Worktrees.ceilingDirectories = nil }
        let fm = FileManager.default
        let plain = dir.appendingPathComponent("plain folder").path
        try? fm.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let repo = dir.appendingPathComponent("wt repo 🫣").path
        try? fm.createDirectory(atPath: repo + "/sub/deeper", withIntermediateDirectories: true)
        func write(_ rel: String, _ text: String) {
            try? fm.createDirectory(atPath: ((repo + "/" + rel) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? text.write(toFile: repo + "/" + rel, atomically: true, encoding: .utf8)
        }
        git(["init", "-q", "-b", "main"], repo)
        write("README.md", "# scratch\n")
        write("sub/deeper/file.txt", "x\n")
        write(".gitignore", ".env\nbuild.log\nsecrets/\n")
        write(".worktreeinclude", ".env\nsecrets/\nnotes.txt\n")
        write(".env", "TOKEN=selftest\n")
        write("build.log", "ignored but not listed\n")
        write("secrets/key.txt", "k\n")
        write("notes.txt", "untracked and not ignored\n")
        git(["add", "README.md", ".gitignore", ".worktreeinclude", "sub"], repo)
        git(["commit", "-q", "-m", "init"], repo)

        check("worktree: git repos are recognised, plain folders aren't",
              Worktrees.repoRoot(of: repo) != nil && Worktrees.repoRoot(of: plain) == nil)
        let id = UUID(uuidString: "3F2A0000-0000-4000-8000-000000000001")!
        guard let wt = try? Worktrees.create(projectPath: repo, chatID: id) else {
            check("worktree: created", false, "create threw")
            return
        }
        let top = Worktrees.repoRoot(of: repo)!
        check("worktree: made at .hantuu/worktrees/<slug> on branch hantuu/<slug>",
              wt.root == top + "/.hantuu/worktrees/chat-3f2a" && wt.branch == "hantuu/chat-3f2a" && fm.fileExists(atPath: wt.root + "/README.md")
              && git(["show-ref", "--verify", "--quiet", "refs/heads/hantuu/chat-3f2a"], repo).code == 0, "\(wt)")
        let common = git(["rev-parse", "--git-common-dir"], repo).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let exclude = (try? String(contentsOfFile: (common.hasPrefix("/") ? common : repo + "/" + common) + "/info/exclude", encoding: .utf8)) ?? ""
        check("worktree: .hantuu/ goes in .git/info/exclude, not .gitignore",
              exclude.contains(".hantuu/") && !((try? String(contentsOfFile: repo + "/.gitignore", encoding: .utf8)) ?? "").contains("hantuu"))
        check("worktree: the main checkout's git status stays clean of it", !git(["status", "--porcelain"], repo).out.contains(".hantuu"))
        check("worktree: ignored files named in .worktreeinclude are copied",
              (try? String(contentsOfFile: wt.root + "/.env", encoding: .utf8)) == "TOKEN=selftest\n" && fm.fileExists(atPath: wt.root + "/secrets/key.txt"))
        check("worktree: other ignored files and untracked files aren't",
              !fm.fileExists(atPath: wt.root + "/build.log") && !fm.fileExists(atPath: wt.root + "/notes.txt"))

        let clash = UUID(uuidString: "3F2A1111-0000-4000-8000-000000000002")!
        let wt2 = try? Worktrees.create(projectPath: repo + "/sub", chatID: clash)
        check("worktree: names stay unique when the short id is taken", wt2?.slug == "chat-3f2a11", "\(String(describing: wt2?.slug))")
        check("worktree: a project inside the repo runs in the same folder of the worktree", wt2?.directory == (wt2?.root ?? "") + "/sub")

        try? "changed\n".write(toFile: wt.root + "/README.md", atomically: true, encoding: .utf8)
        check("worktree: uncommitted changes are noticed", Worktrees.isDirty(wt))
        check("worktree: deleting refuses when there are uncommitted changes", Worktrees.remove(wt, force: false) == .dirty && fm.fileExists(atPath: wt.root))
        git(["checkout", "--", "README.md"], wt.root)
        try? "new\n".write(toFile: wt.root + "/new.txt", atomically: true, encoding: .utf8)
        git(["add", "new.txt"], wt.root)
        git(["commit", "-q", "-m", "work on the chat branch"], wt.root)
        check("worktree: commits only on the chat's branch are counted", Worktrees.unmergedCommits(wt) == 1 && !Worktrees.isDirty(wt))
        check("worktree: without force, a branch with unmerged commits is kept",
              Worktrees.remove(wt, force: false) == .removedKeptBranch && !fm.fileExists(atPath: wt.root)
              && git(["show-ref", "--verify", "--quiet", "refs/heads/" + wt.branch], repo).code == 0)
        git(["branch", "-D", wt.branch], repo)
        if let wt2 {
            check("worktree: a clean worktree and its branch are deleted",
                  Worktrees.remove(wt2, force: false) == .removed && !fm.fileExists(atPath: wt2.root)
                  && git(["show-ref", "--verify", "--quiet", "refs/heads/" + wt2.branch], repo).code != 0)
        }
        check("worktree: workingDirectory(of:) is the worktree for a worktree chat", {
            let p = Project(path: repo)
            let c = Chat(projectID: p.id, agentID: "claude")
            AppModel.shared.projects.append(p)
            defer { AppModel.shared.projects.removeAll { $0.id == p.id } }
            let plain = AppModel.shared.workingDirectory(of: c) == repo
            c.worktree = wt
            return plain && AppModel.shared.workingDirectory(of: c) == wt.directory
        }())
    }

    // MARK: Snapshots

    static func snapshot(_ view: NSView, _ name: String, _ dir: URL) {
        let w = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: view.frame.width, height: view.frame.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = view
        w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent(name + ".png"))
        }
        w.orderOut(nil)
    }

    static func hosting<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil) -> NSView {
        let host = NSHostingView(rootView: AnyView(view.environmentObject(AppModel.shared).environment(\.colorScheme, .dark)))
        host.appearance = NSAppearance(named: .darkAqua)
        let h = height ?? host.fittingSize.height
        host.frame = NSRect(x: 0, y: 0, width: width, height: max(h, 10))
        return host
    }

    static func snapshots(_ workdir: URL) {
        let out = workdir.deletingLastPathComponent().appendingPathComponent("snapshots", isDirectory: true)
        Paths.ensure(out)
        let model = AppModel.shared
        let savedAgents = model.agents, savedProjects = model.projects
        defer { model.agents = savedAgents; model.projects = savedProjects }
        model.agents = [AgentDefinition(id: "claude", name: "Claude Code", transcript: .claude, path: "/usr/local/bin/claude"),
                        AgentDefinition(id: "codex", name: "Codex", transcript: .codex, path: "/usr/local/bin/codex")]
        model.defaultAgentID = "claude"
        let project = Project(path: workdir.appendingPathComponent("wt repo 🫣").path)
        model.projects = [project]
        let settings = SessionSettings.shared
        settings.setGitRoot(project.id, project.path)
        defer { settings.setGitRoot(project.id, nil); settings.setUsesWorktree(project.id, false) }

        // The new-chat popover, with the switch off and on, on a popover-like dark background.
        for on in [false, true] {
            settings.setUsesWorktree(project.id, on)
            let picker = AgentPicker(projectID: project.id) {}
                .background(Color(nsColor: NSColor(white: 0.17, alpha: 1)))
            snapshot(hosting(picker, width: 240), "agent-picker-worktree-\(on ? "on" : "off")", out)
        }

        let chat = Chat(projectID: project.id, agentID: "claude")
        chat.terminalTitle = "Fix the login redirect"
        chat.worktree = WorktreeInfo(repo: project.path, root: project.path + "/.hantuu/worktrees/chat-3f2a",
                                     directory: project.path + "/.hantuu/worktrees/chat-3f2a", branch: "hantuu/chat-3f2a")
        let header = ChatTitle(chat: chat).padding(.horizontal, 12).frame(height: 40, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading).background(Color.hBackground)
        snapshot(hosting(header, width: 640, height: 40), "chat-header-worktree", out)

        // How the branch reads in a sidebar row once ChatRow (bet 1's) shows WorktreeBranchLabel.
        let row = HStack(spacing: 9) {
            StatusDot(status: .running).frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.displayTitle).font(.system(size: 13)).foregroundStyle(Color.hText).lineLimit(1)
                HStack(spacing: 6) {
                    Text(chat.agent.name)
                    WorktreeBranchLabel(chat: chat)
                }
                .font(.system(size: 11)).foregroundStyle(Color.hTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.hSelection))
        .padding(8).background(Color.hChrome)
        snapshot(hosting(row, width: 260), "sidebar-row-branch-preview", out)

        snapshot(hosting(SettingsView(), width: 520, height: 420), "settings-sessions", out)

        let wt = chat.worktree!
        for (name, dirty, unmerged) in [("close-worktree-clean", false, 0), ("close-worktree-dirty", true, 2)] {
            let (alert, _) = WorktreePrompt.closeAlert(agentName: "Claude Code", worktree: wt, running: true, dirty: dirty, unmerged: unmerged)
            let aw = alert.window
            aw.appearance = NSAppearance(named: .darkAqua)
            alert.layout()
            aw.setFrameOrigin(NSPoint(x: -5000, y: -5000))
            aw.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            // The frame view, not the content view: on macOS 26 the alert's background and text
            // only render together from there.
            if let frame = aw.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                frame.cacheDisplay(in: frame.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
            }
            aw.orderOut(nil)
        }
        print("      snapshots in \(out.path)")
    }
}
