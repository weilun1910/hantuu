import AppKit
import SwiftUI
import WebKit

/// The address bar occupies the same header row as Code's document tabs. Secondary actions
/// live above the page so the address field stays usable at the minimum panel width.
struct BrowserBar: View {
    @EnvironmentObject var browser: BrowserCoordinator
    var body: some View {
        if let session = browser.active {
            BrowserAddressBar(session: session, ports: browser.ports).disabled(session.clearingData)
        } else {
            HStack { Text("Browser").font(.system(size: 12)).foregroundStyle(Color.hSecondary); Spacer() }
        }
    }
}

struct BrowserAddressBar: View {
    @ObservedObject var session: BrowserSession
    let ports: [ListeningPort]
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "chevron.left", size: 11, help: "Back") { session.move(-1) }.disabled(!session.history.canBack)
            IconButton(symbol: "chevron.right", size: 11, help: "Forward") { session.move(1) }.disabled(!session.history.canForward)
            IconButton(symbol: session.loading ? "xmark" : "arrow.clockwise", size: 11, help: session.loading ? "Stop loading" : "Reload") { session.reloadOrStop() }
            TextField("Address or port", text: $draft)
                .font(.system(size: 12)).textFieldStyle(.plain)
                .focused($editing)
                .onSubmit { editing = false; session.navigate(draft) }
                .onAppear { draft = session.address }
                .onChange(of: session.address) { _, value in if !editing { draft = value } }
                .onChange(of: editing) { _, value in if !value { draft = session.address } }
                .accessibilityLabel("Browser address")
            Menu {
                if ports.isEmpty { Text("No local servers detected") }
                ForEach(ports) { server in
                    Button("\(server.port)  \(server.command)") { session.navigate("http://localhost:\(server.port)") }
                }
            } label: { Image(systemName: "chevron.down").font(.system(size: 9)).frame(width: 18, height: 22) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Detected local servers")
        }
    }
}

struct BrowserPanel: View {
    @ObservedObject var browser: BrowserCoordinator
    var body: some View {
        Group {
            if let session = browser.active { BrowserPageView(browser: browser, session: session).id(session.projectID) }
            else { BrowserEmptyView() }
        }
        .background(Color.hChrome)
    }
}

struct BrowserEmptyView: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Nothing is running yet").font(.system(size: 12.5)).foregroundStyle(Color.hSecondary)
            Text("Start a local server in your chat, or type an address above.")
                .font(.system(size: 11.5)).foregroundStyle(Color.hTertiary).multilineTextAlignment(.center)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BrowserPageView: View {
    @ObservedObject var browser: BrowserCoordinator
    @ObservedObject var session: BrowserSession
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                IconButton(symbol: "camera", size: 12, help: "Add screenshot to chat without sending") { browser.sendScreenshot(session) }
                    .disabled(!session.hasPage || session.loading || session.error != nil || !browser.canCompose)
                IconButton(symbol: "cursorarrow.rays", size: 12, help: "Select an element. Esc cancels.") { session.setPicking(!session.picking) }
                    .background(session.picking ? Color.hSelection : .clear)
                    .disabled(!session.hasPage || session.loading || session.error != nil || !browser.canCompose)
                if session.picking { Text("Select an element").font(.system(size: 11)).foregroundStyle(Color.hSecondary).lineLimit(1) }
                Spacer(minLength: 0)
                IconButton(symbol: "safari", size: 12, help: "Open in Default Browser") {
                    if let url = URL(string: session.address), BrowserAddress.allowed(url) { NSWorkspace.shared.open(url) }
                }.disabled(!session.hasPage)
                Menu {
                    Button("Clear Browsing Data") { session.clearBrowsingData() }
                    Button("Show Web Inspector") { session.showInspector() }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Browser options")
            }
            .padding(.horizontal, 8).frame(height: 31).disabled(session.clearingData)
            GeometryReader { geometry in
                Rectangle().fill(session.loading ? Color.accentColor : Color.clear)
                    .frame(width: geometry.size.width * max(0.04, session.progress))
            }.frame(height: 1).background(Color.hDivider)
            if let notice = session.notice {
                HStack(alignment: .top, spacing: 6) {
                    Text(notice).font(.system(size: 11)).foregroundStyle(Color.hSecondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    IconButton(symbol: "xmark", size: 9, help: "Dismiss") { session.notice = nil }
                }.padding(.horizontal, 10).padding(.vertical, 5)
            }
            ZStack {
                BrowserWebView(webView: session.webView)
                    .opacity(session.hasPage && session.error == nil ? 1 : 0)
                if session.clearingData {
                    Text("Clearing browsing data").font(.system(size: 12)).foregroundStyle(Color.hSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.hChrome)
                } else if let error = session.error {
                    VStack(spacing: 12) {
                        Text(error).font(.system(size: 12.5)).foregroundStyle(Color.hSecondary).multilineTextAlignment(.center)
                        Button("Retry") { session.reloadOrStop() }.buttonStyle(BarButtonStyle(prominent: true))
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.hChrome)
                } else if !session.hasPage { BrowserEmptyView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Color.hDivider).frame(height: 1)
            HStack(spacing: 6) {
                Button { session.logsOpen.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: session.logsOpen ? "chevron.down" : "chevron.right").font(.system(size: 9))
                        Text("Page logs").font(.system(size: 11.5))
                        let errors = session.logs.entries.filter { $0.level == "error" }.count
                        if errors > 0 { Text("\(errors)").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.red).accessibilityLabel("\(errors) errors") }
                    }
                }.buttonStyle(.plain)
                Spacer()
                if session.logsOpen {
                    Button("Clear") { session.clearLogs() }.buttonStyle(.plain)
                    Button("Send to chat") { browser.sendLogs(session) }.buttonStyle(.plain)
                        .disabled(session.logs.entries.isEmpty || !browser.canCompose)
                }
            }.font(.system(size: 11)).foregroundStyle(Color.hSecondary).padding(.horizontal, 10).frame(height: 28)
            if session.logsOpen { BrowserLogsView(session: session).frame(height: 185) }
        }
    }
}

struct BrowserLogsView: View {
    @ObservedObject var session: BrowserSession
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Page console and errors, not network traffic. Select rows or send all.")
                .font(.system(size: 10.5)).foregroundStyle(Color.hTertiary).padding(.horizontal, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(session.logs.entries) { entry in
                        Button {
                            if !session.selectedLogs.insert(entry.id).inserted { session.selectedLogs.remove(entry.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Text(entry.level).frame(width: 34, alignment: .leading)
                                    .foregroundStyle(entry.level == "error" ? Color.red : Color.hTertiary)
                                Text(entry.text).foregroundStyle(Color.hSecondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.system(size: 10.5, design: .monospaced)).padding(.horizontal, 10).padding(.vertical, 4)
                                .background(session.selectedLogs.contains(entry.id) ? Color.hSelection : .clear)
                        }.buttonStyle(.plain).help(entry.url)
                    }
                }
            }
        }.padding(.bottom, 4)
    }
}

struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        attach(to: host)
        return host
    }
    func updateNSView(_ host: NSView, context: Context) { attach(to: host) }
    private func attach(to host: NSView) {
        guard webView.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: host.leadingAnchor), webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            webView.topAnchor.constraint(equalTo: host.topAnchor), webView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }
}
