import AppKit
import Combine
import SwiftUI

/// The toggleable right panel: Overview (glance cards for the chat), Changes (the diff, with
/// line comments for the agent), Files (the project tree), Code (any file: an editor for text,
/// native viewers for the rest), Browser (a project preview) and Terminal
/// (plain shells in the project folder). The reader isn't here: it replaces the chat's
/// terminal in the main area (Shift-Cmd-R).
final class PanelController: NSViewController {
    private let model: AppModel
    let code: FileViewerController
    let review: ReviewCenter
    let browser: BrowserCoordinator
    private var browserView: NSView!
    let side: SidePanelController
    private let shells = TerminalContainer(color: Theme.background)
    private var header: NSView!
    private var noShells: NSView!
    private var noFiles: NSView!
    private var overview: NSView!
    private var changes: NSView!
    private var files: NSView!
    private var content: FillView!
    private var bag = Set<AnyCancellable>()

    init(model: AppModel, review: ReviewCenter = .shared) {
        self.model = model
        self.review = review
        browser = BrowserCoordinator(model: model, review: review)
        code = FileViewerController(model: model)
        side = SidePanelController(model: model)
        super.init(nibName: nil, bundle: nil)
        review.configure(model: model)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = FillView(color: Theme.chrome)
        header = ChromeHostingView(rootView: PanelHeader(layout: model.layoutState).environmentObject(model).environmentObject(review).environmentObject(browser))
        content = FillView(color: Theme.chrome)
        noShells = ChromeHostingView(rootView: NoShellsView().environmentObject(model))
        noFiles = ChromeHostingView(rootView: NoFilesView().environmentObject(model))
        overview = ChromeHostingView(rootView: OverviewView().environmentObject(model).environmentObject(review))
        changes = ChromeHostingView(rootView: ChangesView().environmentObject(model).environmentObject(review))
        files = ChromeHostingView(rootView: FilesView().environmentObject(model).environmentObject(review))
        browserView = ChromeHostingView(rootView: BrowserPanel(browser: browser))
        let views: [NSView] = [shells, code.view, noShells, noFiles, overview, changes, files, browserView, side.root]
        for v in [header!, content!] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: content.topAnchor),
                v.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 73),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.sync() }.store(in: &bag)
        model.$panelTab.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.sync() }.store(in: &bag)
        sync()
    }

    func sync() {
        let tab = model.panelTab
        let projectID = model.currentProject?.id
        let list = model.shells(in: projectID)
        let selected = list.first(where: { $0.id == model.selectedShellID[projectID ?? UUID()] }) ?? list.last
        // Shells of every project stay alive; only the current project's selected one shows.
        shells.show(model.shells.map(\.terminal), visible: tab == .terminal ? selected?.terminal : nil)
        shells.isHidden = tab != .terminal
        noShells.isHidden = !(tab == .terminal && list.isEmpty)
        code.view.isHidden = tab != .code
        noFiles.isHidden = !(tab == .code && model.codeTabs.isEmpty)
        overview.isHidden = tab != .overview
        changes.isHidden = tab != .changes
        files.isHidden = tab != .files
        browserView.isHidden = tab != .browser
        browser.sync(visible: model.panelVisible && tab == .browser)
        side.root.isHidden = tab != .side
        side.sync(active: model.panelVisible && tab == .side)
        review.setActiveTab(model.panelVisible ? tab : nil)
    }
}

