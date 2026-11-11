import SwiftUI

/// One small ring per agent hantuu can read limits for, side by side at the left of the
/// sidebar footer. Each ring shows how much of the weekly limit is left (a full ring is all
/// of it), and hovering it gives the numbers.
struct UsageRings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var center: UsageCenter
    @ObservedObject var settings = UsageSettings.shared

    init(center: UsageCenter = .shared) { _center = ObservedObject(wrappedValue: center) }

    var sources: [UsageSource] { model.agents.compactMap { UsageSource(agentID: $0.id) } }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(sources, id: \.self) { s in
                let r = center.reading(for: s)
                let off = s == .claude && !(settings.claudeStatusLine || ClaudeUsage.hasOwnStatusLine())
                UsageRing(glyph: s.glyph,
                          left: r?.ringWindow?.leftPercent(at: center.now),
                          tooltip: UsageFormat.tooltip(s, r, now: center.now, off: off))
            }
        }
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
        .help(tooltip)
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
