import AppKit
import Combine

/// Preferences describe the user's split. The result describes only this window size.
enum WindowLayout {
    static let readerMinimum: CGFloat = 380
    static let readerComfortable: CGFloat = 440
    static let readerTargets: [CGFloat] = [440, 560, 720]
    static let terminalTargets = [80, 96, 120]
    static let restoreHysteresis: CGFloat = 64

    struct Input {
        var width: CGFloat
        var reader: Bool
        var terminalMinimum: CGFloat
        var sidebarWanted = true
        var panelWanted = true
        var sidebarPreference: CGFloat = 248
        var panelPreference: CGFloat = 560
        var chatPreference: CGFloat? = nil
        var panelMinimum: CGFloat = 560
        var sidebarWasAutoHidden = false
        var focus = false
        var showPanelWhenSingle = true
    }

    struct Result: Equatable {
        var sidebar: CGFloat
        var chat: CGFloat
        var panel: CGFloat
        var single = false
        var sidebarAutoHidden = false
    }

    static func resolve(_ input: Input) -> Result {
        let width = max(0, input.width)
        let floor = input.reader ? readerMinimum : input.terminalMinimum
        let comfortable = input.reader ? readerComfortable : floor
        let panelFloor = input.panelWanted ? input.panelMinimum : 0
        let divider: CGFloat = input.panelWanted ? 1 : 0
        var sidebar = input.sidebarWanted && !input.focus ? min(380, max(200, input.sidebarPreference)) : 0
        if sidebar > 0 {
            let preferredPanel = input.panelWanted ? max(panelFloor, input.panelPreference) : 0
            let room = width - comfortable - preferredPanel - divider - 1
            if room < 200 || (input.sidebarWasAutoHidden && room < 200 + restoreHysteresis) {
                sidebar = 0
            } else {
                sidebar = min(sidebar, room)
            }
        }
        let autoHidden = input.sidebarWanted && sidebar == 0
        let available = max(0, width - sidebar - (sidebar > 0 ? 1 : 0))
        guard input.panelWanted else {
            return Result(sidebar: sidebar, chat: available, panel: 0, sidebarAutoHidden: autoHidden)
        }
        if available < floor + panelFloor + 1 {
            return Result(sidebar: 0, chat: input.showPanelWhenSingle ? 0 : width,
                          panel: input.showPanelWhenSingle ? width : 0, single: true,
                          sidebarAutoHidden: input.sidebarWanted)
        }
        let desiredPanel: CGFloat
        if input.focus {
            desiredPanel = width * 2 / 3
        } else if let preferredChat = input.chatPreference {
            desiredPanel = available - max(floor, preferredChat) - 1
        } else {
            desiredPanel = input.panelPreference
        }
        let panel = min(max(panelFloor, desiredPanel), available - floor - 1)
        return Result(sidebar: sidebar, chat: available - panel - 1, panel: panel,
                      sidebarAutoHidden: autoHidden)
    }

    static func minimumWidth(reader: Bool, terminalMinimum: CGFloat, panelWanted: Bool, panelMinimum: CGFloat) -> CGFloat {
        max(reader ? readerMinimum : terminalMinimum, panelWanted ? panelMinimum : 0)
    }

    static func panelMinimum(for tab: PanelTab) -> CGFloat {
        switch tab {
        case .overview, .files: return 360
        default: return 560
        }
    }

    /// A small magnetic zone leaves ordinary free resizing intact. Option bypasses it.
    static func detent(_ width: CGFloat, targets: [CGFloat], bypass: Bool = false) -> CGFloat {
        guard !bypass, let nearest = targets.min(by: { abs($0 - width) < abs($1 - width) }),
              abs(nearest - width) <= 6 else { return width }
        return nearest
    }
}

/// Transient state is deliberately excluded from SavedState.
final class WindowLayoutState: ObservableObject {
    enum Request { case focus, chat, panel, navigation, preset(Int), reset }
    let requests = PassthroughSubject<Request, Never>()
    @Published var sidebarAutoHidden = false
    @Published var focused = false
    @Published var single = false
    @Published var showingPanel = false
}
