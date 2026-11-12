import SwiftUI

extension Theme {
    /// Done, unseen: the one blue in the app, close to the system accent in dark mode.
    static let doneUnseen = NSColor(hex: 0x4A8FEF)
}

/// The dot beside a chat. Working pulses slowly; the rest are still.
struct ActivityDot: View {
    let activity: AgentActivity
    /// A fixed point in the pulse, for offscreen snapshots (animations don't render there).
    var pulsePhase: Double? = ActivityDot.fixedPhase
    static var fixedPhase: Double?
    /// Running in background pulses like Working when true. Only the snapshots compare both.
    static var backgroundPulses = false

    var body: some View {
        ZStack {
            switch activity {
            case .working:
                PulseRing(color: Color(nsColor: Theme.running), phase: pulsePhase)
                Circle().fill(Color(nsColor: Theme.running)).frame(width: 7, height: 7)
            case .background:
                // Still going, but nothing for the main agent to do: the working dot without its pulse.
                if ActivityDot.backgroundPulses { PulseRing(color: Color(nsColor: Theme.running), phase: pulsePhase) }
                Circle().fill(Color(nsColor: Theme.running)).frame(width: 7, height: 7)
            case .needsPermission, .needsAnswer:
                Circle().fill(Color(nsColor: Theme.needsYou)).frame(width: 7, height: 7)
            case .doneUnseen:
                Circle().fill(Color(nsColor: Theme.doneUnseen)).frame(width: 7, height: 7)
            case .idle:
                Circle().stroke(Color(nsColor: Theme.secondary), lineWidth: 1.1).frame(width: 7, height: 7)
            case .ended:
                Circle().stroke(Color(nsColor: Theme.ended).opacity(0.55), lineWidth: 1).frame(width: 7, height: 7)
            }
        }
        .frame(width: 12, height: 12)
        .help(activity.label)
    }
}

/// A thin ring that grows out of the Working dot and fades, every two seconds.
struct PulseRing: View {
    let color: Color
    var phase: Double? = nil
    @State private var animating = false

    var body: some View {
        let p = phase ?? (animating ? 1 : 0)
        Circle()
            .stroke(color, lineWidth: 0.8)
            .frame(width: 7, height: 7)
            .scaleEffect(1 + 0.85 * p)
            .opacity(0.7 * (1 - p))
            .onAppear {
                guard phase == nil else { return }
                withAnimation(.easeOut(duration: 2.0).repeatForever(autoreverses: false)) { animating = true }
            }
    }
}

/// The grey line under a chat title: what the agent is doing, or when it finished.
struct ActivityDetailText: View {
    @ObservedObject var chat: Chat
    var now: Date? = nil

    var body: some View {
        if chat.activityDetail.isEmpty, chat.activity != .ended, let done = chat.lastTurnEndedAt {
            // Refreshes on its own so "Done 2m ago" stays true.
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                line(StatusText.done(at: done, now: now ?? ctx.date))
            }
        } else {
            line(chat.activityDetail.isEmpty ? chat.agent.name : chat.activityDetail)
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(chat.activity.isNeeds ? Color.hSecondary : Color.hTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(chat.agent.name + "  " + text)
    }
}

/// "2 need you" in the sidebar header. Opens a compact list; picking a row selects the chat.
struct NeedsYouButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var status = StatusCenter.shared
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let ids = status.attention
        if !ids.isEmpty {
            let needs = ids.contains { id in model.chats.first { $0.id == id }?.activity.isNeeds == true }
            let dot = Color(nsColor: needs ? Theme.needsYou : Theme.doneUnseen)
            Button { open.toggle() } label: {
                ViewThatFits(in: .horizontal) {
                    label(dot: dot, text: "Attention \(ids.count)")
                    label(dot: dot, text: "\(ids.count)")
                }
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Chats needing input or review  ⌘J jumps to the next one")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                NeedsYouList { open = false }
                    .environmentObject(model)
            }
        }
    }

    private func label(dot: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(hovering || open ? Color.hText : Color.hSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering || open ? Color.hHover : .clear))
        .contentShape(Rectangle())
    }
}

/// The list behind "2 need you": oldest first, Needs states before finished turns.
struct NeedsYouList: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var status = StatusCenter.shared
    var now: Date? = nil
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Attention")
                .font(.system(size: 11))
                .foregroundStyle(Color.hTertiary)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(status.attention, id: \.self) { id in
                if let chat = model.chats.first(where: { $0.id == id }) {
                    NeedsYouRow(chat: chat, project: model.project(chat.projectID)?.name, now: now) {
                        done()
                        model.select(chat.id)
                    }
                }
            }
            Text("⌘J jumps to the next one")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.hTertiary)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 6)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(width: 300)
    }
}

struct NeedsYouRow: View {
    @ObservedObject var chat: Chat
    let project: String?
    var now: Date? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                ActivityDot(activity: chat.activity).padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(chat.displayTitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.hText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        if let project {
                            Text(project)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.hTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(-1)
                        }
                    }
                    ActivityDetailText(chat: chat, now: now)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.hSelection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The Notifications section of Settings.
struct NotificationSettingsSection: View {
    @ObservedObject var settings = StatusCenter.shared.settings

    var body: some View {
        Section {
            Toggle("Notify me when a chat needs me", isOn: $settings.notificationsEnabled)
            Toggle("Also when a chat finishes", isOn: $settings.notifyWhenDone)
                .disabled(!settings.notificationsEnabled)
        } header: { Text("Notifications") } footer: {
            Text("Only for chats you aren't looking at. Permission requests and questions quote what the agent asked. The Dock badge counts chats needing input or review.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
