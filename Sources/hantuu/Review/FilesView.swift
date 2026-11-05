import AppKit
import SwiftUI

/// Files: the project tree for the chat's folder. Click opens a file in Code, Option-click
/// types its path into the chat. Changed files carry a small dot.
struct FilesView: View {
    @EnvironmentObject var review: ReviewCenter

    var body: some View {
        Group {
            if review.folder == nil {
                EmptyNote(title: "Pick a chat to browse its files")
            } else if let tree = review.tree {
                FileTreeList(tree: tree)
            } else {
                Color.hChrome
            }
        }
        .background(Color.hChrome)
    }
}

struct FileTreeList: View {
    @EnvironmentObject var review: ReviewCenter
    let tree: FileTree

    var body: some View {
        let changed = review.changedInFolder
        let changedDirs = Self.ancestors(of: changed.keys)
        let filtering = !review.filter.trimmingCharacters(in: .whitespaces).isEmpty
        ScrollView {
            LazyVStack(spacing: 0) {
                if filtering {
                    let hits = tree.matches(review.filter)
                    ForEach(hits) { n in
                        FileRow(node: n, depth: 0, showDirectory: true, changed: changed[n.path], dirChanged: false, expanded: false)
                    }
                    if hits.isEmpty {
                        Text("No files match").font(.system(size: 12)).foregroundStyle(Color.hTertiary).padding(.top, 24)
                    }
                } else {
                    ForEach(tree.rows(expanded: review.expanded)) { r in
                        FileRow(node: r.node, depth: r.depth, showDirectory: false, changed: changed[r.node.path],
                                dirChanged: r.node.isDirectory && changedDirs.contains(r.node.path), expanded: review.expanded.contains(r.node.path))
                    }
                    if tree.top.isEmpty {
                        Text("No files").font(.system(size: 12)).foregroundStyle(Color.hTertiary).padding(.top, 24)
                    }
                }
                if tree.truncated {
                    Text("Showing the first \(FileTree.maxFiles.formatted()) files").font(.system(size: 11.5)).foregroundStyle(Color.hTertiary).padding(.vertical, 10)
                }
            }
            .padding(.vertical, 5)
            // The filtered list and the tree share row ids (paths); a fresh stack for each
            // keeps filtered rows from reusing the tree's indented ones.
            .id(filtering ? "filter" : "tree")
        }
    }

    static func ancestors<S: Sequence>(of paths: S) -> Set<String> where S.Element == String {
        var out = Set<String>()
        for p in paths {
            var d = (p as NSString).deletingLastPathComponent
            while !d.isEmpty, out.insert(d).inserted { d = (d as NSString).deletingLastPathComponent }
        }
        return out
    }
}

struct FileRow: View {
    @EnvironmentObject var review: ReviewCenter
    let node: FileNode
    let depth: Int
    let showDirectory: Bool
    let changed: Character?
    let dirChanged: Bool
    let expanded: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            if depth > 0 { Spacer().frame(width: CGFloat(depth) * 14) }
            Group {
                if node.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(Color.hTertiary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)
            Image(systemName: node.isDirectory ? "folder" : "doc")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.hTertiary)
                .frame(width: 16)
            Text(node.name).font(.system(size: 12.5)).foregroundStyle(Color.hText).lineLimit(1)
            if showDirectory {
                let dir = (node.path as NSString).deletingLastPathComponent
                if !dir.isEmpty { Text(dir).font(.system(size: 11.5)).foregroundStyle(Color.hTertiary).lineLimit(1).truncationMode(.head) }
            }
            Spacer(minLength: 6)
            if let changed {
                Circle().fill(Color(nsColor: ReviewFormat.statusColor(changed))).frame(width: 6, height: 6)
                    .help(ChangedFileRow.statusHelp(changed))
            } else if dirChanged {
                Circle().fill(Color.white.opacity(0.28)).frame(width: 5, height: 5).help("Contains changes")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: 23)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.hHover : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { tap() }
        .onHover { hovering = $0 }
        .help(node.isDirectory ? node.path : "\(node.path)\nClick to open in Code. Option-click to insert the path into the chat.")
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolute)]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(absolute, forType: .string)
            }
            Button("Insert Path into Chat") { review.insertPath(absolute) }.disabled(!review.canSend)
        }
    }

    private var absolute: String { ((review.folder ?? "") as NSString).appendingPathComponent(node.path) }

    private func tap() {
        if node.isDirectory {
            review.toggleExpanded(node.path)
        } else if NSEvent.modifierFlags.contains(.option) {
            review.insertPath(absolute)
        } else {
            review.model?.openFile(absolute, line: nil)
        }
    }
}

struct FilesBar: View {
    @EnvironmentObject var review: ReviewCenter

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.hTertiary)
                TextField("Filter files", text: $review.filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.hText)
                if !review.filter.isEmpty {
                    Button { review.filter = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color.hTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.hDivider, lineWidth: 1))
            if let t = review.tree {
                Text(t.fileCount == 1 ? "1 file" : "\(t.fileCount.formatted()) files")
                    .font(.system(size: 11.5)).foregroundStyle(Color.hTertiary).lineLimit(1).fixedSize()
            }
            IconButton(symbol: "arrow.clockwise", size: 11.5, help: "Refresh") { review.refreshNow() }
        }
    }
}
