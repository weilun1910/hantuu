import AppKit
import WebKit
import SwiftUI

// Register `panelRecovery(dir)` in SelfTest.run alongside fileViewer(dir).
// Fixtures and snapshot outputs stay under the self-test directory. Run with --data-dir
// pointing at disposable test data, as required by the existing self-test launcher.
extension SelfTest {
    static func panelRecovery(_ dir: URL) {
        let root = dir.appendingPathComponent("panel-recovery")
        Paths.ensure(root)
        let store = EditorRecoveryStore(directory: root.appendingPathComponent("journal"))
        let record = EditorRecoveryRecord(projectID: UUID(), documentID: UUID(), path: root.appendingPathComponent("example.swift").path,
                                          realPath: root.appendingPathComponent("example.swift").path, text: "unsaved\n", baseline: "original\n",
                                          baselineFingerprint: EditorRecoveryRecord.fingerprint("original\n"), updated: Date())
        store.put(record)
        check("recovery: native buffer is immediate before debounce", store.read(record.documentID) == record)
        check("recovery: baseline detects agent edits", record.matchesDisk("original\n") && !record.matchesDisk("agent edit\n"))
        store.flush(record.documentID)
        let restarted = EditorRecoveryStore(directory: store.directory)
        check("recovery: journal survives a fresh store", restarted.read(record.documentID) == record)
        let permissions = try? FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent(record.documentID.uuidString + ".json").path)[.posixPermissions] as? NSNumber
        check("recovery: journal is owner-only", permissions?.intValue == 0o600)
        store.remove(record.documentID)
        check("recovery: discard removes durable text", restarted.read(record.documentID) == nil)

        let legacyShell = "{\"id\":\"\(UUID().uuidString)\",\"title\":\"Shell\"}"
        let decodedLegacy = try? JSONDecoder().decode(SavedPanelShell.self, from: Data(legacyShell.utf8))
        check("shell: old saved shells decode without cwd", decodedLegacy != nil && decodedLegacy?.cwd == nil)
        let savedShell = SavedPanelShell(id: UUID(), title: "Worktree", cwd: root.appendingPathComponent("checkout").path)
        let shellData = try? JSONEncoder().encode(savedShell)
        check("shell: checkout survives persisted state", shellData.flatMap { try? JSONDecoder().decode(SavedPanelShell.self, from: $0) }?.cwd == savedShell.cwd)

        panelShellSnapshots(root)
        for provider in ["claude", "codex"] {
            let file = root.appendingPathComponent(provider + ".swift")
            try? Data("let original = true\n".utf8).write(to: file)
            let model = AppModel()
            let project = Project(path: root.path)
            model.projects = [project]
            let chat = Chat(projectID: project.id, agentID: provider)
            model.chats = [chat]
            model.select(chat.id)
            let viewer = FileViewerController(model: model)
            let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 360, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = viewer.view
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            model.panelVisible = true
            model.panelTab = .code
            model.openFile(file.path, line: nil)
            guard let id = model.selectedCodeTabID else { check("recovery: selected fixture", false); continue }
            let page = viewer.page
            guard waitUntil(8, { page.ready && viewer.docs[id]?.inPage == true && (js(page, "!!hantuu._view()") as? Bool) == true }) else {
                check("recovery: editor loads", false); continue
            }
            _ = js(page, "hantuu._view().dispatch({changes:{from:0,insert:'// unsaved\\n'},userEvent:'input'}); 1")
            check("recovery: \(provider) edit reaches native buffer", waitUntil(3) { viewer.docs[id]?.recovery?.text.hasPrefix("// unsaved") == true })
            viewer.recoveryStore.flush(id)
            page.webView.reload()
            check("recovery: \(provider) reload retains dirty and offers recovery", waitUntil(8) {
                viewer.docs[id]?.recoveryPending == true && model.codeTabs.first(where: { $0.id == id })?.dirty == true
            })
            for dark in [true, false] {
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                let output = root.appendingPathComponent("recovery-\(provider)-\(dark ? "dark" : "light").png")
                check("snapshot: recovery \(provider) \(dark ? "dark" : "light")", renderFileViewer(viewer.view, to: output))
            }
            try? Data("let agentEdit = true\n".utf8).write(to: file, options: .atomic)
            viewer.restoreRecovery()
            check("recovery: \(provider) restore preserves disk conflict", viewer.docs[id]?.pendingDisk != nil && viewer.docs[id]?.dirty == true)
            var saved = true
            viewer.save(id) { saved = $0 }
            check("recovery: \(provider) unresolved conflict cannot save", !saved && (try? String(contentsOf: file, encoding: .utf8)) == "let agentEdit = true\n")
            viewer.recoveryStore.remove(id)
        }
    }
    static func panelShellSnapshots(_ root: URL) {
        guard let ghostty = GhosttyApp.shared else { check("shell snapshot: Ghostty available", false); return }
        let model = AppModel()
        let project = Project(path: root.path)
        model.projects = [project]
        model.selectedProjectID = project.id
        let checkout = root.appendingPathComponent("worktree")
        Paths.ensure(checkout)
        let terminal = TerminalView(app: ghostty.app, launch: .init(workingDirectory: checkout.path, command: "/bin/cat"), handlesChildExit: false)
        defer { terminal.destroy() }
        let shell = PanelShell(projectID: project.id, terminal: terminal)
        shell.recreated = true
        let host = ChromeHostingView(rootView: ShellTab(shell: shell, selected: true).environmentObject(model).padding(10))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 360, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 80)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        check("shell: label uses actual checkout", shell.checkoutPath == checkout.path)
        for dark in [true, false] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            check("snapshot: shell checkout \(dark ? "dark" : "light")", render(host, to: root.appendingPathComponent("shell-checkout-\(dark ? "dark" : "light").png")))
        }
    }

}
