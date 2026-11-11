import AppKit
import WebKit

extension SelfTest {
    static func projectPanels(_ dir: URL) {
        let root = dir.appendingPathComponent("project-panels")
        Paths.ensure(root)
        let a = Project(path: root.appendingPathComponent("alpha").path)
        let b = Project(path: root.appendingPathComponent("beta").path)
        Paths.ensure(URL(fileURLWithPath: a.path))
        Paths.ensure(URL(fileURLWithPath: b.path))
        let file = root.appendingPathComponent("outside.txt")
        try? Data("original\n".utf8).write(to: file)
        let model = AppModel()
        model.projects = [a, b]
        let a1 = Chat(projectID: a.id, agentID: "claude")
        let a2 = Chat(projectID: a.id, agentID: "codex")
        let b1 = Chat(projectID: b.id, agentID: "claude")
        let wt = Chat(projectID: a.id, agentID: "codex")
        wt.worktree = WorktreeInfo(repo: a.path, root: a.path + "/checkout", directory: a.path + "/checkout", branch: "test")
        model.chats = [a1, a2, b1, wt]
        model.select(a1.id)
        let review = ReviewCenter(loadSavedState: false)
        review.fixtureMode = true
        review.configure(model: model)
        model.openFile(file.path, line: nil)
        let first = model.codeTabs[0].id
        model.openFile(root.appendingPathComponent("second.md").path, line: nil)
        let second = model.codeTabs[1].id
        model.selectedCodeTabID = first
        model.setPreview(second, true)
        model.panelTab = .files
        model.panelWidth = 620
        review.expanded = ["Sources", "Sources/UI"]
        review.filter = "swift"
        review.selectedFilePath = "Sources/a.swift"
        review.selectedPath = "alpha.swift"
        review.base = .branch
        review.expandedRepositories = [a.path + "/nested"]
        review.showCleanRepositories = true
        review.filesScroll = 180
        review.changesScroll = 64
        review.recordDiffScroll(key: "diff-a", top: 400)
        model.setOverviewScroll(90, project: a.id)
        model.setOverviewPanelState(OverviewPanelState(expandedAgents: ["agent-a"], allAgents: true, allTasks: true), project: a.id)
        model.setCodeTabDirty(first, true)
        let position = EditorPosition(ranges: [.init(anchor: 2, head: 5)], mainIndex: 0, top: 240, left: 12, previewTop: 80)
        model.setEditorPosition(first, position)

        model.select(b1.id)
        check("project panel: a new project starts on Overview with no files", model.panelTab == .overview && model.codeTabs.isEmpty)
        check("project panel: visibility and width stay global", model.panelVisible && model.panelWidth == 620)
        check("project panel: Files and Changes start empty", review.expanded.isEmpty && review.filter.isEmpty && review.selectedPath == nil && review.filesScroll == 0 && review.base == .uncommitted)
        model.openFile(file.path, line: nil)
        let betaFile = model.codeTabs[0].id
        check("project panel: the same outside file has a separate document in each project", betaFile != first)
        model.panelTab = .changes
        review.selectedPath = "beta.swift"
        review.expanded = ["Tests"]
        review.filesScroll = 24
        model.select(a2.id)
        check("project panel: chats in one project share the tab and ordered files", model.panelTab == .files && model.codeTabs.map(\.id) == [first, second] && model.selectedCodeTabID == first)
        check("project panel: preview mode and editor position survive", model.codeTabs[1].preview && model.codeTabs[0].editorPosition == position)
        check("project panel: folder expansion, filter and row selection return", review.expanded == ["Sources", "Sources/UI"] && review.filter == "swift" && review.selectedFilePath == "Sources/a.swift")
        check("project panel: comparison, selected diff and repository options return", review.base == .branch && review.selectedPath == "alpha.swift" && review.showCleanRepositories && review.expandedRepositories == [a.path + "/nested"])
        check("project panel: list, diff and Overview offsets return", review.filesScroll == 180 && review.changesScroll == 64 && review.diffScroll["diff-a"] == 400 && model.overviewScroll(project: a.id) == 90)
        check("project panel: background dirty tabs stay in the global inventory", model.allCodeTabs.count == 3 && model.allCodeTabs.first { $0.id == first }?.dirty == true)
        model.select(wt.id)
        check("project panel: a worktree shares Code tabs and panel tab", model.panelTab == .files && model.codeTabs.map(\.id) == [first, second])
        check("project panel: a worktree has separate folder state", review.folder == wt.worktreePath && review.expanded.isEmpty && review.selectedPath == nil && review.filter.isEmpty)
        review.expanded = ["WorktreeOnly"]
        review.selectedPath = "worktree.swift"
        model.select(a1.id)
        check("project panel: the main checkout keeps its state after a worktree visit", review.expanded.contains("Sources/UI") && review.selectedPath == "alpha.swift")
        model.select(wt.id)
        check("project panel: the worktree restores its own state", review.expanded == ["WorktreeOnly"] && review.selectedPath == "worktree.swift")
        model.select(b1.id)
        check("project panel: the second project's selection returns", model.panelTab == .changes && model.codeTabs.map(\.id) == [betaFile] && review.selectedPath == "beta.swift" && review.expanded == ["Tests"])
        model.setCodeTabDirty(first, false)
        check("project panel: a late editor message updates its background project", model.allCodeTabs.first { $0.id == first }?.dirty == false)

        var saved = SavedState()
        saved.projects = [a, b]
        saved.projectPanels = model.savedProjectPanels()
        let decoded = (try? JSONEncoder.hantuu.encode(saved)).flatMap(SavedState.read)
        let restored = AppModel()
        restored.projects = [a, b]
        restored.restoreProjectPanels(decoded ?? SavedState())
        restored.selectedProjectID = a.id
        check("project panel: saved state restores tab order, selection and preview", restored.codeTabs.map(\.id) == [first, second] && restored.selectedCodeTabID == first && restored.codeTabs[1].preview && restored.panelTab == .files)
        check("project panel: Overview expansion and toggles round-trip", restored.overviewPanelState(project: a.id).expandedAgents == ["agent-a"] && restored.overviewPanelState(project: a.id).allTasks == true)
        check("project panel: saved state restores editor selection and scroll", restored.codeTabs.first?.editorPosition == position)
        check("project panel: saved state keeps both checkout records", restored.folderPanelState(project: a.id, folder: a.path).selectedPath == "alpha.swift" && restored.folderPanelState(project: a.id, folder: wt.worktreePath!).selectedPath == "worktree.swift")
        restored.selectedProjectID = b.id
        check("project panel: saved state restores the second project", restored.panelTab == .changes && restored.codeTabs.map(\.id) == [betaFile])
        restored.projects.removeAll { $0.id == a.id }
        restored.pruneProjectPanels()
        check("project panel: removed projects are pruned with their open documents", restored.projectPanels[a.id] == nil && !restored.allCodeTabs.contains { $0.id == first })
        var withAway = saved
        let away = Project(path: root.appendingPathComponent("unplugged-drive").path)
        withAway.projects.append(away)
        withAway.projectPanels?[away.id.uuidString] = saved.projectPanels?[a.id.uuidString]
        let awayModel = AppModel()
        awayModel.restoreProjectList(withAway)
        awayModel.restoreProjectPanels(withAway)
        check("project panel: temporarily missing projects retain their saved panel", !awayModel.projects.contains { $0.id == away.id } && awayModel.savedProjectPanels()[away.id.uuidString]?.codeTabs?.count == 2)
        let old = SavedState.read(Data(#"{"panelTab":"Changes","projects":[],"chats":[]}"#.utf8))
        check("project panel: an old state without project panels still loads", old != nil && old?.projectPanels == nil)
        let damaged = """
        {"projectPanels":{"\(a.id)":{"tab":"Code","codeTabs":[{"id":"\(first)","path":"example.txt"},{"id":3}],"folders":{"good":{"filter":"ok"},"bad":false}},"broken":17}}
        """
        let partial = SavedState.read(Data(damaged.utf8))
        check("project panel: malformed panel entries do not discard valid siblings", partial?.projectPanels?.count == 1 && partial?.projectPanels?[a.id.uuidString]?.codeTabs?.count == 1 && partial?.projectPanels?[a.id.uuidString]?.folders?["good"]?.filter == "ok")
        let sameFolder = AppModel()
        let duplicate = Project(path: a.path)
        sameFolder.projects = [a, duplicate]
        sameFolder.selectedProjectID = a.id
        sameFolder.panelTab = .files
        sameFolder.setFolderPanelState(FolderPanelState(filter: "only-alpha"), project: a.id, folder: a.path)
        sameFolder.selectedProjectID = duplicate.id
        check("project panel: projects sharing one folder still have separate state", sameFolder.panelTab == .overview && sameFolder.folderPanelState(project: duplicate.id, folder: a.path).filter == nil)
        projectPanelEditor(root, a: a, b: b)
    }

    private static func projectPanelEditor(_ root: URL, a: Project, b: Project) {
        let file = root.appendingPathComponent("editor.txt")
        let original = (1...250).map { "Line \($0)" }.joined(separator: "\n") + "\n"
        try? Data(original.utf8).write(to: file)
        let model = AppModel()
        model.projects = [a, b]
        model.selectedProjectID = a.id
        let viewer = FileViewerController(model: model)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 560, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = viewer.view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        model.openFile(file.path, line: nil)
        let id = model.codeTabs[0].id
        guard waitUntil(10, { viewer.page.ready && viewer.docs[id]?.inPage == true }) else {
            check("project panel editor: fixture opens", false)
            return
        }
        _ = js(viewer.page, "hantuu._view().dispatch({changes:{from:0,insert:'unsaved '},selection:{anchor:2,head:5}}); 1")
        check("project panel editor: fixture becomes dirty", waitUntil(3) { model.codeTabs[0].dirty })
        _ = js(viewer.page, "hantuu._view().scrollDOM.scrollTop = 700; 1")
        check("project panel editor: scroll position reaches the model", waitUntil(3) { (model.codeTabs[0].editorPosition?.top ?? 0) > 500 })
        let doc = viewer.docs[id]
        model.selectedProjectID = b.id
        viewer.render()
        check("project panel editor: switching keeps the document loaded", viewer.docs[id] === doc && viewer.unsavedTabs.map(\.id) == [id])
        var prompted: [UUID] = []
        viewer.promptOverride = { tabs in prompted = tabs.map(\.id); return .cancel }
        check("project panel editor: quit sees background unsaved changes", !viewer.confirmQuit() && prompted == [id])
        model.openFile(file.path, line: nil)
        let other = model.codeTabs[0].id
        _ = waitUntil(6) { viewer.docs[other]?.inPage == true }
        model.selectedProjectID = a.id
        viewer.render()
        check("project panel editor: unsaved text and selection survive switching", waitUntil(3) {
            (js(viewer.page, "hantuu._view().state.doc.toString()") as? String) == "unsaved " + original
                && (js(viewer.page, "hantuu._view().state.selection.main.head") as? Int) == 5
        })
        check("project panel editor: scroll position returns with the document", (js(viewer.page, "hantuu._view().scrollDOM.scrollTop") as? Double ?? 0) > 500)
        check("project panel editor: switching never writes the file", (try? String(contentsOf: file, encoding: .utf8)) == original)
        model.selectedProjectID = b.id
        model.closeCodeTab(other)
        viewer.render()
        check("project panel editor: closing another project's file keeps the dirty document", viewer.docs[id] === doc && viewer.unsavedTabs.map(\.id) == [id])
        viewer.promptOverride = { _ in .save }
        check("project panel editor: quit can save a background document", viewer.confirmQuit() && (try? String(contentsOf: file, encoding: .utf8)) == "unsaved " + original)
    }
}
