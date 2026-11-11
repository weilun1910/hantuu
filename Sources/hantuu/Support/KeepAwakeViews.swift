import SwiftUI

/// What the footer, its tooltip and Settings say about Keep awake.
struct KeepAwakeText: Equatable {
    /// The small line under "Keep awake". nil shows the label alone.
    var detail: String?
    var tooltip: String
    /// The Status row in Settings.
    var settingsLine: String
    /// hantuu's own session is on: the label takes the accent colour.
    var lit = false
    /// The detail is a problem.
    var warning = false
}

extension KeepAwake {
    /// Everything the text depends on, so the self test can check each case directly.
    struct Facts {
        var session: KeepAwakeSession?
        var sleepDisabled: Bool?
        var settingRead: Bool
        var stuck: Bool
        var busy: KeepAwakeBusy?
        var lastEnd: KeepAwakeEnd?
        var problem: (short: String, long: String)?
        var power: PowerState
        var idleMinutes: Int
        var sessionHours: Int
        var batteryPercent: Int
        var now: Date
    }

    var facts: Facts {
        Facts(session: session, sleepDisabled: sleepDisabled, settingRead: settingRead, stuck: stuck, busy: busy,
              lastEnd: lastEnd, problem: problem, power: env.disabled ? power : env.power(),
              idleMinutes: settings.idleMinutes, sessionHours: settings.sessionHours, batteryPercent: settings.batteryPercent,
              now: env.now())
    }

    func statusText() -> KeepAwakeText { Self.text(facts, time: env.time) }

    static func hours(_ n: Int) -> String { n == 1 ? "1 hour" : "\(n) hours" }

    static func text(_ f: Facts, time: (Date) -> String) -> KeepAwakeText {
        if let b = f.busy {
            switch b {
            case .turningOn: return KeepAwakeText(detail: "Waiting for password", tooltip: "Waiting for your password in the macOS prompt.", settingsLine: "Waiting for your password")
            case .turningOff: return KeepAwakeText(detail: "Switching off", tooltip: "Turning sleep back on.", settingsLine: "Switching off")
            case .removing: return KeepAwakeText(detail: "Removing permission", tooltip: "Removing the keep-awake permission.", settingsLine: "Removing the permission")
            }
        }
        if let s = f.session {
            let ends = time(s.endsAt)
            if f.stuck {
                if f.sleepDisabled == nil {
                    return KeepAwakeText(detail: "Status unavailable",
                                         tooltip: "Status unavailable: hantuu switched Keep awake off but couldn't read the Mac's sleep setting back. It checks again every minute.",
                                         settingsLine: "Status unavailable", lit: true, warning: true)
                }
                return KeepAwakeText(detail: "Couldn't switch off",
                                     tooltip: f.problem?.long ?? "Keep awake is still on: hantuu couldn't turn sleep back on. It tries again every minute.",
                                     settingsLine: "Still on: hantuu couldn't turn sleep back on", lit: true, warning: true)
            }
            if f.sleepDisabled == nil {
                return KeepAwakeText(detail: "Status unavailable",
                                     tooltip: "Status unavailable: hantuu couldn't read the Mac's sleep setting. Its limits still apply, and the session ends at \(ends).",
                                     settingsLine: "Status unavailable, ends \(ends)", lit: true, warning: true)
            }
            let source = f.power.onBattery ? "on battery, stops below \(f.batteryPercent)%" : "on power"
            let also = f.power.onBattery
                ? "It also stops after \(f.idleMinutes) minutes with no agent working, if the Mac gets too warm, or when you quit hantuu."
                : "It also stops after \(f.idleMinutes) minutes with no agent working, below \(f.batteryPercent)% battery once unplugged, if the Mac gets too warm, or when you quit hantuu."
            return KeepAwakeText(detail: "Until \(ends)",
                                 tooltip: "Keep awake on, ends \(ends) (\(source)). \(also) Right-click to add an hour.",
                                 settingsLine: "On until \(ends)", lit: true)
        }
        if f.sleepDisabled == true {
            return KeepAwakeText(detail: "Set by another app",
                                 tooltip: "On, set by another app (or an older hantuu). Sleep is off for the whole Mac, and hantuu won't switch it off by itself. Switching this off turns sleep back on.",
                                 settingsLine: "On, set by another app")
        }
        if let p = f.problem {
            return KeepAwakeText(detail: p.short, tooltip: p.long, settingsLine: p.long, warning: true)
        }
        if f.settingRead && f.sleepDisabled == nil {
            return KeepAwakeText(detail: "Status unavailable", tooltip: "Status unavailable: hantuu couldn't read the Mac's sleep setting.",
                                 settingsLine: "Status unavailable", warning: true)
        }
        let about = "Keep the Mac running with the lid shut, even on battery. Asks for your password. Ends by itself after \(hours(f.sessionHours)), after \(f.idleMinutes) minutes with no agent working, below \(f.batteryPercent)% battery, if the Mac gets too warm, or when you quit hantuu. With the lid open, hantuu already stops idle sleep while agents work."
        if let e = f.lastEnd, f.now.timeIntervalSince(e.at) < 12 * 3600, let (short, long) = endText(e, f, time: time) {
            return KeepAwakeText(detail: short, tooltip: long + "\n\n" + about, settingsLine: long)
        }
        return KeepAwakeText(detail: nil, tooltip: about, settingsLine: "Off")
    }

