import AppKit
import SwiftUI

/// Changes: the changed files on top, the selected file's diff below, and the pending
/// comments at the bottom.
struct ChangesView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var review: ReviewCenter

    var body: some View {
        VStack(spacing: 0) {
            content
            if !review.currentComments.isEmpty || review.flash != nil {
                Rectangle().fill(Color.hDivider).frame(height: 1)
                CommentBar()
            }
        }
        .background(Color.hChrome)
    }

    @ViewBuilder private var content: some View {
        if review.folder == nil {
            EmptyNote(title: "Pick a chat to review its changes")
        } else if !review.repoChecked {
            Color.hChrome
        } else if review.repo == nil {
            EmptyNote(title: "Not a git repository", detail: "Changes compares the chat's folder with git, so it needs a repository.")
        } else if review.changesLoaded && review.changes.isEmpty {
            EmptyNote(title: review.base == .branch ? "No changes against \(review.baseLabel)" : "No uncommitted changes",
                      detail: review.base == .uncommitted && review.repo?.mergeBase != nil ? "Branch shows everything since \(review.repo?.defaultBranch ?? "the base")." : nil)
        } else {
            GeometryReader { g in
                VStack(spacing: 0) {
                    ChangedFileList().frame(height: listHeight(g.size.height))
                    Rectangle().fill(Color.hDivider).frame(height: 1)
                    if let f = review.selectedFile {
                        FileBar(file: f)
                        Rectangle().fill(Color.hDivider).frame(height: 1)
                    }
                    DiffWebView(webView: review.diffPage.view)
                }
            }
        }
    }

    private func listHeight(_ total: CGFloat) -> CGFloat {
        let natural = CGFloat(review.changes.count) * ChangedFileRow.height + 10
        return min(natural, max(110, total * 0.34))
    }
}

struct ChangedFileList: View {
    @EnvironmentObject var review: ReviewCenter

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(review.changes) { f in
                        ChangedFileRow(file: f, selected: f.path == review.selectedPath, viewed: review.isViewed(f)).id(f.path)
                    }
                }
                .padding(.vertical, 5)
            }
            .onChange(of: review.selectedPath) { _, p in if let p { proxy.scrollTo(p) } }
        }
    }
}

struct ChangedFileRow: View {
    @EnvironmentObject var review: ReviewCenter
    let file: ChangedFile
    let selected: Bool
    let viewed: Bool
    static let height: CGFloat = 25
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(String(file.status))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: ReviewFormat.statusColor(file.status)))
                .frame(width: 12)
                .help(Self.statusHelp(file.status))
            HStack(spacing: 6) {
                Text(file.name).font(.system(size: 12.5)).foregroundStyle(viewed ? Color.hTertiary : Color.hText).layoutPriority(1)
                if !file.directory.isEmpty {
                    Text(file.directory).font(.system(size: 11.5)).foregroundStyle(Color.hTertiary).truncationMode(.head)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            if viewed {
                Image(systemName: "checkmark").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Color.hTertiary).help("Viewed")
            }
            if !(file.status == "R" && file.added == 0 && file.deleted == 0) {
                DiffCounts(added: file.added, deleted: file.deleted)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.hSelection : (hovering ? Color.hHover : .clear)))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { review.selectedPath = file.path }
        .onHover { hovering = $0 }
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
        .contextMenu {
            Button("Open in Code") { review.open(file) }
            Button(viewed ? "Mark as Not Viewed" : "Mark as Viewed") { review.toggleViewed(file) }
            Divider()
            Button("Revert…") { review.confirmRevert(file) }.disabled(!review.hasUncommittedChanges(file))
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(review.absolutePath(file) ?? file.path, forType: .string)
            }
            Button("Reveal in Finder") {
                if let p = review.absolutePath(file) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
            }
        }
    }

    static func statusHelp(_ s: Character) -> String {
        switch s {
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "?": return "Untracked"
        case "U": return "Conflicted"
        default: return "Modified"
        }
    }
}

struct DiffCounts: View {
    let added: Int?
    let deleted: Int?
    var body: some View {
        if let added, let deleted {
            HStack(spacing: 5) {
                Text("+\(added)").foregroundStyle(Color.hAdded)
                Text("−\(deleted)").foregroundStyle(Color.hRemoved)
            }
            .font(.system(size: 11.5).monospacedDigit())
        } else {
            Text("binary").font(.system(size: 11.5)).foregroundStyle(Color.hTertiary)
        }
    }
}

