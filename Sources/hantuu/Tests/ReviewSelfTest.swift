import AppKit
import WebKit

/// Self test for the Overview, Changes and Files tabs: git parsing, the comment message,
/// context and plan extraction, port matching, file listing, a real fixture repository,
/// folder watching, the diff page and the whole panel. Writes PNG snapshots of each tab to
/// HANTUU_SNAPSHOT_DIR (or <workdir>/snapshots). With HANTUU_LIVE_REVIEW_TEST=<scratch git
/// repo> it also runs a real Claude Code chat there and checks Changes and comments end to end.
extension SelfTest {
    static func review(_ dir: URL) {
        reviewParsing()
        reviewMessage()
        reviewInsights()
        reviewPorts()
        reviewFileListing(dir)
        let repo = makeFixtureRepo(dir)
        reviewRepo(repo)
        reviewWatcher(dir)
        reviewPanel(dir, repo: makeFixtureRepo(dir.appendingPathComponent("panel"), forPanel: true))
        if let live = ProcessInfo.processInfo.environment["HANTUU_LIVE_REVIEW_TEST"], !live.isEmpty {
            reviewLiveAgent(makeLiveScratch(URL(fileURLWithPath: live)), dir: dir)
        }
    }

    // MARK: Parsing

    static func reviewParsing() {
        let status = GitParse.status(Data("M  src/a.swift\0 M src/b.swift\0R  new.txt\0old.txt\0?? notes/new file.md\0 D gone.txt\0UU conflict.txt\0A  added.txt\0".utf8))
        let byPath = Dictionary(uniqueKeysWithValues: status.map { ($0.path, $0) })
        check("git status: modified, staged and unstaged", byPath["src/a.swift"]?.status == "M" && byPath["src/b.swift"]?.status == "M")
        check("git status: rename keeps the old path", byPath["new.txt"]?.status == "R" && byPath["new.txt"]?.oldPath == "old.txt", "\(status)")
        check("git status: untracked with a space", byPath["notes/new file.md"]?.status == "?")
        check("git status: deleted, conflicted, added", byPath["gone.txt"]?.status == "D" && byPath["conflict.txt"]?.status == "U" && byPath["added.txt"]?.status == "A")
        check("git status: nothing extra", status.count == 7)

        let num = GitParse.numstat(Data("3\t1\tsrc/a.swift\0-\t-\timg.png\0\(0)\t\(0)\t\0old.txt\0new.txt\0".utf8))
        check("git numstat: counts", num.first == .init(path: "src/a.swift", oldPath: nil, added: 3, deleted: 1))
        check("git numstat: binary has no counts", num.count > 1 && num[1].added == nil && num[1].deleted == nil)
        check("git numstat: rename", num.count > 2 && num[2].path == "new.txt" && num[2].oldPath == "old.txt" && num[2].added == 0)

        let ns = GitParse.nameStatus(Data("M\0src/a.swift\0R087\0old.txt\0new.txt\0A\0added.txt\0D\0gone.txt\0".utf8))
        check("git name-status: letters and renames", ns.map { String($0.status) } == ["M", "R", "A", "D"] && ns[1].oldPath == "old.txt" && ns[1].path == "new.txt", "\(ns)")

        let diff = """
        diff --git a/src/a.swift b/src/a.swift
        index 1111111..2222222 100644
        --- a/src/a.swift
        +++ b/src/a.swift
        @@ -1,4 +1,5 @@ struct A {
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
         let d = 5
         let e = 6
        @@ -10,2 +11,2 @@
        -old
        +new
        \\ No newline at end of file

        """
        let p = DiffParser.parse(diff)
        let kinds = p.rows.map(\.t.rawValue).joined()
        check("diff: rows in order", kinds == "hcdaacchdan", kinds)
        check("diff: line numbers on both sides", p.rows[1].o == 1 && p.rows[1].n == 1 && p.rows[2].o == 2 && p.rows[3].n == 2 && p.rows[5].o == 3 && p.rows[5].n == 4)
        check("diff: second hunk numbering", p.rows[8].o == 10 && p.rows[9].n == 11)
        check("diff: counts and text", p.added == 3 && p.deleted == 2 && p.rows[3].s == "let b = 3")
        check("diff: binary detected", DiffParser.parse("diff --git a/x.png b/x.png\nBinary files a/x.png and b/x.png differ\n").binary)

        let pr = PullRequestInfo.parse(Data(#"{"number":42,"title":"Tidy the parser","state":"OPEN","isDraft":false,"url":"https://github.com/o/r/pull/42","reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://x/1"},{"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":""},{"__typename":"StatusContext","context":"lint","state":"FAILURE","targetUrl":"https://x/2"},{"__typename":"CheckRun","name":"docs","status":"COMPLETED","conclusion":"SKIPPED"}]}"#.utf8))
        check("pr: gh json parsed", pr?.number == 42 && pr?.stateLabel == "Open" && pr?.reviewLabel == "Changes requested")
        check("pr: check states", pr?.checks.map { "\($0.name)=\($0.state)" } == ["build=success", "test=pending", "lint=failure", "docs=skipped"], "\(pr?.checks ?? [])")
        check("pr: missing PR is nil", PullRequestInfo.parse(Data("no pull requests found".utf8)) == nil)
    }

    static func reviewMessage() {
        let c1 = ReviewComment(root: "/r", path: "src/a.swift", side: "new", start: 2, end: 3, quoted: ["let b = 3", "let c = 4"], body: "Use named constants\u{1b}[201~ here.")
        let c2 = ReviewComment(root: "/r", path: "README.md", side: "old", start: 7, end: 7, quoted: ["old intro  "], body: "Keep this sentence.")
        let msg = CommentMessage.build([c1, c2], folder: "/r")
        check("comments: one message, numbered, sorted by file", msg.hasPrefix("Please address these 2 review comments") && msg.contains("1. README.md:7") && msg.contains("2. src/a.swift:2-3"), msg)
        check("comments: file:line, quoted lines and the comment", msg.contains("src/a.swift:2-3\n> let b = 3\n> let c = 4\nUse named constants[201~ here."), msg)
        check("comments: removed lines are labelled", msg.contains("README.md:7 (removed line)\n> old intro\nKeep this sentence."))
        check("comments: control characters stripped, so a paste can't be ended early", !msg.unicodeScalars.contains { $0.value == 0x1B })
        let sub = CommentMessage.build([c1, c2], folder: "/r/src")
        check("comments: paths relative to the agent's folder", sub.contains("2. a.swift:2-3") && sub.contains("1. /r/README.md:7"), sub)
        let long = ReviewComment(root: "/r", path: "x.txt", side: "new", start: 1, end: 9, quoted: (1...9).map { "line \($0)" }, body: "Too long")
        let lm = CommentMessage.build([long], folder: "/r")
        check("comments: long quotes are cut", lm.contains("> line 6\n> …\nToo long") && !lm.contains("line 7") && lm.hasPrefix("Please address this review comment"), lm)
    }

    // MARK: Context and plan

    static func reviewInsights() {
        var claude = InsightsParser(kind: .claude)
        let claudeLines = [
            #"{"type":"assistant","uuid":"a1","message":{"model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":2000,"cache_read_input_tokens":48000,"output_tokens":300}}}"#,
            #"{"type":"assistant","uuid":"s1","isSidechain":true,"message":{"model":"claude-haiku","usage":{"input_tokens":190000}}}"#,
            #"{"type":"assistant","uuid":"a2","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tw","name":"TodoWrite","input":{"todos":[{"content":"Read the parser","status":"completed","activeForm":"Reading"},{"content":"Fix the off-by-one","status":"in_progress","activeForm":"Fixing"},{"content":"Add a test","status":"pending","activeForm":"Adding"}]}}]}}"#,
            #"{"type":"assistant","uuid":"a3","message":{"model":"<synthetic>","content":[]}}"#,
        ]
        for l in claudeLines { claude.consume(Data(l.utf8)) }
        let ci = claude.insights
        check("context: Claude usage is input plus cache tokens", ci.contextUsed == 50010 && ci.contextWindow == 200_000 && ci.windowIsGuess, "\(ci)")
        check("context: Claude model from the transcript, sidechains ignored", ci.model == "claude-opus-5-5")
        check("context: Claude percentage", Int((ci.contextFraction ?? 0) * 100) == 25)
        check("plan: TodoWrite items with states", ci.plan.map(\.text) == ["Read the parser", "Fix the off-by-one", "Add a test"] && ci.plan.map(\.state) == [.completed, .inProgress, .pending])
        check("context: past 200k means a 1M window", InsightsParser.claudeWindow(model: "claude-opus-5-5", used: 450_000) == (1_000_000, true))

        var tasks = InsightsParser(kind: .claude)
        for l in [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tc1","name":"TaskCreate","input":{"subject":"Write docs","description":"d"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tc1","content":"Task #1 created successfully: Write docs"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tc2","name":"TaskCreate","input":{"subject":"Ship it","description":"d"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tc2","content":[{"type":"text","text":"Task #2 created successfully: Ship it"}]}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu1","name":"TaskUpdate","input":{"taskId":"1","status":"completed"}}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu2","name":"TaskUpdate","input":{"taskId":"2","status":"in_progress"}}]}}"#,
        ] { tasks.consume(Data(l.utf8)) }
        check("plan: Claude task list (TaskCreate, TaskUpdate)", tasks.insights.plan.map { "\($0.text)=\($0.state.rawValue)" } == ["Write docs=completed", "Ship it=inProgress"], "\(tasks.insights.plan)")

        var codex = InsightsParser(kind: .codex)
        for l in [
            #"{"timestamp":"t","type":"turn_context","payload":{"cwd":"/x","model":"gpt-6-astra","effort":"high"}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":99999},"last_token_usage":{"input_tokens":64000,"cached_input_tokens":13312,"output_tokens":600,"total_tokens":64600},"model_context_window":258400}}}"#,
            #"{"timestamp":"t","type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"explanation\":\"x\",\"plan\":[{\"step\":\"Scan the repo\",\"status\":\"completed\"},{\"step\":\"Patch the bug\",\"status\":\"in_progress\"},{\"step\":\"Run tests\",\"status\":\"pending\"}]}","call_id":"c1"}}"#,
        ] { codex.consume(Data(l.utf8)) }
        let xi = codex.insights
        check("context: Codex token_count with its window size", xi.contextUsed == 64600 && xi.contextWindow == 258400 && !xi.windowIsGuess, "\(xi)")
        check("context: Codex model and percentage", xi.model == "gpt-6-astra" && Int((xi.contextFraction ?? 0) * 100) == 25)
        check("plan: Codex update_plan", xi.plan.map(\.text) == ["Scan the repo", "Patch the bug", "Run tests"] && xi.plan[1].state == .inProgress)
    }

    // MARK: Ports

    static func reviewPorts() {
        let lsof = "p100\ncnode\nf12\nn*:3000\nf13\nn[::1]:3000\np200\ncpython3\nf3\nn127.0.0.1:8000\np300\ncruby\nf4\nn*:4000\np400\ncvite\nf5\nn[::1]:5173\n"
        let ls = Ports.parseLsof(lsof)
        check("ports: lsof output parsed, IPv4 and IPv6 merged", ls.count == 4 && ls.first == .init(pid: 100, command: "node", port: 3000), "\(ls)")
        let cwds: [Int32: String] = [100: "/w/proj/web", 200: "/w/proj2", 300: "/w/proj", 400: "/elsewhere"]
        let m = Ports.match(ls, folder: "/w/proj", cwd: { cwds[$0] })
        check("ports: only processes working inside the chat's folder", m.map(\.port) == [3000, 4000], "\(m)")
        check("ports: a sibling folder with the same prefix isn't inside", !Ports.isInside("/w/proj2", folder: "/w/proj") && Ports.isInside("/w/proj", folder: "/w/proj/"))
        check("ports: cwd of this process from the kernel", Ports.cwd(of: getpid()) == FileManager.default.currentDirectoryPath)
    }

    // MARK: Files

    static func reviewFileListing(_ dir: URL) {
        let fm = FileManager.default
        let plain = dir.appendingPathComponent("plain folder")
        for p in ["a.txt", "sub/b.txt", "node_modules/x/index.js", ".build/debug/y", ".git/HEAD", ".DS_Store", "sub/deeper/c.swift"] {
            let u = plain.appendingPathComponent(p)
            Paths.ensure(u.deletingLastPathComponent())
            fm.createFile(atPath: u.path, contents: Data("x\n".utf8))
        }
        let (paths, truncated) = FileTree.listFiles(folder: plain.path, inRepo: false)
        check("files: outside git, a filtered listing", Set(paths) == ["a.txt", "sub/b.txt", "sub/deeper/c.swift"] && !truncated, "\(paths)")
        let tree = FileTree.build(root: plain.path, paths: paths, truncated: false, fromGit: false)
        check("files: folders first, then files", tree.rows(expanded: []).map(\.node.name) == ["sub", "a.txt"])
        check("files: expanding shows children with depth", tree.rows(expanded: ["sub"]).map { "\($0.depth):\($0.node.name)" } == ["0:sub", "1:deeper", "1:b.txt", "0:a.txt"])
        check("files: filter matches paths, names first", tree.matches("b txt").map(\.path) == ["sub/b.txt"] && tree.matches("sub").map(\.path) == ["sub/b.txt", "sub/deeper/c.swift"])
    }

    // MARK: A real repository

    static let fixtureEnv = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]

    @discardableResult
    static func fixtureGit(_ args: [String], _ repo: URL) -> Git.Result {
        Git.run(["-c", "user.name=hantuu", "-c", "user.email=selftest@hantuu.invalid", "-c", "commit.gpgsign=false",
                 "-c", "core.hooksPath=/dev/null", "-c", "init.defaultBranch=main"] + args, in: repo.path, extraEnv: fixtureEnv)
    }

    static func write(_ repo: URL, _ path: String, _ text: String) {
        let u = repo.appendingPathComponent(path)
        Paths.ensure(u.deletingLastPathComponent())
        FileManager.default.createFile(atPath: u.path, contents: Data(text.utf8))
    }

    static let parserV1 = """
    import Foundation

    /// Splits source text into tokens.
    struct Parser {
        let source: String

        func tokens() -> [String] {
            var out: [String] = []
            var current = ""
            for ch in source {
                if ch == " " {
                    out.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            return out
        }

        func count() -> Int {
            tokens().count
        }
    }

    """

    static let parserV2 = """
    import Foundation

    /// Splits source text into tokens, skipping empty runs of whitespace.
    struct Parser {
        let source: String

        func tokens() -> [String] {
            var out: [String] = []
            var current = ""
            for ch in source {
                if ch.isWhitespace {
                    if !current.isEmpty { out.append(current) }
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            if !current.isEmpty { out.append(current) }
            return out
        }

        func count() -> Int {
            tokens().count
        }
    }

    """

    /// A repo on branch "feature" off "main", with one commit on the branch and uncommitted
    /// edits: a modified file, a deletion, a staged rename and an untracked file.
    static func makeFixtureRepo(_ base: URL, forPanel: Bool = false) -> URL {
        let repo = base.appendingPathComponent("tidy-parser")
        try? FileManager.default.removeItem(at: repo)
        Paths.ensure(repo)
        fixtureGit(["init", "-q"], repo)
        write(repo, ".gitignore", "build/\n*.log\n")
        write(repo, "Sources/Parser.swift", parserV1)
        write(repo, "README.md", "# Tidy parser\n\nA small tokenizer.\n")
        write(repo, "docs/old-notes.txt", "Notes from the first version.\n")
        write(repo, "gone.txt", "This file goes away.\n")
        fixtureGit(["add", "-A"], repo)
        fixtureGit(["commit", "-q", "-m", "First version"], repo)
        fixtureGit(["checkout", "-q", "-b", "feature"], repo)
        write(repo, "README.md", "# Tidy parser\n\nA small tokenizer that skips extra whitespace.\n")
        fixtureGit(["commit", "-q", "-am", "Describe whitespace handling"], repo)
        write(repo, "Sources/Parser.swift", parserV2)
        try? FileManager.default.removeItem(at: repo.appendingPathComponent("gone.txt"))
        fixtureGit(["mv", "docs/old-notes.txt", "docs/notes.txt"], repo)
        write(repo, "Sources/Tokenizer.swift", "/// Token kinds.\nenum TokenKind {\n    case word\n    case number\n}\n")
        write(repo, "build/out.o", "ignored\n")
        write(repo, "debug.log", "ignored\n")
        if forPanel {
            write(repo, "Tests/ParserTests.swift", "import XCTest\n\nfinal class ParserTests: XCTestCase {\n    func testSkipsSpaces() {\n        XCTAssertEqual(Parser(source: \"a  b\").tokens(), [\"a\", \"b\"])\n    }\n}\n")
        }
        return repo
    }

    static func reviewRepo(_ repo: URL) {
        guard let info = RepoInfo.load(folder: repo.appendingPathComponent("Sources").path) else {
            check("repo: fixture repository found from a subfolder", false)
            return
        }
        let root = URL(fileURLWithPath: info.root).resolvingSymlinksInPath().path
        check("repo: root, branch and default branch", root == repo.resolvingSymlinksInPath().path && info.branch == "feature" && info.defaultBranch == "main" && info.mergeBase != nil && !info.isLinkedWorktree, "\(info)")
        let indexURL = repo.appendingPathComponent(".git/index")
        // A touched but unchanged tracked file has stale stat info: exactly what makes a plain
        // `git diff` rewrite the index to refresh it.
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: repo.appendingPathComponent("README.md").path)
        let indexBefore = (try? FileManager.default.attributesOfItem(atPath: indexURL.path))?[.modificationDate] as? Date
        let indexData = try? Data(contentsOf: indexURL)
        let unc = ChangeScanner.uncommitted(info)
        let by = Dictionary(uniqueKeysWithValues: unc.map { ($0.path, $0) })
        check("repo: uncommitted modified file with counts", by["Sources/Parser.swift"]?.status == "M" && by["Sources/Parser.swift"]?.added == 4 && by["Sources/Parser.swift"]?.deleted == 3, "\(unc.map { "\($0.status) \($0.path) +\($0.added ?? -1) -\($0.deleted ?? -1)" })")
        check("repo: deletion, staged rename and untracked file", by["gone.txt"]?.status == "D" && by["docs/notes.txt"]?.status == "R" && by["docs/notes.txt"]?.oldPath == "docs/old-notes.txt" && by["Sources/Tokenizer.swift"]?.status == "?" && by["Sources/Tokenizer.swift"]?.added == 5)
        check("repo: committed and ignored files aren't uncommitted", by["README.md"] == nil && by["debug.log"] == nil && by["build/out.o"] == nil)
        let branch = ChangeScanner.branch(info, base: info.mergeBase ?? "HEAD")
        check("repo: branch view adds what was committed on the branch", branch.contains { $0.path == "README.md" && $0.status == "M" } && branch.contains { $0.path == "Sources/Parser.swift" } && branch.contains { $0.path == "Sources/Tokenizer.swift" })
        let diff = DiffParser.parse(ChangeScanner.diff(by["Sources/Parser.swift"]!, base: info.headRef, root: info.root))
        check("repo: diff of a modified file", diff.rows.contains { $0.t == .add && $0.s.contains("ch.isWhitespace") } && diff.rows.contains { $0.t == .del && $0.s.contains("ch == \" \"") })
        let untracked = DiffParser.parse(ChangeScanner.diff(by["Sources/Tokenizer.swift"]!, base: info.headRef, root: info.root))
        check("repo: diff of an untracked file", untracked.rows.filter { $0.t == .add }.count == 5 && untracked.rows.first?.t == .hunk)
        let renamed = DiffParser.parse(ChangeScanner.diff(by["docs/notes.txt"]!, base: info.headRef, root: info.root))
        check("repo: pure rename has no line changes", renamed.rows.isEmpty && !renamed.binary)
        let (files, _) = FileTree.listFiles(folder: info.root, inRepo: true)
        check("files: in git, tracked plus untracked, ignored left out", files.contains("Sources/Tokenizer.swift") && files.contains("Sources/Parser.swift") && !files.contains("debug.log") && !files.contains("build/out.o"), "\(files)")
        let (sub, _) = FileTree.listFiles(folder: repo.appendingPathComponent("Sources").path, inRepo: true)
        check("files: listing is relative to the chat's folder", Set(sub) == ["Parser.swift", "Tokenizer.swift"], "\(sub)")
        let indexAfter = (try? FileManager.default.attributesOfItem(atPath: indexURL.path))?[.modificationDate] as? Date
        check("repo: reading changes never touches the index", indexBefore == indexAfter && indexData == (try? Data(contentsOf: indexURL)))
        // Control, for the record: the same read without the private copy.
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: repo.appendingPathComponent("README.md").path)
        let controlBefore = try? Data(contentsOf: indexURL)
        Git.run(["diff", "--numstat", "HEAD", "--"], in: info.root)
        print("      control: a plain `git diff` with GIT_OPTIONAL_LOCKS=0 \(controlBefore == (try? Data(contentsOf: indexURL)) ? "left the index alone" : "rewrote the index")")

        let err = ChangeScanner.revert(by["Sources/Parser.swift"]!, repo: info)
        let restored = (try? String(contentsOf: repo.appendingPathComponent("Sources/Parser.swift"), encoding: .utf8)) ?? ""
        check("repo: revert restores a tracked file from HEAD", err == nil && restored == parserV1 && !ChangeScanner.uncommitted(info).contains { $0.path == "Sources/Parser.swift" }, err ?? "")
    }

    static func reviewWatcher(_ dir: URL) {
        let folder = dir.appendingPathComponent("watched")
        Paths.ensure(folder.appendingPathComponent(".git/objects"))
        var fired = 0
        let w = FolderWatcher(path: folder.path, quiet: 0.2) { fired += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        w.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        fired = 0
        FileManager.default.createFile(atPath: folder.appendingPathComponent(".git/objects/ab").path, contents: Data("x".utf8))
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        check("watch: git object churn is ignored", fired == 0, "fired \(fired)")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("edited.swift").path, contents: Data("x".utf8))
        check("watch: an edit in the folder triggers a refresh", waitUntil(4) { fired > 0 })
        w.stop()

        // Changes reads git through a copy of the index. Making the copy mustn't look like a
        // change, or every refresh would start the next one.
        let repo = dir.appendingPathComponent("watched-repo")
        Paths.ensure(repo)
        fixtureGit(["init", "-q"], repo)
        write(repo, "a.txt", "a\n")
        fixtureGit(["add", "-A"], repo)
        fixtureGit(["commit", "-q", "-m", "Add a."], repo)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        var copies = 0
        let indexWatcher = FolderWatcher(path: repo.path, quiet: 0.2) { copies += 1 }
        indexWatcher.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        copies = 0
        let env = Git.readOnlyIndex(root: repo.path)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        check("watch: copying the index to read git isn't a change", copies == 0 && env["GIT_INDEX_FILE"] != nil, "fired \(copies)")
        indexWatcher.stop()
    }

    // MARK: The panel, end to end with fixtures

    static func snapshotDir(_ dir: URL) -> URL {
        if let s = ProcessInfo.processInfo.environment["HANTUU_SNAPSHOT_DIR"], !s.isEmpty { return URL(fileURLWithPath: s) }
        return dir.appendingPathComponent("snapshots")
    }

    static func claudeFixtureTranscript(_ url: URL) {
        func line(_ o: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) }
        var lines: [String] = []
        lines.append(line(["type": "user", "uuid": "u1", "message": ["role": "user", "content": "Make the parser skip runs of whitespace."]]))
        lines.append(line(["type": "assistant", "uuid": "a1", "message": ["model": "claude-opus-5-5", "role": "assistant",
            "content": [["type": "tool_use", "id": "tw1", "name": "TodoWrite", "input": ["todos": [
                ["content": "Read Parser.swift", "status": "completed", "activeForm": "Reading"],
                ["content": "Skip empty tokens between spaces", "status": "completed", "activeForm": "Skipping"],
                ["content": "Add a test for double spaces", "status": "in_progress", "activeForm": "Adding a test"],
                ["content": "Update the README", "status": "pending", "activeForm": "Updating"],
            ]]]],
            "usage": ["input_tokens": 6, "cache_creation_input_tokens": 3120, "cache_read_input_tokens": 71890, "output_tokens": 410]]]))
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func render(_ view: NSView, to url: URL) -> Bool {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        guard let cached = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        view.cacheDisplay(in: bounds, to: cached)
        var shots: [(NSRect, NSImage)] = []
        func webViews(_ v: NSView) -> [WKWebView] { (v as? WKWebView).map { [$0] } ?? v.subviews.flatMap(webViews) }
        for w in webViews(view) where !w.isHiddenOrHasHiddenAncestor && w.bounds.width > 0 && w.bounds.height > 0 {
            var image: NSImage?
            var done = false
            w.takeSnapshot(with: nil) { img, _ in image = img; done = true }
            _ = waitUntil(5) { done }
            if let image { shots.append((w.convert(w.bounds, to: view), image)) }
        }
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cached.pixelsWide, pixelsHigh: cached.pixelsHigh, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        out.size = bounds.size
        guard let ctx = NSGraphicsContext(bitmapImageRep: out) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        Theme.chrome.setFill()
        bounds.fill()
        cached.draw(in: bounds)
        for (r, img) in shots { img.draw(in: r) }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = out.representation(using: .png, properties: [:]) else { return false }
        Paths.ensure(url.deletingLastPathComponent())
        return (try? png.write(to: url)) != nil
    }

    static func reviewPanel(_ dir: URL, repo: URL) {
        guard let g = GhosttyApp.shared ?? GhosttyApp.start() else {
            check("panel: libghostty available", false)
            return
        }
        let shots = snapshotDir(dir)
        let model = AppModel()
        let project = model.addProject(path: repo.path)
        let chat = Chat(projectID: project.id, agentID: "claude", createdAt: Date().addingTimeInterval(-4300))
        let transcript = dir.appendingPathComponent("panel-transcript.jsonl")
        claudeFixtureTranscript(transcript)
        chat.transcriptPath = transcript.path
        chat.terminalTitle = "Skip runs of whitespace"
        // The chat's "agent" captures exactly what Send to Agent types: raw mode, bracketed
        // paste on, every byte to a file.
        let sent = dir.appendingPathComponent("sent.bin")
        let script = "stty -icanon -icrnl -echo min 1 time 0; printf '\\033[?2004h'; exec cat -u > \(ShellEscape.quote(sent.path))"
        let tv = TerminalView(app: g.app, launch: .init(workingDirectory: repo.path, command: "/bin/sh -c \(ShellEscape.quote(script))"), handlesChildExit: true)
        chat.terminal = tv
        chat.startedAt = Date().addingTimeInterval(-4260)
        model.chats = [chat]
        model.selectedChatID = chat.id
        model.panelVisible = true
        model.panelTab = .overview

        let center = ReviewCenter()
        center.fixtureMode = true
        let panel = PanelController(model: model, review: center)
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 560, height: 860), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 860))
        panel.view.frame = w.contentView!.bounds
        panel.view.autoresizingMask = [.width, .height]
        w.contentView!.addSubview(panel.view)
        let term = NSWindow(contentRect: NSRect(x: -4000, y: -3000, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        term.isReleasedWhenClosed = false
        tv.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        term.contentView?.addSubview(tv)
        term.orderFrontRegardless()
        w.orderFrontRegardless()
        defer {
            tv.destroy()
            w.orderOut(nil)
            term.orderOut(nil)
        }

        check("panel: Overview follows the selected chat", waitUntil(5) { center.chatID == chat.id && center.folder == repo.path })
        center.setFixture(pr: PullRequestInfo.parse(Data(#"{"number":42,"title":"Skip runs of whitespace in the parser","state":"OPEN","isDraft":false,"url":"https://github.com/example/tidy-parser/pull/42","reviewDecision":"REVIEW_REQUIRED","statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":""},{"__typename":"StatusContext","context":"lint","state":"FAILURE"}]}"#.utf8)),
                          ports: [ListeningPort(port: 5173, pid: 1, command: "vite"), ListeningPort(port: 8080, pid: 2, command: "python3")])
        let loaded = waitUntil(10) { center.changesLoaded && center.insights?.contextUsed != nil && center.branchSummary != nil }
        check("panel: Overview loads changes against the branch base, context and plan", loaded && center.branchSummary?.files == 6 && center.insights?.plan.count == 4,
              "summary=\(String(describing: center.branchSummary)) insights=\(String(describing: center.insights))")
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        check("snapshot: Overview", render(panel.view, to: shots.appendingPathComponent("overview.png")))

        model.panelTab = .changes
        _ = waitUntil(5) { center.changesLoaded && !center.changes.isEmpty }
        center.selectedPath = "Sources/Parser.swift"
        let page = center.diffPage.page
        // Wait for this file's rows, not just any rows: the page can still be showing the file
        // that was selected before.
        let rendered = waitUntil(8) { page.ready && (js(page, "Array.from(document.querySelectorAll('tr.add')).some(t => t.textContent.includes('isWhitespace')) ? 1 : 0") as? Int ?? 0) == 1 }
        check("panel: Changes lists files and renders the first diff", rendered && center.changes.count == 5 && center.selectedPath == "Sources/Parser.swift",
              "\(center.changes.map(\.path)) selected=\(center.selectedPath ?? "nil")")
        let hl = js(page, "document.querySelectorAll('table.diff .hljs-keyword').length") as? Int ?? 0
        check("panel: diff is highlighted with line numbers", hl > 0 && (js(page, "document.querySelector('tr.add td.ln.n').textContent") as? String ?? "") != "")

        // Comment on an added line through the page, the way a click would.
        _ = js(page, "(() => { const r = Array.from(document.querySelectorAll('tr.add')).find(t => t.textContent.includes('isWhitespace')); r.querySelector('td.ln.n').click(); return 1; })()")
        let boxOpen = (js(page, "document.querySelectorAll('tr.cbox textarea').length") as? Int ?? 0) == 1
        _ = js(page, "(() => { const t = document.querySelector('tr.cbox textarea'); t.value = 'Use a CharacterSet here so tabs and newlines count too.'; t.dispatchEvent(new Event('input')); document.querySelector('tr.cbox .add').click(); return 1; })()")
        let added = waitUntil(3) { center.currentComments.count == 1 }
        let c = center.currentComments.first
        check("comments: clicking a line number opens a box, Add stores the comment", boxOpen && added && c?.path == "Sources/Parser.swift" && c?.side == "new" && c?.quoted.first?.contains("isWhitespace") == true, "\(String(describing: c))")
        check("comments: the saved comment is drawn under its line", waitUntil(3) { (js(page, "document.querySelectorAll('tr.note').length") as? Int ?? 0) == 1 })
        // Shift-click a range of two context lines and leave the box open for the snapshot.
        _ = js(page, "(() => { const rows = Array.from(document.querySelectorAll('tr.ctx')); rows[rows.length-3].querySelector('td.ln.n').click(); rows[rows.length-2].querySelector('td.ln.n').dispatchEvent(new MouseEvent('click', {bubbles: true, shiftKey: true})); document.querySelector('tr.cbox textarea').value = 'Could count() avoid building the array?'; return 1; })()")
        let range = js(page, "document.querySelector('tr.cbox .cbox-head').textContent") as? String ?? ""
        check("comments: Shift-click selects a range", range.hasPrefix("Comment on lines "), range)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        check("snapshot: Changes with a comment", render(panel.view, to: shots.appendingPathComponent("changes.png")))
        _ = js(page, "document.querySelector('tr.cbox .cancel').click(); 1")

        // Viewed marks and the base switch.
        if let f = center.selectedFile {
            center.toggleViewed(f)
            check("changes: mark a file as viewed", center.isViewed(f))
        }
        center.base = .branch
        check("changes: Branch base includes the branch's commits", waitUntil(6) { center.changesLoaded && center.changes.contains { $0.path == "README.md" } })
        center.base = .uncommitted
        _ = waitUntil(6) { center.changesLoaded && !center.changes.contains { $0.path == "README.md" } }

        // Live refresh: an edit on disk shows up without touching the panel.
        write(repo, "Sources/Lexer.swift", "struct Lexer {}\n")
        check("changes: live refresh picks up a new file", waitUntil(6) { center.changes.contains { $0.path == "Sources/Lexer.swift" } })

        // A large diff waits behind a button instead of stalling the page.
        write(repo, "data/big.txt", (1...6000).map { "row \($0)" }.joined(separator: "\n") + "\n")
        _ = waitUntil(6) { center.changes.contains { $0.path == "data/big.txt" } }
        center.selectedPath = "data/big.txt"
        let gated = waitUntil(6) { (js(page, "document.querySelectorAll('.large button').length") as? Int ?? 0) == 1 }
        _ = js(page, "document.querySelector('.large button').click(); 1")
        let shown = waitUntil(10) { (js(page, "document.querySelectorAll('tr[data-i]').length") as? Int ?? 0) == 6000 }
        check("changes: a large diff shows a Show Diff button, then renders on request", gated && shown)
        try? FileManager.default.removeItem(at: repo.appendingPathComponent("data"))
        _ = waitUntil(6) { !center.changes.contains { $0.path == "data/big.txt" } }
        center.selectedPath = "Sources/Parser.swift"

        // Send to Agent: one bracketed paste, then a real Return key.
        check("comments: Send is available for a running chat", center.canSend)
        center.sendComments()
        let typed = waitUntil(5) { ((try? Data(contentsOf: sent)) ?? Data()).count > 60 && ((try? Data(contentsOf: sent)) ?? Data()).last == 0x0D }
        let bytes = String(decoding: (try? Data(contentsOf: sent)) ?? Data(), as: UTF8.self)
        check("comments: sent as one bracketed paste followed by Return", typed && bytes.hasPrefix("\u{1b}[200~Please address this review comment") && bytes.hasSuffix("\u{1b}[201~\r")
              && bytes.contains("Parser.swift:") && bytes.contains("> ") && bytes.contains("Use a CharacterSet here"), bytes.debugDescription)
        check("comments: cleared once sent", center.currentComments.isEmpty)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        model.panelTab = .files
        center.expanded = ["Sources", "Tests"]
        let tree = waitUntil(6) { center.tree != nil }
        check("panel: Files shows the tree with changed files marked", tree && center.tree?.fileCount == 7 && center.changedInFolder["Sources/Parser.swift"] == "M", "count=\(center.tree?.fileCount ?? -1) changed=\(center.changedInFolder)")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        check("snapshot: Files", render(panel.view, to: shots.appendingPathComponent("files.png")))
        center.filter = "parser"
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        check("snapshot: Files filtered", render(panel.view, to: shots.appendingPathComponent("files-filter.png")))
        center.filter = ""

        // Five tab labels at the default width and at the narrowest panel.
        w.setContentSize(NSSize(width: 360, height: 860))
        model.panelTab = .overview
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        check("snapshot: narrow panel", render(panel.view, to: shots.appendingPathComponent("overview-narrow.png")))
        model.panelVisible = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check("panel: hiding the panel stops review work", center.activeTab == nil)
        print("      snapshots in \(shots.path)")
    }

    // MARK: A real agent

    /// A fresh scratch repo for the live test with one committed file.
    static func makeLiveScratch(_ repo: URL) -> URL {
        try? FileManager.default.removeItem(at: repo)
        Paths.ensure(repo)
        fixtureGit(["init", "-q"], repo)
        write(repo, "notes.txt", "The sky is blue.\nThe grass is tall.\n")
        fixtureGit(["add", "-A"], repo)
        fixtureGit(["commit", "-q", "-m", "Scratch"], repo)
        return repo
    }


    /// Test-only additions to the agent's command line. For Claude Code, one allow rule for
    /// file edits, which Claude limits to its working folder (the scratch repo), so nobody has
    /// to answer a permission prompt and no settings file is written. For Codex, low reasoning
    /// effort to keep the run short; its own sandbox already lets it edit inside the workspace.
    /// The app itself never passes either.
    static func liveExtraArguments(_ agent: String) -> [String] {
        switch agent {
        case "claude": return ["--settings", #"{"permissions":{"allow":["Edit"]}}"#]
        // No update check: an update offer is a menu, and Return would accept it.
        case "codex": return ["-c", #"model_reasoning_effort="low""#, "-c", "check_for_update_on_startup=false"]
        default: return []
        }
    }

    /// Runs a real agent chat in the scratch repo: it edits a file, Changes picks the edit up
    /// live, a line comment is sent through the terminal, and the agent acts on it. Stops,
    /// without answering, if the agent asks whether to trust the folder.
    static func reviewLiveAgent(_ repo: URL, dir: URL) {
        guard let g = GhosttyApp.shared else { return }
        let agent = ProcessInfo.processInfo.environment["HANTUU_LIVE_REVIEW_AGENT"] ?? "codex"
        print("      live agent test with \(agent) in \(repo.path)")
        let model = AppModel()
        let project = model.addProject(path: repo.path)
        let chat = Chat(projectID: project.id, agentID: agent)
        if agent == "claude" { chat.sessionID = UUID().uuidString.lowercased() }
        let argv = chat.agent.launchArguments(sessionID: chat.sessionID) + liveExtraArguments(agent)
        let tv = TerminalView(app: g.app, launch: .init(workingDirectory: repo.path, command: LoginShell.surfaceCommand(argv),
                                                         environment: ["HANTUU_CHAT_ID": chat.id.uuidString]), handlesChildExit: true)
        chat.terminal = tv
        chat.startedAt = Date()
        model.chats = [chat]
        model.selectedChatID = chat.id
        let discovery = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            guard chat.transcriptPath == nil else { return }
            if agent == "claude", let sid = chat.sessionID, let u = ClaudeTranscriptParser.locate(sessionID: sid, cwd: repo.path) {
                chat.transcriptPath = u.path
            } else if agent == "codex", let (u, _) = CodexTranscriptParser.locate(cwd: repo.path, after: chat.startedAt, excluding: []) {
                chat.transcriptPath = u.path
            }
        }
        defer { discovery.invalidate() }
        let center = ReviewCenter()
        let panel = PanelController(model: model, review: center)
        let w = NSWindow(contentRect: NSRect(x: -5000, y: -4000, width: 1400, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        tv.frame = NSRect(x: 0, y: 0, width: 840, height: 900)
        panel.view.frame = NSRect(x: 840, y: 0, width: 560, height: 900)
        w.contentView!.addSubview(tv)
        w.contentView!.addSubview(panel.view)
        w.orderFrontRegardless()
        model.panelVisible = true
        model.panelTab = .changes
        defer {
            tv.destroy()
            w.orderOut(nil)
        }
        // The test only ever types at an idle composer. Any menu or question on screen (trust,
        // update, approval, enter-to-confirm) stops it, unanswered, because a Return would
        // pick that menu's default.
        let readyMarks = ["for shortcuts", "context left"]
        let blockers = ["trust", "Update available", "Update now", "Skip until", "Press enter", "Enter to confirm", "(y/n)",
                        "Would you like", "Yes, proceed", "Allow command", "Approve", "Do you want"]
        func blocker() -> String? { let s = tv.screenText(); return blockers.first { s.contains($0) } }
        func idle() -> Bool { let s = tv.screenText(); return readyMarks.contains { s.contains($0) } && !s.contains("esc to interrupt") }
        let ready = waitUntil(90) { blocker() != nil || idle() }
        if let b = blocker() {
            check("live: \(agent) opened without a menu or question (\"\(b)\" on screen, not answered)", false, String(tv.screenText().suffix(700)))
            return
        }
        check("live: \(agent) started in the chat", ready, String(tv.screenText().suffix(400)))
        guard ready else { return }
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        guard blocker() == nil, idle() else {
            check("live: composer still idle before typing", false, String(tv.screenText().suffix(700)))
            return
        }
        tv.submit("In notes.txt, change the word blue to green. Edit only that file and don't run anything else.")
        let edited = waitUntil(300) { center.changes.contains { $0.path == "notes.txt" } }
        check("live: Changes updates live when the agent edits a file", edited, String(tv.screenText().suffix(800)))
        guard edited else { return }
        let page = center.diffPage.page
        _ = waitUntil(10) { (js(page, "document.querySelectorAll('tr.add').length") as? Int ?? 0) > 0 }
        _ = js(page, "(() => { document.querySelector('tr.add td.ln.n').click(); const t = document.querySelector('tr.cbox textarea'); t.value = 'Also add an exclamation mark at the end of this line.'; t.dispatchEvent(new Event('input')); document.querySelector('tr.cbox .add').click(); return 1; })()")
        check("live: comment added on the agent's line", waitUntil(3) { center.currentComments.count == 1 })
        // Wait for the turn to finish before typing the next message.
        _ = waitUntil(180) { blocker() != nil || idle() }
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        guard blocker() == nil, idle() else {
            check("live: composer idle before sending the comment (not answered)", false, String(tv.screenText().suffix(700)))
            return
        }
        center.sendComments()
        let reached = waitUntil(90) {
            guard let p = chat.transcriptPath, let t = try? String(contentsOfFile: p, encoding: .utf8) else { return false }
            return t.contains("Please address this review comment") && t.contains("exclamation mark")
        }
        check("live: the comment reached the agent as one prompt", reached, String(tv.screenText().suffix(800)))
        let acted = waitUntil(300) { ((try? String(contentsOf: repo.appendingPathComponent("notes.txt"), encoding: .utf8)) ?? "").contains("green!") }
        check("live: the agent acted on the comment", acted, String(tv.screenText().suffix(800)))
        let redrawn = waitUntil(15) { (js(page, "document.body.innerText.includes('green!')") as? Bool) == true }
        check("live: the diff refreshed with the agent's second edit", redrawn)
        print("      live transcript: \(chat.transcriptPath ?? "none")")
        print("      final screen:\n" + String(tv.screenText().suffix(1200)))
    }
}
