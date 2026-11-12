import AppKit
import SwiftUI

// Register `panelGit(dir)` alongside review(dir). All Git mutations below target newly
// created fixture repositories. The standard test launcher must provide disposable data.
extension SelfTest {
    static func panelGit(_ dir: URL) {
        let root = dir.appendingPathComponent("panel-git")
        Paths.ensure(root)
        let repo = root.appendingPathComponent(UUID().uuidString)
        Paths.ensure(repo)
        func git(_ args: [String]) throws -> Git.Result {
            let result = fixtureGit(args, repo)
            guard result.ok else { throw GitReviewError(message: result.err) }
            return result
        }
        func load(_ scope: DiffBase) throws -> GitReviewSnapshot {
            try GitReviewSnapshot.load(root: repo.path, scope: scope, selection: GitReviewSelection(target: "main"))
        }
        func file(_ snapshot: GitReviewSnapshot, _ path: String = "sample.txt") throws -> ChangedFile {
            guard let file = snapshot.files.first(where: { $0.path == path }) else { throw GitReviewError(message: "Fixture file missing: \(path)") }
            return file
        }
        func contents(_ path: String) -> String { (try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)) ?? "" }
        let original = (1...80).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let edited = original.replacingOccurrences(of: "line 5\n", with: "first edit\n").replacingOccurrences(of: "line 65\n", with: "second edit\n")
        do {
            _ = try git(["init", "-q"])
            // Actions run through the production command path, so set fixture-local
            // identity and disable signing/hooks here as well as in fixtureGit.
            for (key, value) in [("user.name", "hantuu test"), ("user.email", "selftest@hantuu.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.attributesFile", "/dev/null"), ("core.excludesFile", "/dev/null")] {
                _ = try git(["config", "--local", key, value])
            }
            write(repo, "sample.txt", original)
            write(repo, "literal[1].txt", "original literal\n")
            write(repo, "literal1.txt", "original neighbor\n")
            _ = try git(["add", "-A"])
            _ = try git(["commit", "-qm", "Fixture baseline"])
            let baseline = try GitReviewSnapshot.resolve("HEAD", root: repo.path)
            let rootCommit = try GitReviewSnapshot.load(root: repo.path, scope: .commit, selection: GitReviewSelection(commit: baseline))
            check("panel git: root commit uses empty tree", rootCommit.files.count == 3)
            _ = try git(["checkout", "-qb", "feature"])
            write(repo, "branch.txt", "committed branch change\n")
            _ = try git(["add", "branch.txt"])
            _ = try git(["commit", "-qm", "Fixture feature"])
            write(repo, "sample.txt", edited)
            write(repo, "untracked.txt", "untracked\n")

            let branch = try load(.branch)
            check("panel git: branch contains committed changes only", branch.files.map(\.path) == ["branch.txt"] && branch.baseRevision == baseline)
            let commit = try load(.commit)
            check("panel git: selected commit excludes dirty working tree", commit.files.map(\.path) == ["branch.txt"])
            var unstaged = try load(.unstaged)
            check("panel git: unstaged includes untracked", unstaged.files.contains(where: { $0.path == "untracked.txt" && $0.isUntracked }))
            let initialFile = try file(unstaged)
            let hunks = GitReviewHunk.parse(try unstaged.diff(initialFile), file: initialFile)
            guard hunks.count == 2 else { throw GitReviewError(message: "Fixture expected two separated hunks.") }
            _ = try GitReviewActions.run(.stageHunk(hunks[0]), snapshot: unstaged, file: initialFile)
            var staged = try load(.staged)
            unstaged = try load(.unstaged)
            check("panel git: mixed file appears in staged and unstaged", staged.files.contains(where: { $0.path == "sample.txt" }) && unstaged.files.contains(where: { $0.path == "sample.txt" }))
            let indexAfterHunk = try git(["show", ":sample.txt"]).text
            check("panel git: hunk stage leaves second edit unstaged", indexAfterHunk.contains("first edit") && !indexAfterHunk.contains("second edit"))

            let stagedFile = try file(staged)
            let stagedHunks = GitReviewHunk.parse(try staged.diff(stagedFile, context: 10), file: stagedFile, context: 10)
            guard let stagedHunk = stagedHunks.first else { throw GitReviewError(message: "Staged hunk missing.") }
            _ = try GitReviewActions.run(.unstageHunk(stagedHunk), snapshot: staged, file: stagedFile)
            let unstagedIndex = try git(["show", ":sample.txt"]).text
            check("panel git: unstage hunk with expanded context preserves worktree", unstagedIndex == original && contents("sample.txt") == edited)

            unstaged = try load(.unstaged)
            let discardFile = try file(unstaged)
            let discardHunks = GitReviewHunk.parse(try unstaged.diff(discardFile), file: discardFile)
            guard let discardHunk = discardHunks.first else { throw GitReviewError(message: "Discard hunk missing.") }
            let discarded = try GitReviewActions.run(.discardHunk(discardHunk), snapshot: unstaged, file: discardFile)
            check("panel git: discard hunk leaves other edit intact", !contents("sample.txt").contains("first edit") && contents("sample.txt").contains("second edit"))
            check("panel git: discard retains recovery manifest and patches", discarded.backup.map { folder in
                ["manifest.json", "file-0", "unstaged.patch", "staged.patch"].allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            } == true)
            if let backup = discarded.backup {
                check("panel git: recovery has exact pre-discard text", (try? String(contentsOf: backup.appendingPathComponent("file-0"), encoding: .utf8)) == edited)
            }

            let stale = try load(.unstaged)
            let staleFile = try file(stale)
            let staleHunks = GitReviewHunk.parse(try stale.diff(staleFile), file: staleFile)
            guard let staleHunk = staleHunks.first else { throw GitReviewError(message: "Stale fixture hunk missing.") }
            write(repo, "sample.txt", contents("sample.txt") + "external agent edit\n")
            let beforeRejection = try git(["show", ":sample.txt"]).text
            var refused = false
            do { _ = try GitReviewActions.run(.stageHunk(staleHunk), snapshot: stale, file: staleFile) } catch { refused = true }
            let afterRejection = try git(["show", ":sample.txt"]).text
            check("panel git: stale hunk refuses without staging", refused && beforeRejection == afterRejection)

            write(repo, "literal[1].txt", "changed literal\n")
            write(repo, "literal1.txt", "changed neighbor\n")
            unstaged = try load(.unstaged)
            let literal = try file(unstaged, "literal[1].txt")
            _ = try GitReviewActions.run(.stage(literal), snapshot: unstaged)
            staged = try load(.staged)
            check("panel git: literal glob path stages only selected file", staged.files.map(\.path) == ["literal[1].txt"])
            let stagedLiteral = try file(staged, "literal[1].txt")
            _ = try GitReviewActions.run(.unstage(stagedLiteral), snapshot: staged)
            let afterLiteralUnstage = try load(.staged)
            check("panel git: literal glob path unstages without touching neighbor", afterLiteralUnstage.files.isEmpty && contents("literal1.txt") == "changed neighbor\n")
            unstaged = try load(.unstaged)
            _ = try GitReviewActions.run(.stage(try file(unstaged, "literal[1].txt")), snapshot: unstaged)
            staged = try load(.staged)
            _ = try GitReviewActions.run(.commit("Fixture scoped commit"), snapshot: staged)
            let committedLiteral = try git(["show", "HEAD:literal[1].txt"]).text
            let committedNeighbor = try git(["show", "HEAD:literal1.txt"]).text
            check("panel git: commit includes only staged content", committedLiteral == "changed literal\n" && committedNeighbor == "original neighbor\n")

            // Exercise stale index detection separately from a working-tree edit.
            unstaged = try load(.unstaged)
            _ = try git(["add", "--", "literal1.txt"])
            refused = false
            do { try GitReviewActions.validate(unstaged) } catch { refused = true }
            check("panel git: index-only change invalidates snapshot", refused)

            try GitReviewSnapshot.withReadOnlyIndex(root: repo.path) { first in
                try GitReviewSnapshot.withReadOnlyIndex(root: repo.path) { second in
                    check("panel git: overlapping reads own distinct index copies", first["GIT_INDEX_FILE"] != second["GIT_INDEX_FILE"])
                }
                check("panel git: inner read does not remove outer index", first["GIT_INDEX_FILE"].map { FileManager.default.fileExists(atPath: $0) } == true)
            }
            write(repo, "literal[1].txt", "discard this literal edit\n")
            unstaged = try load(.unstaged)
            let discardLiteral = try file(unstaged, "literal[1].txt")
            let beforeDiscardIndex = try git(["show", ":literal1.txt"]).text
            let literalDiscard = try GitReviewActions.run(.discard(discardLiteral), snapshot: unstaged)
            let afterDiscardIndex = try git(["show", ":literal1.txt"]).text
            check("panel git: file discard is literal and preserves staged neighbor", contents("literal[1].txt") == "changed literal\n" && contents("literal1.txt") == "changed neighbor\n" && beforeDiscardIndex == afterDiscardIndex && literalDiscard.backup != nil)

            let beforeReadIndex = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
            let display = try load(.unstaged)
            let afterReadIndex = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
            check("panel git: review reads preserve the real index bytes", beforeReadIndex == afterReadIndex)
            check("panel git: overview includes branch and local work", display.overviewSummary.files > branch.files.count)
            let regular = ChangedFile(path: "link", oldPath: nil, status: "M", added: 1, deleted: 1)
            let linkPatch = "diff --git a/link b/link\nindex 1111111..2222222 120000\n--- a/link\n+++ b/link\n@@ -1 +1 @@\n-old-target\n+new-target\n"
            check("panel git: symlink hunk requires whole-file action", GitReviewHunk.parse(linkPatch, file: regular).isEmpty)
            panelGitSnapshots(root, snapshot: display)
            panelGitConflictFixture(root)
            let aggregateRepo = makeFixtureRepo(root.appendingPathComponent("aggregate"), forPanel: true)
            let aggregate = try GitReviewSnapshot.load(root: aggregateRepo.path, scope: .staged, selection: GitReviewSelection())
            check("panel git: Overview retains six files independent of staged scope", aggregate.overviewSummary.files == 6)
            GitReviewSelection(checkout: repo.path + "/other-checkout").save(repo.path)
            GitReviewSelection(target: "main").save(repo.path)
            check("panel git: scope persistence retains selected checkout", GitReviewSelection.load(repo.path).checkout == repo.path + "/other-checkout")


        } catch {
            check("panel git: fixture operations complete", false, error.localizedDescription)
        }
    }

    static func panelGitConflictFixture(_ root: URL) {
        let repo = root.appendingPathComponent("conflict-" + UUID().uuidString)
        Paths.ensure(repo)
        fixtureGit(["init", "-q"], repo)
        write(repo, "conflict.txt", "original\n")
        fixtureGit(["add", "conflict.txt"], repo)
        fixtureGit(["commit", "-qm", "Conflict baseline"], repo)
        fixtureGit(["checkout", "-qb", "other"], repo)
        write(repo, "conflict.txt", "other branch\n")
        fixtureGit(["commit", "-qam", "Other branch edit"], repo)
        fixtureGit(["checkout", "-q", "main"], repo)
        write(repo, "conflict.txt", "main branch\n")
        fixtureGit(["commit", "-qam", "Main branch edit"], repo)
        let merge = fixtureGit(["merge", "--no-edit", "other"], repo)
        check("panel git: fixture merge conflicts", !merge.ok)
        do {
            let snapshot = try GitReviewSnapshot.load(root: repo.path, scope: .unstaged, selection: GitReviewSelection())
            let files = snapshot.files.filter { $0.path == "conflict.txt" }
            check("panel git: conflicts appear once and remain conflicted", files.count == 1 && files.first?.status == "U")
            guard let file = files.first else { return }
            var refused = false
            do { _ = try GitReviewActions.run(.stage(file), snapshot: snapshot) } catch { refused = true }
            check("panel git: conflicted file cannot be staged by panel", refused)
        } catch { check("panel git: conflicted snapshot remains readable", false, error.localizedDescription) }
    }

    static func panelGitSnapshots(_ root: URL, snapshot: GitReviewSnapshot) {
        let review = ReviewCenter(loadSavedState: false)
        review.fixtureMode = true
        review.gitSnapshot = snapshot
        review.gitSelection = snapshot.selection
        review.base = snapshot.scope
        review.changes = snapshot.files
        review.gitReadState = PanelReadState(loading: false, lastSuccess: Date(), error: nil)
        review.commitMessage = "Keep the literal path change"
        review.prTitle = "Review fixture changes"
        review.prBody = "A disposable fixture used to inspect the Git form."
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 360, height: 680), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        for form in [false, true] {
            let content = form ? AnyView(GitActionsForm().environmentObject(review)) : AnyView(GitReviewToolbar().environmentObject(review))
            let host = ChromeHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: 360, height: 680)
            window.contentView = host
            window.orderFrontRegardless()
            for dark in [true, false] {
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                let name = "git-\(form ? "form" : "toolbar")-\(dark ? "dark" : "light").png"
                check("snapshot: \(name) at 360 points", render(host, to: root.appendingPathComponent(name)))
            }
        }
    }
}