/// The selected file's path and actions, above its diff.
struct FileBar: View {
    @EnvironmentObject var review: ReviewCenter
    let file: ChangedFile

    var body: some View {
        let viewed = review.isViewed(file)
        let canRevert = review.hasUncommittedChanges(file)
        HStack(spacing: 4) {
            Text(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                .font(.system(size: 12))
                .foregroundStyle(Color.hSecondary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(file.path)
            Spacer(minLength: 8)
            Button { review.toggleViewed(file) } label: {
                HStack(spacing: 5) {
                    Image(systemName: viewed ? "checkmark.square.fill" : "square").font(.system(size: 11.5))
                    Text("Viewed").font(.system(size: 11.5))
                }
                .foregroundStyle(viewed ? Color.hText : Color.hSecondary)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(viewed ? "Mark as not viewed" : "Mark as viewed. It comes back if the file changes again.")
            IconButton(symbol: "chevron.left.forwardslash.chevron.right", size: 11.5, help: "Open in Code") {
                review.open(file, line: nil)
            }
            .disabled(file.status == "D")
            IconButton(symbol: "arrow.uturn.backward", size: 11.5, help: canRevert ? "Revert…" : "No uncommitted changes to revert") {
                review.confirmRevert(file)
            }
            .disabled(!canRevert)
            .opacity(canRevert ? 1 : 0.4)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 30)
    }
}

/// "3 comments" and Send to Agent, shown while comments are waiting.
struct CommentBar: View {
    @EnvironmentObject var review: ReviewCenter
    // Redraws when the chat starts or ends, so Send follows whether it can type into it.
    @EnvironmentObject var model: AppModel

    var body: some View {
        let n = review.currentComments.count
        HStack(spacing: 8) {
            if let flash = review.flash, n == 0 {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.hAdded)
                Text(flash).font(.system(size: 12)).foregroundStyle(Color.hSecondary)
            } else {
                Image(systemName: "text.bubble").font(.system(size: 12)).foregroundStyle(Color.hSecondary)
                Text(n == 1 ? "1 comment" : "\(n) comments").font(.system(size: 12)).foregroundStyle(Color.hText)
            }
            Spacer()
            if n > 0 {
                Button("Clear") {
                    let a = NSAlert()
                    a.messageText = n == 1 ? "Clear this comment?" : "Clear \(n) comments?"
                    a.informativeText = "They haven't been sent to the agent."
                    a.addButton(withTitle: "Clear")
                    a.addButton(withTitle: "Cancel")
                    if a.runModal() == .alertFirstButtonReturn { review.clearComments() }
                }
                .buttonStyle(BarButtonStyle(prominent: false))
                Button("Send to Agent  ⌘↩") { review.sendComments() }
                    .buttonStyle(BarButtonStyle(prominent: true))
                    .disabled(!review.canSend)
                    .opacity(review.canSend ? 1 : 0.45)
                    .help(review.canSend ? "Types the comments into the chat as one message" : "The chat isn't running. Resume it to send comments.")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color.hChrome)
    }
}

struct ChangesBar: View {
    @EnvironmentObject var review: ReviewCenter

    var body: some View {
        let canBranch = review.repo?.mergeBase != nil
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                ModeButton(title: "Uncommitted", selected: review.base == .uncommitted) { review.base = .uncommitted }
                    .help("Changes since the last commit")
                ModeButton(title: "Branch", selected: review.base == .branch) { if canBranch { review.base = .branch } }
                    .opacity(canBranch ? 1 : 0.4)
                    .help(canBranch ? "Everything since this branch left \(review.repo?.defaultBranch ?? "the default branch")" : "No default branch to compare with")
            }
            if review.repo != nil, review.changesLoaded, !review.changes.isEmpty {
                let s = review.changes.summary
                HStack(spacing: 6) {
                    Text(s.files == 1 ? "1 file" : "\(s.files) files").foregroundStyle(Color.hTertiary)
                    Text("+\(s.added)").foregroundStyle(Color.hAdded)
                    Text("−\(s.deleted)").foregroundStyle(Color.hRemoved)
                }
                .font(.system(size: 11.5).monospacedDigit())
                .lineLimit(1)
            }
            Spacer()
            IconButton(symbol: "arrow.clockwise", size: 11.5, help: "Refresh") { review.refreshNow() }
        }
    }
}
