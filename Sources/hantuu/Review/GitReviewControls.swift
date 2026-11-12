import AppKit
import SwiftUI

extension ReviewCenter {
    func editCommentPrompt(_ comment: ReviewComment) {
        let alert = NSAlert()
        alert.messageText = "Edit review comment"
        alert.informativeText = comment.path + ":" + comment.lineLabel
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 160))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.string = comment.body
        text.font = .systemFont(ofSize: 13)
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { editComment(id: comment.id, body: text.string) }
    }

    var visibleChanges: [ChangedFile] {
        changes.filter { file in
            (pathFilter.isEmpty || file.path.localizedCaseInsensitiveContains(pathFilter)) &&
            (!hideDeleted || file.status != "D") && (!hideTests || !Self.isTest(file.path)) &&
            (!hideGenerated || !Self.isGenerated(file.path))
        }
    }
    static func isTest(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.contains("test") || p.contains("spec.")
    }
    static func isGenerated(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.hasSuffix(".lock") || p.hasSuffix(".min.js") || p.hasSuffix(".generated.swift") || p.contains("/generated/")
    }
    var gitActionsAvailable: Bool { gitSnapshot?.scope == base && gitReadState.error == nil && !gitReadState.loading && !operationRunning }

    func chooseCheckout(_ path: String) {
        selectedCheckout = path
        if let owner = checkoutPreferenceRoot {
            var saved = GitReviewSelection.load(owner)
            saved.checkout = path
            saved.save(owner)
        }
        gitSelection = GitReviewSelection.load(path)
        gitSnapshot = nil
        gitReadState = PanelReadState()
        diffReadState = PanelReadState()
        selectedPath = nil
        changes = []
        changesLoaded = false
        refreshGit()
    }
    func chooseTarget(_ ref: String) {
        gitSelection.target = ref
        gitSelection.targetRevision = nil
        if let root = repo?.root { gitSelection.save(root) }
        refreshGit()
    }
    func chooseCommit(_ oid: String) {
        gitSelection.commit = oid
        if let root = repo?.root { gitSelection.save(root) }
        refreshGit()
    }
    func stepFile(_ offset: Int) {
        let files = visibleChanges
        guard !files.isEmpty else { return }
        let current = files.firstIndex { $0.path == selectedPath } ?? 0
        select(files[(current + offset + files.count) % files.count].path)
    }

    func confirmGitAction(_ action: GitReviewAction) {
        guard gitActionsAvailable, let snapshot = gitSnapshot else { return }
        let file = selectedFile
        let alert = NSAlert()
        alert.messageText = action.title + "?"
        var detail = "Checkout: \(snapshot.info.root)\nBranch: \(snapshot.info.branch ?? "detached HEAD")\nScope: \(snapshot.scope.title)"
        switch action {
        case .stage(let f), .unstage(let f), .discard(let f): detail += "\nFile: \(f.path)"
        case .stageHunk(let h), .unstageHunk(let h), .discardHunk(let h): detail += "\nFile: \(file?.path ?? "")\nHunk: \(h.header)"
        case .stageFiles(let files), .unstageFiles(let files): detail += "\n\(files.count) visible files:\n" + files.map(\.path).joined(separator: "\n")
        case .commit(let message): detail += "\n\(snapshot.staged.count) staged files:\n" + snapshot.staged.map(\.path).joined(separator: "\n") + "\n\nMessage:\n" + message
        case .push(let remote), .pull(let remote): detail += "\nRemote: \(remote)\nFetch URL: \(snapshot.remoteURLs[remote] ?? "unavailable")\nPush URL: \(snapshot.remotePushURLs[remote] ?? "unavailable")\nUpstream: \(snapshot.upstream ?? "not configured")\nAhead: \(snapshot.ahead.map(String.init) ?? "unknown"), behind: \(snapshot.behind.map(String.init) ?? "unknown")"
        case .createPR(let remote, let base, let title, let body, let draft):
            detail += "\nRemote: \(remote)\nBase: \(base)\n\(draft ? "Draft PR" : "Ready for review")\nTitle: \(title)\n\n\(body)\n\nOnly pushed commits are included. Local edits are excluded."
        }
        switch action {
        case .discard, .discardHunk: detail += "\n\nThe current file and patches will be preserved in Review Recovery. Staged changes stay intact."
        default: break
        }
        if detail.count > 600 {
            alert.informativeText = "Review the full checkout, selection and action below."
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
            scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds)
            text.string = detail
            text.isEditable = false
            text.isSelectable = true
            text.font = .systemFont(ofSize: 12)
            text.isVerticallyResizable = true
            text.autoresizingMask = [.width]
            scroll.documentView = text
            alert.accessoryView = scroll
        } else { alert.informativeText = detail }
        alert.addButton(withTitle: action.title)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performGitAction(action, snapshot: snapshot, file: file)
    }

    func performGitAction(_ action: GitReviewAction, snapshot: GitReviewSnapshot, file: ChangedFile?) {
        guard !operationRunning else { return }
        operationRunning = true
        operationMessage = action.title + "..."
        GitReviewActions.queue.async {
            let result: Result<GitReviewActions.Outcome, Error>
            do { result = .success(try GitReviewActions.run(action, snapshot: snapshot, file: file)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                self.operationRunning = false
                // A result belongs to its checkout, even when the user switched chats meanwhile.
                guard self.repo?.root == snapshot.info.root else { return }
                switch result {
                case .success(let outcome):
                    self.operationMessage = outcome.message
                    self.recoveryFolder = outcome.backup
                    if case .commit = action { self.commitMessage = "" }
                case .failure(let error): self.operationMessage = error.localizedDescription
                }
                self.refreshGit()
            }
        }
    }
}

