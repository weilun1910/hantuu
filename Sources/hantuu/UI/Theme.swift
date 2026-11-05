import AppKit
import SwiftUI

/// Neutral, untinted darks. The window matches the terminal background from the user's
/// Ghostty config; the sidebar and panel sit one step lighter. Colour lives in text and accents.
enum Theme {
    static var background: NSColor = NSColor(hex: 0x161616)
    static var chrome: NSColor { background.adjusted(0.035) }
    static let divider = NSColor(white: 1, alpha: 0.075)
    static let text = NSColor(white: 0.90, alpha: 1)
    static let secondary = NSColor(white: 0.58, alpha: 1)
    static let tertiary = NSColor(white: 0.40, alpha: 1)
    static let hover = NSColor(white: 1, alpha: 0.045)
    static let selection = NSColor(white: 1, alpha: 0.085)
    static let running = NSColor(hex: 0x5DBB7E)
    static let needsYou = NSColor(hex: 0xE5A23B)
    static let ended = NSColor(white: 0.42, alpha: 1)
    static let error = NSColor(hex: 0xE06C6C)

    static func configure(from ghostty: GhosttyApp?) {
        if let g = ghostty { background = g.backgroundColor.usingColorSpace(.sRGB) ?? background }
    }
}

extension Color {
    static var hBackground: Color { Color(nsColor: Theme.background) }
    static var hChrome: Color { Color(nsColor: Theme.chrome) }
    static var hDivider: Color { Color(nsColor: Theme.divider) }
    static var hText: Color { Color(nsColor: Theme.text) }
    static var hSecondary: Color { Color(nsColor: Theme.secondary) }
    static var hTertiary: Color { Color(nsColor: Theme.tertiary) }
    static var hHover: Color { Color(nsColor: Theme.hover) }
    static var hSelection: Color { Color(nsColor: Theme.selection) }
}

/// A plain icon button: SF Symbol, no bezel, a faint square highlight on hover.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 13
    var help: String = ""
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(active ? Color.hText : (hovering ? Color.hText : Color.hSecondary))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.hHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct StatusDot: View {
    let status: ChatStatus
    var body: some View {
        switch status {
        case .running:
            Circle().fill(Color(nsColor: Theme.running)).frame(width: 7, height: 7)
        case .needsYou:
            Circle().fill(Color(nsColor: Theme.needsYou)).frame(width: 7, height: 7)
                .overlay(Circle().stroke(Color(nsColor: Theme.needsYou).opacity(0.35), lineWidth: 3).frame(width: 11, height: 11))
        case .ended:
            Circle().stroke(Color(nsColor: Theme.ended), lineWidth: 1.2).frame(width: 7, height: 7)
        }
    }
}

extension ChatStatus {
    var label: String {
        switch self {
        case .running: return "Running"
        case .needsYou: return "Needs you"
        case .ended: return "Ended"
        }
    }
}

/// Lets an empty strip of SwiftUI chrome drag the window (the titlebar is hidden).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

/// NSHostingView that never takes first responder from the terminal by accident.
/// Its size comes from Auto Layout constraints, not from the SwiftUI content (otherwise an
/// empty view's zero size would squeeze the whole window), and it ignores the titlebar's
/// safe area so chrome lines up with the traffic lights.
final class ChromeHostingView<Content: View>: NSHostingView<AnyView> {
    init(rootView: Content) {
        super.init(rootView: AnyView(rootView.ignoresSafeArea()))
        sizingOptions = []
    }
    @MainActor required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
    }
    @MainActor required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { false }
}
