import AppKit

// Temporary proof harness: one window, one Ghostty surface running the login shell.
final class ProofEvents: TerminalEvents {
    func terminalTitleDidChange(_ view: TerminalView, title: String) { Log.write("title: \(title)") }
    func terminalNeedsAttention(_ view: TerminalView, reason: String) { Log.write("attention: \(reason)") }
    func terminalChildDidExit(_ view: TerminalView, code: Int) { Log.write("exit: \(code)") }
    func terminalRequestedClose(_ view: TerminalView, processAlive: Bool) { Log.write("close alive=\(processAlive)") }
    func terminalFocusDidChange(_ view: TerminalView, focused: Bool) {}
}

enum FileRouter {
    static let shared = Router()
    final class Router { func openFromTerminal(_ s: String, isOSC8: Bool, base: String?) { Log.write("route \(s)") } }
}
enum AppActions {
    static let shared = Actions()
    final class Actions {
        func newTerminalTab() {}
        func newChat(agentID: String?, projectID: UUID?) {}
        func selectChat(index: Int) {}
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let events = ProofEvents()
var window: NSWindow!
var term: TerminalView!
DispatchQueue.main.async {
    guard let g = GhosttyApp.start() else { print("ghostty failed"); exit(1) }
    window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "hantuu proof"
    let cmd = CommandLine.arguments.last
    term = TerminalView(app: g.app, launch: .init(workingDirectory: NSHomeDirectory(), command: cmd), handlesChildExit: true)
    term.events = events
    term.autoresizingMask = [.width, .height]
    term.frame = window.contentView!.bounds
    window.contentView!.addSubview(term)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(term)
    NSApp.activate()
}
app.run()
