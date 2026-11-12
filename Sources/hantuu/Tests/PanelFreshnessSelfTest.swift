import AppKit
import SwiftUI

extension SelfTest {
    /// Pure result fixtures: no gh, network, lsof, real transcript or agent process.
    static func panelFreshness(_ dir: URL) {
        let absent = GitHubCLI.decode(.init(status: 1, out: Data(), err: "no pull requests found for branch \"feature\"\n"))
        if case .success(nil) = absent { check("PR: explicit no-match is empty success", true) }
        else { check("PR: explicit no-match is empty success", false) }
        for (status, message) in [(Int32(4), "authentication required"), (1, "error connecting to api.github.com"), (1, "GraphQL: Resource not accessible")] {
            if case .failure = GitHubCLI.decode(.init(status: status, out: Data(), err: message)) {
                check("PR: failure is not absence - \(message)", true)
            } else { check("PR: failure is not absence - \(message)", false) }
        }
        if case .failure = GitHubCLI.decode(.init(status: 0, out: Data("{}".utf8), err: "")) {
            check("PR: malformed response stays unavailable", true)
        } else { check("PR: malformed response stays unavailable", false) }
        if case .success(let listeners) = Ports.decode(.init(status: 1, out: Data(), err: "")) {
            check("Ports: silent no-match is empty success", listeners.isEmpty)
        } else { check("Ports: silent no-match is empty success", false) }
        if case .failure = Ports.decode(.init(status: 1, out: Data(), err: "lsof: permission denied")) {
            check("Ports: diagnostics are not a clean scan", true)
        } else { check("Ports: diagnostics are not a clean scan", false) }
        let stale = PanelReadState(lastSuccess: Date(timeIntervalSince1970: 1_700_000_000), error: "Network unavailable. Last successful result retained.")
        check("Read state: failed refresh is stale", stale.label == "Stale")
        check("Read state: first failure is unavailable", PanelReadState(error: "Failed").label == "Unavailable")
        check("Read state: refresh retains success time", PanelReadState(loading: true, lastSuccess: stale.lastSuccess).label == "Refreshing")
        panelDiscoveryFailures(dir)
        panelFreshnessSnapshots(dir, stale: stale)
    }

    static func panelDiscoveryFailures(_ dir: URL) {
        let missing = dir.appendingPathComponent("missing-" + UUID().uuidString).path
        let discovered = RepositoryDiscovery.discover(folder: missing)
        check("Discovery: missing directory reports an error", !discovered.errors.isEmpty && discovered.repositories.isEmpty)
        do {
            _ = try FileTree.walkChecked(missing)
            check("Files: missing folder is not a successful empty tree", false)
        } catch { check("Files: missing folder is not a successful empty tree", true) }
        let info = RepoInfo(root: missing, branch: "feature", headExists: true, isLinkedWorktree: false, defaultBranch: "main", mergeBase: "base")
        for failingArg in ["status", "--numstat", "--name-status"] {
            do {
                _ = try RepositoryChanges.readChanges(info) { args in
                    if args.contains(failingArg) { return .init(status: 128, out: Data(), err: "fixture failure") }
                    return .init(status: 0, out: Data(), err: "")
                }
                check("Nested repository: \(failingArg) failure is explicit", false)
            } catch { check("Nested repository: \(failingArg) failure is explicit", error.localizedDescription.contains("fixture failure")) }
        }
        do {
            let files = try RepositoryChanges.readChanges(info) { args in
                let text: String
                if args.first == "status" { text = " M a.swift\0" }
                else if args.contains("--name-status") { text = "M\0a.swift\0" }
                else { text = "2\t1\ta.swift\0" }
                return .init(status: 0, out: Data(text.utf8), err: "")
            }
            check("Nested repository: successful counts survive", files.uncommitted.first?.added == 2 && files.branch.first?.deleted == 1)
        } catch { check("Nested repository: successful counts survive", false, error.localizedDescription) }
    }

    static func panelFreshnessSnapshots(_ dir: URL, stale: PanelReadState) {
        let pr = PullRequestInfo(number: 42, title: "Preserve context while refreshing", state: "OPEN", isDraft: false,
                                 url: "https://github.com/example/project/pull/42", reviewDecision: "REVIEW_REQUIRED",
                                 checks: [.init(name: "Unit tests", state: .failure, url: "https://github.com/example/project/actions/runs/42")])
        check("CI context contains PR and failing check", pr.failingChecksContext.contains("Unit tests") && pr.failingChecksContext.contains(pr.url))
        let host = NSHostingView(rootView: VStack(spacing: 10) {
            PullRequestCard(pr: pr, readState: stale, retry: {}, addFailures: {})
            PortsCard(ports: [.init(port: 3000, pid: 123, command: "node")], readState: stale, retry: {})
            ReviewCard(title: "Context") {
                PanelReadStatus(state: .init(error: "No transcript is available for this chat."), source: "Transcript", retry: {})
            }
            ReviewCard(title: "Pull request") {
                PanelReadStatus(state: .init(loading: true), source: "GitHub CLI")
            }
        }.padding(14).background(Color.hChrome))
        let frame = NSRect(x: 0, y: 0, width: 430, height: 650)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.frame = frame
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            check("Overview freshness snapshot: \(name)", render(host, to: snapshotDir(dir).appendingPathComponent("overview-freshness-\(name).png")))
        }
    }
}