    /// Why the last session ended, short for the footer and as a sentence for the tooltip.
    static func endText(_ e: KeepAwakeEnd, _ f: Facts, time: (Date) -> String) -> (String, String)? {
        switch e.reason {
        case .manual, .quit: return nil
        case .idle: return ("Off: agents idle", "Off: no agent worked for \(f.idleMinutes) minutes.")
        case .battery: return ("Off: battery low", "Off: the battery fell below \(f.batteryPercent)% while unplugged.")
        case .thermal: return ("Off: Mac too warm", "Off: the Mac got too warm.")
        case .timeLimit: return ("Off: time limit", "Off: the session ended at \(time(e.at)).")
        case .stopped: return ("Off: hantuu stopped", "Off: hantuu stopped without switching it off (a crash, force quit or restart), so sleep was turned back on at \(time(e.at)).")
        case .overdue: return ("Off: ran past its end", "Off: the session ran 10 minutes past its end, so the crash check turned sleep back on at \(time(e.at)).")
        case .outside: return ("Off: set elsewhere", "Off: sleep was turned back on outside hantuu.")
        }
    }
}

/// The Keep awake label and switch in the sidebar footer. A second, smaller line says when it
/// ends or why it stopped, and the tooltip says the rest. Right-click to add an hour.
struct KeepAwakeControl: View {
    @ObservedObject var keepAwake: KeepAwake
    @ObservedObject private var settings: KeepAwakeSettings

    init(keepAwake: KeepAwake) {
        _keepAwake = ObservedObject(wrappedValue: keepAwake)
        _settings = ObservedObject(wrappedValue: keepAwake.settings)
    }

    var body: some View {
        let t = keepAwake.statusText()
        // The status line runs under both the label and the switch, so it still fits at the
        // narrowest sidebar with the usage rings beside it.
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 7) {
                Text("Keep awake")
                    .font(.system(size: 12))
                    .foregroundStyle(t.lit ? Color(nsColor: Theme.needsYou) : Color.hSecondary)
                    .lineLimit(1)
                    .fixedSize()
                Toggle("", isOn: Binding(get: { keepAwake.isOn }, set: { _ in keepAwake.toggle() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(keepAwake.busy != nil)
            }
            if let d = t.detail {
                Text(d)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(t.warning ? Color(nsColor: Theme.error) : Color.hTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        // Its natural width comes first; the spacer to its left gives way.
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .help(t.tooltip)
        .contextMenu {
            if keepAwake.session != nil {
                Button("Add 1 Hour") { keepAwake.extend() }
                Button("Switch Off") { keepAwake.toggle() }
                Divider()
            }
            Button("Keep Awake Settings…") { AppDelegate.shared?.showSettings() }
        }
    }
}

/// Settings: the limits, the current state, and removing the permission.
struct KeepAwakeSettingsSection: View {
    @ObservedObject var keepAwake: KeepAwake
    @ObservedObject private var settings: KeepAwakeSettings

    init(keepAwake: KeepAwake = AppModel.shared.keepAwake) {
        _keepAwake = ObservedObject(wrappedValue: keepAwake)
        _settings = ObservedObject(wrappedValue: keepAwake.settings)
    }

    var body: some View {
        let t = keepAwake.statusText()
        Section {
            LabeledContent("Status") {
                HStack(spacing: 8) {
                    Text(t.settingsLine)
                        .foregroundStyle(t.warning ? Color(nsColor: Theme.error) : .secondary)
                        .multilineTextAlignment(.trailing)
                    if keepAwake.session != nil {
                        Button("Add 1 Hour") { keepAwake.extend() }
                    }
                }
            }
            Picker("Session length", selection: $settings.sessionHours) {
                ForEach(KeepAwakeSettings.hourChoices, id: \.self) { Text(KeepAwake.hours($0)).tag($0) }
            }
            Picker("End when no agent has worked for", selection: $settings.idleMinutes) {
                ForEach(KeepAwakeSettings.idleChoices, id: \.self) { Text("\($0) minutes").tag($0) }
            }
            Picker("End on battery below", selection: $settings.batteryPercent) {
                ForEach(KeepAwakeSettings.batteryChoices, id: \.self) { Text("\($0)%").tag($0) }
            }
            LabeledContent {
                Button("Remove…") { keepAwake.removePermission() }
                    .disabled(!keepAwake.permissionInstalled || keepAwake.busy != nil)
            } label: {
                Text("Keep-awake permission")
                Text(keepAwake.permissionInstalled
                     ? "Installed. Asks for your password once to remove."
                     : "Not installed. Added the first time you switch Keep awake on.")
            }
        } header: {
            Text("Keep awake")
        } footer: {
            Text("The Keep awake switch in the sidebar keeps the Mac running with the lid shut, even on battery. It always ends when you quit hantuu or the Mac gets too warm. Switching it on asks for your password. The first time, hantuu also adds a sudoers rule that allows only the command that turns sleep back on, and a check that runs every minute and turns sleep back on if hantuu crashes.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