struct GitReviewToolbar: View {
    @EnvironmentObject var review: ReviewCenter
    @State private var actions = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let snapshot = review.gitSnapshot {
                HStack(spacing: 6) {
                    Menu {
                        ForEach(snapshot.worktrees, id: \.self) { path in
                            Button(path) { review.chooseCheckout(path) }
                        }
                    } label: {
                        Text((snapshot.info.root as NSString).lastPathComponent + " | " + (snapshot.info.branch ?? "detached"))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .help(snapshot.info.root)
                    Spacer(minLength: 0)
                    Button("Git actions") { actions = true }.buttonStyle(.plain)
                }
                if review.base == .branch {
                    Menu("Base: " + review.baseLabel) {
                        ForEach(snapshot.refs, id: \.self) { ref in Button(ref) { review.chooseTarget(ref) } }
                    }.help("Committed branch changes only. Uses local refs without fetching.")
                } else if review.base == .commit {
                    Menu("Commit: " + review.baseLabel) {
                        ForEach(snapshot.commits, id: \.self) { commit in
                            Button(String(commit.prefix(90))) { review.chooseCommit(String(commit.split(separator: " ").first ?? "")) }
                        }
                    }.help("Selected commit compared with its first parent, or the empty tree for a root commit.")
                }
                HStack(spacing: 5) {
                    TextField("Filter paths", text: $review.pathFilter).textFieldStyle(.plain)
                    Menu {
                        Toggle("Hide tests", isOn: $review.hideTests)
                        Toggle("Hide generated files", isOn: $review.hideGenerated)
                        Toggle("Hide deleted files", isOn: $review.hideDeleted)
                    } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .menuStyle(.borderlessButton).frame(width: 20)
                    Text("\(review.visibleChanges.count)/\(review.changes.count)").foregroundStyle(Color.hTertiary)
                    if review.base == .unstaged {
                        Button("Stage visible") { review.confirmGitAction(.stageFiles(review.visibleChanges)) }
                            .disabled(!review.gitActionsAvailable || review.visibleChanges.isEmpty)
                    } else if review.base == .staged {
                        Button("Unstage visible") { review.confirmGitAction(.unstageFiles(review.visibleChanges)) }
                            .disabled(!review.gitActionsAvailable || review.visibleChanges.isEmpty)
                    }
                }
                if snapshot.truncated { Text("Showing the first \(ChangeScanner.maxFiles) files. Bulk actions affect only visible files.").foregroundStyle(Color.hTertiary) }
            }
            if let checkout = review.selectedCheckout, let original = review.checkoutPreferenceRoot, checkout != original {
                HStack {
                    Text(ReviewFormat.tilde(checkout)).lineLimit(1).truncationMode(.middle).help(checkout)
                    Button("Use original checkout") { review.chooseCheckout(original) }
                }
            }
            if review.gitReadState.error != nil, review.base == .branch || review.base == .commit {
                Button("Reset comparison") {
                    review.gitSelection.target = nil
                    review.gitSelection.commit = nil
                    review.refreshGit()
                }
            }
            GitReadStatus(state: review.gitReadState, retry: review.refreshNow)
            if let error = review.diffReadState.error { Text("Diff stale: " + error).foregroundStyle(Color.hRemoved).textSelection(.enabled) }
            if let message = review.operationMessage {
                HStack(alignment: .top) {
                    if review.operationRunning { ProgressView().controlSize(.small) }
                    Text(message).lineLimit(4).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Details") {
                        let a = NSAlert(); a.messageText = "Git operation"; a.informativeText = message; a.runModal()
                    }
                }
            }
            if let recovery = review.recoveryFolder {
                Button("Show recovery copy") { NSWorkspace.shared.activateFileViewerSelecting([recovery]) }
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Color.hSecondary)
        .padding(10)
        .sheet(isPresented: $actions) { GitActionsForm().environmentObject(review) }
    }
}

