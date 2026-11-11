import AppKit
import SwiftUI

extension Color {
    static var hAdded: Color { Color(nsColor: ReviewColors.added) }
    static var hRemoved: Color { Color(nsColor: ReviewColors.removed) }
    static var hPending: Color { Color(nsColor: ReviewColors.pending) }
    static var hLink: Color { Color(nsColor: Theme.link) }
}

/// A quiet card: a small title, optional trailing text, thin border. Tappable when it has an
/// action.
struct ReviewCard<Content: View>: View {
    let title: String
    var trailing: String? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.hTertiary)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(.system(size: 11.5)).foregroundStyle(Color.hTertiary).lineLimit(1)
                }
                if action != nil {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.hTertiary)
                }
            }
            content
        }
        .padding(.horizontal, 13)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering && action != nil ? Color.hHover : Color(nsColor: ReviewColors.card)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.hDivider, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .onHover { hovering = $0 }
    }
}

/// An SF Symbol and a line of secondary text.
struct InfoRow: View {
    let symbol: String
    let text: String
    var help: String? = nil
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Color.hTertiary).frame(width: 15)
            Text(text).font(.system(size: 12)).foregroundStyle(Color.hSecondary).lineLimit(1).truncationMode(.middle)
        }
        .help(help ?? text)
    }
}

struct EmptyNote: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 12.5)).foregroundStyle(Color.hTertiary)
            if let detail {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Color.hTertiary.opacity(0.8)).multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.hChrome)
    }
}

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var review: ReviewCenter

    var body: some View {
        if let chat = review.selectedChat {
            OverviewCards(chat: chat)
        } else {
            EmptyNote(title: "Pick a chat to see its overview")
        }
    }
}

struct OverviewCards: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var review: ReviewCenter
    @ObservedObject var chat: Chat

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                session
                if let s = review.overviewSummary, s.files > 0, review.hasRepositories { changes(s) }
                if let pr = review.pr { PullRequestCard(pr: pr) }
                if let i = review.insights, let used = i.contextUsed, let window = i.contextWindow { context(used: used, window: window, guess: i.windowIsGuess) }
                if let plan = review.insights?.plan, !plan.isEmpty { PlanCard(items: plan) }
                if !review.ports.isEmpty { PortsCard(ports: review.ports) }
            }
            .padding(14)
        }
        .scrollIndicators(.automatic)
        .background(Color.hChrome)
    }

    private var session: some View {
        ReviewCard(title: "Session") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(chat.agent.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.hText)
                    if let m = review.insights?.model {
                        Text(m).font(.system(size: 12)).foregroundStyle(Color.hSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    HStack(spacing: 6) {
                        ActivityDot(activity: chat.activity)
                        Text(chat.activity.label).font(.system(size: 11.5)).foregroundStyle(Color.hTertiary)
                    }
                }
                .padding(.bottom, 2)
                if let folder = review.folder {
                    InfoRow(symbol: "folder", text: ReviewFormat.tilde(folder), help: folder)
                }
                if let repo = review.repo {
                    let branch = repo.branch ?? "Detached HEAD"
                    InfoRow(symbol: "arrow.triangle.branch", text: repo.isLinkedWorktree ? "\(branch)  (worktree)" : branch)
                }
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    InfoRow(symbol: "clock", text: runningText(now: ctx.date))
                }
            }
        }
    }

    private func runningText(now: Date) -> String {
        if chat.status == .ended || chat.terminal == nil {
            return "Ended. Started \(ReviewFormat.clock(chat.createdAt))"
        }
        return "Running for \(ReviewFormat.duration(now.timeIntervalSince(chat.startedAt))), since \(ReviewFormat.clock(chat.startedAt))"
    }

    private func changes(_ s: ChangeSummary) -> some View {
        let against = review.repo?.mergeBase != nil ? (review.repo?.defaultBranch ?? "the branch base") : "the last commit"
        let changed = review.repositories.filter(\.hasChanges).count
        return ReviewCard(title: "Changes", action: {
            review.showOverviewChanges()
        }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(s.files == 1 ? "1 file changed" : "\(s.files) files changed").font(.system(size: 12.5)).foregroundStyle(Color.hText)
                    Text("+\(s.added)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.hAdded)
                    Text("−\(s.deleted)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.hRemoved)
                }
                Text(review.repo != nil ? "Against \(against)" : "In \(changed) \(changed == 1 ? "repository" : "repositories")").font(.system(size: 11.5)).foregroundStyle(Color.hTertiary)
            }
        }
    }

    private func context(used: Int, window: Int, guess: Bool) -> some View {
        let fraction = min(1, Double(used) / Double(max(window, 1)))
        let pct = Int((fraction * 100).rounded())
        return ReviewCard(title: "Context", trailing: "\(pct)% of \(guess ? "≈" : "")\(ReviewFormat.tokens(window))") {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.hInk(0.08))
                        Capsule().fill(fraction > 0.8 ? Color.hPending : Color.hText.opacity(0.55))
                            .frame(width: max(2, g.size.width * fraction))
                    }
                }
                .frame(height: 3)
                Text("\(used.formatted()) tokens in use").font(.system(size: 11.5)).foregroundStyle(Color.hTertiary)
            }
        }
        .help(guess ? "The window size is a guess: the transcript doesn't say which context size the model runs with." : "")
    }
}

