import AppKit
import Combine
import SwiftUI

/// The toggleable right panel: Overview (glance cards for the chat), Changes (the diff, with
/// line comments for the agent), Files (the project tree), Code (read-only viewer) and Terminal
/// (plain shells in the project folder). The reader isn't here: it replaces the chat's
/// terminal in the main area (Shift-Cmd-R).
final class PanelController: NSViewController {
    private let model: AppModel
    let code: CodeViewerController
    let review: ReviewCenter
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
        code = CodeViewerController(model: model)
        super.init(nibName: nil, bundle: nil)
        review.configure(model: model)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = FillView(color: Theme.chrome)
        header = ChromeHostingView(rootView: PanelHeader().environmentObject(model).environmentObject(review))
        content = FillView(color: Theme.chrome)
        noShells = ChromeHostingView(rootView: NoShellsView().environmentObject(model))
        noFiles = ChromeHostingView(rootView: NoFilesView().environmentObject(model))
        overview = ChromeHostingView(rootView: OverviewView().environmentObject(model).environmentObject(review))
        changes = ChromeHostingView(rootView: ChangesView().environmentObject(model).environmentObject(review))
        files = ChromeHostingView(rootView: FilesView().environmentObject(model).environmentObject(review))
        let views: [NSView] = [shells, code.view, noShells, noFiles, overview, changes, files]
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
        review.setActiveTab(model.panelVisible ? tab : nil)
    }
}

struct PanelHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                WindowDragArea()
                HStack(spacing: 2) {
                    // Five labels fit at the default width; a narrow panel tightens the padding.
                    ViewThatFits(in: .horizontal) {
                        tabs(padding: 8)
                        tabs(padding: 5)
                        tabs(padding: 3)
                    }
                    Spacer(minLength: 0)
                    IconButton(symbol: "sidebar.right", help: "Hide Panel  ⌥⌘0") { model.panelVisible = false }
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
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Color.hSecondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(hovering || selected ? 1 : 0)
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
        SubTab(title: shell.title, selected: selected, help: model.project(shell.projectID)?.path ?? "",
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
            ScrollView(.horizontal) {
                HStack(spacing: 3) {
                    ForEach(model.codeTabs) { t in
                        SubTab(title: t.name, selected: t.id == model.selectedCodeTabID, help: t.path,
                               select: { model.selectedCodeTabID = t.id },
                               close: { model.closeCodeTab(t.id) })
                    }
                }
            }
            .scrollIndicators(.never)
            if let id = model.selectedCodeTabID, let tab = model.codeTabs.first(where: { $0.id == id }) {
                if tab.isMarkdown {
                    HStack(spacing: 0) {
                        ModeButton(title: "Source", selected: !tab.preview) { model.setPreview(id, false) }
                        ModeButton(title: "Preview", selected: tab.preview) { model.setPreview(id, true) }
                    }
                }
                IconButton(symbol: "arrow.up.forward.square", size: 12, help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tab.path)])
                }
            }
        }
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