struct PanelHeader: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var layout: WindowLayoutState = AppModel.shared.layoutState

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                WindowDragArea()
                // Narrow panels use icons, so additional tabs never overflow the header.
                HStack(spacing: 4) {
                    if layout.single && layout.showingPanel {
                        Spacer().frame(width: 66)
                        IconButton(symbol: "sidebar.left", help: "Browse Projects  ⌘0") { layout.requests.send(.navigation) }
                        Button {
                            layout.requests.send(.chat)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Chat")
                                if model.chats.contains(where: { $0.activity.isNeeds }) {
                                    Image(systemName: "circle.fill").font(.system(size: 6))
                                }
                            }
                        }
                        .buttonStyle(.plain).font(.system(size: 12))
                        .help("Back to chat. Agents keep running while the panel is focused.")
                    }
                    ViewThatFits(in: .horizontal) {
                        tabs(padding: 8)
                        tabs(padding: 3)
                        iconTabs
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    IconButton(symbol: layout.focused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               help: layout.focused ? "Restore Split  ⌃⌥⌘F" : "Expand Panel  ⌃⌥⌘F",
                               active: layout.focused) { layout.requests.send(.focus) }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 40)
            Rectangle().fill(Color.hDivider).frame(height: 1)
            Group {
                switch model.panelTab {
                case .overview: OverviewBar()
                case .changes: ChangesBar()
                case .files: FilesBar()
                case .terminal: ShellTabs()
                case .code: CodeTabs()
                case .browser: BrowserBar()
                case .side:
                    HStack {
                        Text(model.selectedChat?.displayTitle ?? "Side questions")
                            .font(.system(size: 12)).foregroundStyle(Color.hSecondary).lineLimit(1)
                        Spacer()
                    }
                }
            }
            .frame(height: 31)
            .padding(.horizontal, 8)
            Rectangle().fill(Color.hDivider).frame(height: 1)
        }
        .background(Color.hChrome)
    }

    private func tabs(padding: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(PanelTab.allCases.enumerated()), id: \.element) { i, tab in
                PanelTabButton(title: tab.rawValue, selected: model.panelTab == tab, padding: padding) { model.panelTab = tab }
                    .help("\(tab.rawValue)  ⌥⌘\(i + 1)")
            }
        }
        .fixedSize()
    }

    private var iconTabs: some View {
        HStack(spacing: 4) {
            ForEach(Array(PanelTab.allCases.enumerated()), id: \.element) { i, tab in
                Button { model.panelTab = tab } label: {
                    VStack(spacing: 6) {
                        Image(systemName: Self.symbol(tab.rawValue)).font(.system(size: 12))
                            .frame(width: 28, height: 17)
                        Rectangle().fill(model.panelTab == tab ? Color.hText.opacity(0.85) : .clear).frame(height: 1.5)
                    }
                    .foregroundStyle(model.panelTab == tab ? Color.hText : Color.hSecondary)
                    .padding(.top, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(tab.rawValue)  ⌥⌘\(i + 1)")
                .accessibilityLabel(tab.rawValue)
            }
        }
        .fixedSize()
    }

    private static func symbol(_ title: String) -> String {
        switch title {
        case "Overview": return "square.grid.2x2"
        case "Changes": return "plus.forwardslash.minus"
        case "Files": return "folder"
        case "Code": return "doc.text"
        case "Browser": return "globe"
        case "Side": return "bubble.left.and.bubble.right"
        default: return "terminal"
        }
    }
}

struct PanelTabButton: View {
    let title: String
    let selected: Bool
    var padding: CGFloat = 8
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                // The label reserves its medium-weight width so selecting a tab doesn't shift the row.
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .hidden()
                    .overlay(
                        Text(title)
                            .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                            .foregroundStyle(selected ? Color.hText : (hovering ? Color.hText.opacity(0.8) : Color.hSecondary))
                    )
                Rectangle().fill(selected ? Color.hText.opacity(0.85) : .clear).frame(height: 1.5)
            }
            .padding(.horizontal, padding)
            .padding(.top, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A small text tab with a close button that appears on hover.
struct SubTab: View {
    let title: String
    let selected: Bool
    let help: String
    /// Unsaved changes: a small dot where the close button goes, until you hover.
    var dirty = false
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(selected ? Color.hText : Color.hSecondary)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
            ZStack {
                if dirty && !hovering {
                    Circle().fill(Color.hSecondary).frame(width: 6, height: 6)
                        .accessibilityLabel("Unsaved changes")
                } else {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Color.hSecondary)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering || selected ? 1 : 0)
                    .accessibilityLabel("Close \(title)")
                }
            }
            .frame(width: 14, height: 14)
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(height: 23)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.hSelection : (hovering ? Color.hHover : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct ShellTabs: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let pid = model.currentProject?.id
        let list = model.shells(in: pid)
        let sel = model.selectedShellID[pid ?? UUID()] ?? list.last?.id
        HStack(spacing: 3) {
            ScrollView(.horizontal) {
                HStack(spacing: 3) {
                    ForEach(list) { s in
                        ShellTab(shell: s, selected: s.id == sel)
                    }
                }
            }
            .scrollIndicators(.never)
            IconButton(symbol: "plus", size: 12, help: "New Terminal  ⌘T") { model.newTerminalTab() }
        }
    }
}