struct GitReadStatus: View {
    var state: PanelReadState
    var retry: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            if state.loading { ProgressView().controlSize(.mini) }
            Text(state.label)
            if let date = state.lastSuccess { Text(date, style: .time) }
            if state.error != nil { Button("Retry", action: retry) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5)).foregroundStyle(Color.hTertiary)
        .help(state.error ?? "Last successful refresh")
    }
}

struct GitActionsForm: View {
    @EnvironmentObject var review: ReviewCenter
    @Environment(\.dismiss) private var dismiss
    @State private var remote = ""
    @State private var base = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Git actions").font(.system(size: 17, weight: .semibold))
            if let snapshot = review.gitSnapshot {
                Text(snapshot.info.root).font(.system(size: 11)).textSelection(.enabled)
                Text("\(snapshot.info.branch ?? "Detached HEAD") | \(snapshot.staged.count) staged files")
                Text("Ahead \(snapshot.ahead.map(String.init) ?? "unknown") | Behind \(snapshot.behind.map(String.init) ?? "unknown")")
                    .foregroundStyle(Color.hTertiary)
                Text("Upstream: " + (snapshot.upstream ?? "not configured")).foregroundStyle(Color.hTertiary)
                if let url = snapshot.remoteURLs[remote] { Text("Fetch: " + url).font(.system(size: 11)).textSelection(.enabled) }
                if let url = snapshot.remotePushURLs[remote] { Text("Push: " + url).font(.system(size: 11)).textSelection(.enabled) }
                Picker("Remote", selection: $remote) { ForEach(snapshot.remotes, id: \.self) { Text($0).tag($0) } }
                TextField("Commit message", text: $review.commitMessage)
                Button("Review commit") { review.confirmGitAction(.commit(review.commitMessage)) }
                    .disabled(snapshot.staged.isEmpty || review.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                HStack {
                    Button("Review push") { review.confirmGitAction(.push(remote: remote)) }
                    Button("Review pull") { review.confirmGitAction(.pull(remote: remote)) }
                }.disabled(remote.isEmpty || snapshot.info.branch == nil)
                Divider()
                TextField("PR base branch", text: $base)
                TextField("PR title", text: $review.prTitle)
                TextEditor(text: $review.prBody).frame(height: 90).border(Color.hDivider)
                Toggle("Create as draft", isOn: $review.prDraft)
                Text("PR creation includes pushed commits only. Push is a separate step.").foregroundStyle(Color.hTertiary)
                Button("Review pull request") {
                    review.confirmGitAction(.createPR(remote: remote, base: base, title: review.prTitle, body: review.prBody, draft: review.prDraft))
                }.disabled(remote.isEmpty || base.isEmpty || review.prTitle.isEmpty)
            }
            if let message = review.operationMessage { Text(message).lineLimit(5).textSelection(.enabled) }
            HStack { Spacer(); Button("Done") { dismiss() } }
        }
        .font(.system(size: 12))
        .padding(20).frame(minWidth: 320, idealWidth: 400, maxWidth: 440)
        .disabled(review.operationRunning)
        .onAppear {
            remote = review.gitSnapshot?.remotes.first ?? ""
            let target = review.gitSelection.target ?? review.repo?.defaultBranch ?? ""
            base = target.hasPrefix(remote + "/") ? String(target.dropFirst(remote.count + 1)) : target
        }
    }
}

struct GitHunkControls: View {
    @EnvironmentObject var review: ReviewCenter
    var body: some View {
        HStack(spacing: 6) {
            IconButton(symbol: "chevron.up", size: 10, help: "Previous file") { review.stepFile(-1) }
            IconButton(symbol: "chevron.down", size: 10, help: "Next file") { review.stepFile(1) }
            Menu("Hunks (\(review.hunks.count))") {
                ForEach(review.hunks) { hunk in
                    Menu(hunk.header) {
                        if review.base == .unstaged {
                            Button("Stage hunk") { review.confirmGitAction(.stageHunk(hunk)) }
                            Button("Discard unstaged hunk") { review.confirmGitAction(.discardHunk(hunk)) }
                        } else if review.base == .staged {
                            Button("Unstage hunk") { review.confirmGitAction(.unstageHunk(hunk)) }
                        }
                    }
                }
            }.disabled(!review.gitActionsAvailable || review.hunks.isEmpty || ![DiffBase.unstaged, .staged].contains(review.base))
            Spacer(minLength: 0)
            Menu("Context: \(review.diffContext)") {
                ForEach([3, 10, 30], id: \.self) { count in Button("\(count) lines") { review.diffContext = count } }
            }
        }.font(.system(size: 11)).padding(.horizontal, 10).frame(height: 28)
    }
}
