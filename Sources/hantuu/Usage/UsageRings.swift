import SwiftUI

/// One small ring per agent hantuu can read limits for, side by side at the left of the
/// sidebar footer. Each ring shows how much of the weekly limit is left (a full ring is all
/// of it), and hovering it gives the numbers.
struct UsageRings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var center: UsageCenter
    @ObservedObject var settings = UsageSettings.shared
    @State private var hover = UsageHoverState()
    @State private var pending: DispatchWorkItem?

    init(center: UsageCenter = .shared) { _center = ObservedObject(wrappedValue: center) }

    var sources: [UsageSource] { model.agents.compactMap { UsageSource(agentID: $0.id) } }
    var claudeOff: Bool { !(settings.claudeStatusLine || ClaudeUsage.hasOwnStatusLine()) }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(sources, id: \.self) { s in
                let r = center.reading(for: s)
                let off = s == .claude && claudeOff
                UsageRing(glyph: s.glyph,
                          left: r?.ringWindow?.leftPercent(at: center.now),
                          tooltip: UsageFormat.tooltip(s, r, now: center.now, off: off))
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hover.anchorChanged(inside, at: ProcessInfo.processInfo.systemUptime)
            schedule()
        }
        .popover(isPresented: Binding(get: { hover.isOpen }, set: { open in
            if !open { dismiss() }
        }), arrowEdge: .top) {
            UsageHoverCard(sources: sources, readings: readings, now: center.now, claudeOff: claudeOff)
                .onHover { inside in
                    hover.cardChanged(inside, at: ProcessInfo.processInfo.systemUptime)
                    schedule()
                }
        }
        .accessibilityAction(named: Text("Show usage limits")) {
            pending?.cancel()
            hover.openImmediately()
        }
        .onDisappear { dismiss() }
        .onChange(of: sources) { _, sources in
            if sources.isEmpty { dismiss() }
        }
    }

    private var readings: [UsageSource: UsageReading] {
        sources.reduce(into: [:]) { result, source in
            result[source] = center.reading(for: source)
        }
    }

    private func dismiss() {
        pending?.cancel()
        pending = nil
        hover.dismiss()
    }

    private func schedule() {
        pending?.cancel()
        pending = nil
        guard let next = hover.pending else { return }
        let work = DispatchWorkItem {
            guard !sources.isEmpty else { dismiss(); return }
            hover.fire(at: ProcessInfo.processInfo.systemUptime)
            pending = nil
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, next.deadline - ProcessInfo.processInfo.systemUptime), execute: work)
    }
}

/// Explicit hover state keeps a short crossing between the rings and the card from closing it.
/// The clock is supplied so the same transitions can be checked without sleeping in tests.
struct UsageHoverState {
    struct Transition {
        let open: Bool
        let deadline: TimeInterval
    }

    private(set) var isOpen = false
    private(set) var overAnchor = false
    private(set) var overCard = false
    private(set) var pending: Transition?

    mutating func anchorChanged(_ inside: Bool, at now: TimeInterval) {
        overAnchor = inside
        if inside {
            pending = isOpen ? nil : Transition(open: true, deadline: now + NewChatButton.openDelay)
        } else {
            pending = isOpen ? Transition(open: false, deadline: now + NewChatButton.leaveButtonDelay) : nil
        }
    }

    mutating func cardChanged(_ inside: Bool, at now: TimeInterval) {
        overCard = inside
        pending = inside ? nil : Transition(open: false, deadline: now + NewChatButton.leaveMenuDelay)
    }

    mutating func fire(at now: TimeInterval) {
        guard let next = pending, now >= next.deadline else { return }
        pending = nil
        if next.open {
            if overAnchor { isOpen = true }
        } else if !overAnchor && !overCard {
            isOpen = false
        }
    }

    mutating func openImmediately() {
        pending = nil
        isOpen = true
    }

    mutating func dismiss() {
        pending = nil
        isOpen = false
        overCard = false
        overAnchor = false
    }
}

/// All connected providers share one quiet card, whichever ring the cursor enters.
struct UsageHoverCard: View {
    let sources: [UsageSource]
    let readings: [UsageSource: UsageReading]
    let now: Date
    var claudeOff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sources, id: \.self) { source in
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    let lines = UsageFormat.details(source, readings[source], now: now,
                                                    off: source == .claude && claudeOff)
                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index])
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
    }
}

struct UsageRing: View {
    let glyph: String
    /// 0 to 100, or nil when there's no reading.
    let left: Double?
    let tooltip: String

    /// Outer size: the strokes are inset, so nothing draws outside it.
    static let size: CGFloat = 15
    static let line: CGFloat = 1.5

    var level: UsageLevel { .of(leftPercent: left) }

    var tint: Color {
        switch level {
        case .normal: return .hSecondary
        case .low: return Color(nsColor: Theme.needsYou)
        case .critical: return Color(nsColor: Theme.error)
        case .unknown: return .hTertiary
        }
    }

    var body: some View {
        ZStack {
            if let left {
                Circle().inset(by: Self.line / 2).stroke(Color.hInk(0.12, light: 0.1), lineWidth: Self.line)
                Circle().inset(by: Self.line / 2)
                    .trim(from: 0, to: max(0, min(1, left / 100)))
                    .stroke(tint, style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                // No reading: a dotted outline only.
                Circle().inset(by: 0.5).stroke(Color.hInk(0.22, light: 0.24), style: StrokeStyle(lineWidth: 1, dash: [1.2, 1.9]))
            }
            Text(glyph)
                .font(.system(size: 6.5, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(tint)
                .fixedSize()
        }
        .frame(width: Self.size, height: Self.size)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tooltip)
    }
}

/// Settings > Usage Limits.
struct UsageSettingsSection: View {
    @ObservedObject var settings = UsageSettings.shared

    var body: some View {
        let own = ClaudeUsage.hasOwnStatusLine()
        Section {
            Toggle("Show Claude Code's limits", isOn: Binding(get: { own || settings.claudeStatusLine },
                                                               set: { settings.claudeStatusLine = $0 }))
                .disabled(own)
        } header: { Text("Usage Limits") } footer: {
            Text(own
                 ? "Always on, because you have your own Claude status line. hantuu runs it as before and reads the limits on the way. Codex's limits need nothing."
                 : "Claude Code only shares its plan limits with a status line. With this on, Claude chats you start or resume get one that shows nothing and saves the limits for the rings. Any status line hides Claude's footer hints, like esc to interrupt. Codex's limits need nothing.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