struct PullRequestCard: View {
    let pr: PullRequestInfo
    static let maxChecks = 8

    var body: some View {
        ReviewCard(title: "Pull request") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("#\(pr.number)").font(.system(size: 12.5)).foregroundStyle(Color.hSecondary)
                    Text(pr.title).font(.system(size: 12.5)).foregroundStyle(Color.hText).lineLimit(2)
                }
                HStack(spacing: 10) {
                    Text(pr.stateLabel).font(.system(size: 11.5, weight: .medium)).foregroundStyle(stateColor)
                    if let r = pr.reviewLabel {
                        Text(r).font(.system(size: 11.5)).foregroundStyle(pr.reviewDecision == "CHANGES_REQUESTED" ? Color.hPending : Color.hSecondary)
                    }
                }
                if !pr.checks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(pr.checks.prefix(Self.maxChecks)) { c in CheckRow(check: c) }
                        if pr.checks.count > Self.maxChecks {
                            Text("and \(pr.checks.count - Self.maxChecks) more").font(.system(size: 11.5)).foregroundStyle(Color.hTertiary)
                        }
                    }
                    .padding(.top, 1)
                }
                Button {
                    if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) }
                } label: {
                    HStack(spacing: 4) {
                        Text("Open on GitHub")
                        Image(systemName: "arrow.up.right").font(.system(size: 9.5, weight: .semibold))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Color.hLink)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    private var stateColor: Color {
        switch pr.stateLabel {
        case "Open": return .hAdded
        case "Merged": return Color(nsColor: Theme.pair(dark: NSColor(hex: 0xB49AE0), light: NSColor(hex: 0x7F58BF)))
        case "Closed": return .hRemoved
        default: return .hSecondary
        }
    }
}

struct CheckRow: View {
    let check: PullRequestInfo.Check
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color).frame(width: 15)
            Text(check.name).font(.system(size: 12)).foregroundStyle(Color.hSecondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { if let s = check.url, let u = URL(string: s) { NSWorkspace.shared.open(u) } }
        .help(check.url ?? check.name)
    }

    private var symbol: String {
        switch check.state {
        case .success: return "checkmark.circle"
        case .failure: return "xmark.circle"
        case .pending: return "circle.dotted"
        case .skipped: return "minus.circle"
        }
    }

    private var color: Color {
        switch check.state {
        case .success: return .hAdded
        case .failure: return .hRemoved
        case .pending: return .hPending
        case .skipped: return .hTertiary
        }
    }
}

struct PlanCard: View {
    let items: [PlanItem]

    var body: some View {
        let done = items.filter { $0.state == .completed }.count
        ReviewCard(title: "Plan", trailing: "\(done) of \(items.count) done") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol(item.state)).font(.system(size: 11)).foregroundStyle(color(item.state)).frame(width: 15)
                        Text(item.text).font(.system(size: 12.5))
                            .foregroundStyle(item.state == .completed ? Color.hTertiary : (item.state == .inProgress ? Color.hText : Color.hSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func symbol(_ s: PlanItem.State) -> String {
        switch s {
        case .completed: return "checkmark.circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .pending: return "circle"
        }
    }

    private func color(_ s: PlanItem.State) -> Color {
        switch s {
        case .completed: return .hAdded
        case .inProgress: return .hText
        case .pending: return .hTertiary
        }
    }
}

struct PortsCard: View {
    let ports: [ListeningPort]
    var body: some View {
        ReviewCard(title: "Ports") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ports) { p in PortRow(port: p) }
            }
        }
    }
}

struct PortRow: View {
    let port: ListeningPort
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 8) {
            Text("localhost:\(String(port.port))").font(.system(size: 12.5)).foregroundStyle(hovering ? Color.hLink : Color.hText)
            Text(port.command).font(.system(size: 11.5)).foregroundStyle(Color.hTertiary).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Color.hTertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { if let u = URL(string: "http://localhost:\(port.port)") { NSWorkspace.shared.open(u) } }
        .onHover { hovering = $0 }
        .help("Open http://localhost:\(port.port) in your browser")
    }
}

struct OverviewBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var review: ReviewCenter
    var body: some View {
        HStack(spacing: 8) {
            if let chat = model.selectedChat {
                ReaderBarTitle(chat: chat)
            } else {
                Text("No chat selected").font(.system(size: 12)).foregroundStyle(Color.hTertiary)
            }
            Spacer()
            IconButton(symbol: "arrow.clockwise", size: 11.5, help: "Refresh") { review.refreshNow() }
        }
        .padding(.horizontal, 4)
    }
}
