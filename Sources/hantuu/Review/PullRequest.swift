import Foundation

/// The pull request for the folder's current branch, through `gh pr view`. Read-only: hantuu
/// never runs a gh command that changes anything on GitHub.
struct PullRequestInfo: Equatable {
    struct Check: Equatable, Identifiable {
        enum State { case success, failure, pending, skipped }
        var name: String
        var state: State
        var url: String?
        var id: String { name }
    }

    var number: Int
    var title: String
    var state: String          // OPEN, CLOSED, MERGED
    var isDraft: Bool
    var url: String
    var reviewDecision: String?
    var checks: [Check]

    static let fields = "number,title,state,url,reviewDecision,statusCheckRollup,isDraft"

    static func parse(_ data: Data) -> PullRequestInfo? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let number = (o["number"] as? NSNumber)?.intValue,
              let url = o["url"] as? String else { return nil }
        var checks: [Check] = []
        var seen = Set<String>()
        for c in (o["statusCheckRollup"] as? [[String: Any]]) ?? [] {
            let name = (c["name"] as? String) ?? (c["context"] as? String) ?? "Check"
            guard seen.insert(name).inserted else { continue }
            checks.append(Check(name: name, state: checkState(c), url: (c["detailsUrl"] as? String) ?? (c["targetUrl"] as? String)))
        }
        let decision = (o["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return PullRequestInfo(number: number, title: (o["title"] as? String) ?? "", state: (o["state"] as? String) ?? "OPEN",
                               isDraft: (o["isDraft"] as? Bool) ?? false, url: url, reviewDecision: decision, checks: checks)
    }

    /// CheckRun has status and conclusion; StatusContext has state.
    static func checkState(_ c: [String: Any]) -> Check.State {
        if let conclusion = (c["conclusion"] as? String)?.uppercased(), !conclusion.isEmpty {
            switch conclusion {
            case "SUCCESS": return .success
            case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE": return .failure
            case "SKIPPED", "NEUTRAL": return .skipped
            default: break
            }
        }
        if let status = (c["status"] as? String)?.uppercased(), status != "COMPLETED", !status.isEmpty { return .pending }
        switch (c["state"] as? String)?.uppercased() {
        case "SUCCESS": return .success
        case "FAILURE", "ERROR": return .failure
        case "PENDING", "EXPECTED": return .pending
        default: return .skipped
        }
    }

    var stateLabel: String {
        if state == "MERGED" { return "Merged" }
        if state == "CLOSED" { return "Closed" }
        return isDraft ? "Draft" : "Open"
    }

    var reviewLabel: String? {
        switch reviewDecision {
        case "APPROVED": return "Approved"
        case "CHANGES_REQUESTED": return "Changes requested"
        case "REVIEW_REQUIRED": return "Review required"
        default: return nil
        }
    }
}

enum GitHubCLI {
    /// gh isn't on a GUI app's PATH, so look in the usual places, then ask the login shell once.
    static let path: String? = {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", ("~/.local/bin/gh" as NSString).expandingTildeInPath, "/usr/bin/gh"]
        if let p = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return p }
        let out = LoginShell.run("echo __GH__; command -v gh", timeout: 8)
        if let r = out.range(of: "__GH__") {
            let p = out[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if p.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }()

    struct ReadError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Only gh's explicit branch-not-found response means a successful empty result.
    static func decode(_ result: Git.Result) -> Result<PullRequestInfo?, ReadError> {
        if result.ok {
            guard let pr = PullRequestInfo.parse(result.out) else {
                return .failure(ReadError(message: "GitHub returned an unreadable pull request response."))
            }
            return .success(pr)
        }
        let detail = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 1 && detail.hasPrefix("no pull requests found for branch ") { return .success(nil) }
        if result.status == 4 || detail.contains("gh auth login") || detail.contains("HTTP 401") {
            return .failure(ReadError(message: "GitHub authentication is required. Sign in with gh auth login, then retry."))
        }
        return .failure(ReadError(message: detail.isEmpty ? "GitHub lookup failed (exit \(result.status))." : detail))
    }

    static func readPullRequest(folder: String) -> Result<PullRequestInfo?, ReadError> {
        guard let gh = path else { return .failure(ReadError(message: "GitHub CLI is unavailable. Install gh to read pull requests.")) }
        var env = ProcessInfo.processInfo.environment
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        let r = Process.capture(gh, ["pr", "view", "--json", PullRequestInfo.fields], in: folder, env: env, timeout: 20)
        return decode(r)
    }
}

// Compatibility for callers which do not display read state.
extension GitHubCLI {
    static func pullRequest(folder: String) -> PullRequestInfo? { try? readPullRequest(folder: folder).get() }
}

struct RepositoryPullRequest: Identifiable {
    var root: String
    var pr: PullRequestInfo?
    var readState = PanelReadState()
    var id: String { root }
}

extension PullRequestInfo {
    var failingChecksContext: String {
        let failures = checks.filter { $0.state == .failure }.map { check in
            "- " + check.name + (check.url.map { "\n  " + $0 } ?? "")
        }.joined(separator: "\n")
        return "Please investigate the failing checks for PR #\(number): \(title)\n\(url)\n\(failures)"
    }
}
