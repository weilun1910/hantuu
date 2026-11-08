import AppKit
import SwiftUI

/// Neutral, untinted colours for light and dark. The window matches the terminal background
/// for the current appearance (read from the Ghostty config); the sidebar and panel sit one
/// step away from it. Colour lives in text and accents. Every colour here is dynamic, so
/// views redraw with the right one when the appearance changes.
enum Theme {
    /// Posted when a terminal background changes for an appearance that's already showing
    /// (the Ghostty config was reloaded), so plain AppKit fills can redraw.
    static let didChange = Notification.Name("hantuu.themeDidChange")

    /// The terminal background for each appearance, from the Ghostty config.
    private(set) static var darkBackground = NSColor(hex: 0x161616)
    private(set) static var lightBackground = NSColor(hex: 0xF7F7F7)

    static let background = NSColor(name: "hantuu.background") { $0.isDark ? darkBackground : lightBackground }
    static let chrome = NSColor(name: "hantuu.chrome") { $0.isDark ? darkBackground.adjusted(0.035) : lightBackground.adjusted(-0.03) }
    /// Cards and bars that sit on the background, like reader mode's banner.
    static let raised = NSColor(name: "hantuu.raised") { $0.isDark ? darkBackground.adjusted(0.06) : NSColor.white }
    static let divider = ink(0.075, light: 0.09)
    static let text = pair(dark: NSColor(white: 0.90, alpha: 1), light: NSColor(white: 0.13, alpha: 1))
    static let secondary = pair(dark: NSColor(white: 0.58, alpha: 1), light: NSColor(white: 0.42, alpha: 1))
    static let tertiary = pair(dark: NSColor(white: 0.40, alpha: 1), light: NSColor(white: 0.62, alpha: 1))
    static let hover = ink(0.045)
    static let selection = ink(0.085, light: 0.07)
    static let running = pair(dark: NSColor(hex: 0x5DBB7E), light: NSColor(hex: 0x3F9E62))
    static let needsYou = pair(dark: NSColor(hex: 0xE5A23B), light: NSColor(hex: 0xC4841A))
    static let ended = pair(dark: NSColor(white: 0.42, alpha: 1), light: NSColor(white: 0.62, alpha: 1))
    static let error = pair(dark: NSColor(hex: 0xE06C6C), light: NSColor(hex: 0xC94A4A))
    static let link = pair(dark: NSColor(hex: 0x8FB4F0), light: NSColor(hex: 0x2F6FD0))

    /// One colour for dark mode and another for light.
    static func pair(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.isDark ? dark : light }
    }

    /// A see-through wash for hovers, fills and outlines: white over dark, black over light.
    /// Black reads stronger than white at the same alpha, so light mode uses a bit less
    /// unless `light` says otherwise.
    static func ink(_ alpha: CGFloat, light: CGFloat? = nil) -> NSColor {
        pair(dark: NSColor(white: 1, alpha: alpha), light: NSColor(white: 0, alpha: light ?? alpha * 0.85))
    }

    /// Store the terminal background Ghostty reports for one appearance.
    static func setTerminalBackground(_ color: NSColor, dark: Bool) {
        let c = color.usingColorSpace(.sRGB) ?? color
        let old = dark ? darkBackground : lightBackground
        guard c.hexString != old.hexString else { return }
        if dark { darkBackground = c } else { lightBackground = c }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Kept for the self tests: makes sure both backgrounds came from the Ghostty config.
    static func configure(from ghostty: GhosttyApp?) {
        ghostty?.captureThemeColors()
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension Color {
    static var hBackground: Color { Color(nsColor: Theme.background) }
    static var hChrome: Color { Color(nsColor: Theme.chrome) }
    static var hRaised: Color { Color(nsColor: Theme.raised) }
    static var hDivider: Color { Color(nsColor: Theme.divider) }
    static var hText: Color { Color(nsColor: Theme.text) }
    static var hSecondary: Color { Color(nsColor: Theme.secondary) }
    static var hTertiary: Color { Color(nsColor: Theme.tertiary) }
    static var hHover: Color { Color(nsColor: Theme.hover) }
    static var hSelection: Color { Color(nsColor: Theme.selection) }
    /// See Theme.ink: white over dark, black over light.
    static func hInk(_ alpha: CGFloat, light: CGFloat? = nil) -> Color { Color(nsColor: Theme.ink(alpha, light: light)) }
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