struct ShellTab: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var shell: PanelShell
    let selected: Bool

    var body: some View {
        SubTab(title: shell.title + " | " + FileViewerController.abbreviate(shell.checkoutPath) + (shell.recreated ? " | Recreated" : ""), selected: selected, help: shell.checkoutPath + (shell.recreated ? "\nRecreated shell. Previous commands and scrollback were not resumed." : ""),
               select: {
                   model.selectedShellID[shell.projectID] = shell.id
                   model.focusRequest.send(shell.terminal)
               },
               close: { model.closeShell(shell) })
    }
}

struct CodeTabs: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(model.codeTabs) { t in
                            SubTab(title: t.name, selected: t.id == model.selectedCodeTabID,
                                   help: t.dirty ? "\(t.path)\nUnsaved changes" : t.path, dirty: t.dirty,
                                   select: { model.selectedCodeTabID = t.id },
                                   close: { model.closeCodeTab(t.id) })
                                .id(t.id)
                        }
                    }
                }
                .scrollIndicators(.never)
                // A file opened from a link may land past the edge: bring its tab into view.
                .onChange(of: model.selectedCodeTabID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            if let id = model.selectedCodeTabID, let tab = model.codeTabs.first(where: { $0.id == id }) {
                if tab.kind.hasPreview {
                    HStack(spacing: 0) {
                        ModeButton(title: "Source", selected: !tab.preview) { model.setPreview(id, false) }
                        ModeButton(title: "Preview", selected: tab.preview) { model.setPreview(id, true) }
                    }
                }
                FileMenuButton(tab: tab)
            }
        }
    }
}

/// The tab's file: Save, Open With, Reveal in Finder and Copy Path.
struct FileMenuButton: View {
    @EnvironmentObject var model: AppModel
    let tab: CodeTab

    var body: some View {
        Menu {
            if tab.kind.isEditable {
                Button("Save") { model.fileViewer?.saveSelected() }
                    .disabled(!(model.fileViewer?.canSaveSelected ?? false))
                Divider()
            }
            Button("Open in New Window") { model.fileViewer?.openInNewWindow() }
            Divider()
            if let app = FileKinds.defaultApp(for: tab.path) {
                Button("Open with \(app.name)") { FileViewerActions.openWithDefaultApp(tab.path) }
            }
            Button("Reveal in Finder") { FileViewerActions.revealInFinder(tab.path) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.path, forType: .string)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.hSecondary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Open With, Reveal in Finder and more")
    }
}

struct ModeButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.hText : Color.hTertiary)
                .padding(.horizontal, 7)
                .frame(height: 21)
                .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.hSelection : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ReaderBarTitle: View {
    @ObservedObject var chat: Chat
    var body: some View {
        HStack(spacing: 7) {
            ActivityDot(activity: chat.activity)
            Text(chat.displayTitle).font(.system(size: 12)).foregroundStyle(Color.hText).lineLimit(1)
            if chat.follower != nil && chat.status != .ended {
                Text("Live").font(.system(size: 11)).foregroundStyle(Color.hTertiary)
            }
        }
    }
}

struct NoShellsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            Text("No terminals in \(model.currentProject?.name ?? "this project")")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.hTertiary)
            Button("New Terminal  ⌘T") { model.newTerminalTab() }
                .buttonStyle(BarButtonStyle(prominent: true))
                .disabled(model.currentProject == nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.hChrome)
    }
}

struct NoFilesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            Text("No files open")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.hTertiary)
            Text("File links in a chat or the reader open here.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.hTertiary.opacity(0.8))
            Button("Open File…  ⌘O") { model.openFileWithPanel() }
                .buttonStyle(BarButtonStyle(prominent: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.hChrome)
    }
}
