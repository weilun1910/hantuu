import AppKit
import SwiftUI

/// A stand-in for the Mac in the Keep awake checks. Every command, prompt and file is recorded
/// and answered from here, so the self test never reaches pmset (beyond -g), sudo, /etc,
/// ~/Library/LaunchAgents or launchd.
final class FakeKeepAwakeSystem: KeepAwakeSystem {
    let user: String
    /// What `pmset -g` reports. nil makes it fail.
    var sleepDisabled: Bool? = false
    var sudoWorks = true
    var adminAnswer: AdminResult = .done
    /// The readback after the next administrator prompt fails.
    var readFailsAfterAdmin = false
    /// pid to executable path, for ps.
    var running: [Int32: String] = [:]
    var loaded = false
    var files: [String: String] = [:]
    /// Every call, in order: commands as one line, "admin", "write <path>", "remove <path>".
    var log: [String] = []
    var admin: [(script: String, prompt: String)] = []
    /// Direct pmset calls with anything but -g. Must stay empty.
    var badPmset: [[String]] = []

    init(user: String) { self.user = user }

    static func pmsetOutput(_ disabled: Bool) -> String {
        "System-wide power settings:\n" + (disabled ? " SleepDisabled\t\t1\n" : "")
            + "Currently in use:\n standby              1\n sleep                1\n hibernatemode        3\n displaysleep         10\n"
    }

    func run(_ exe: String, _ args: [String]) -> CommandResult {
        log.append(([exe] + args).joined(separator: " "))
        switch exe {
        case "/usr/bin/pmset":
            guard args == ["-g"] else {
                badPmset.append(args)
                return CommandResult(status: 1)
            }
            guard let s = sleepDisabled else { return CommandResult(status: 1, error: "pmset: can't read") }
            return CommandResult(status: 0, output: Self.pmsetOutput(s))
        case "/usr/bin/sudo":
            guard args == ["-n"] + KeepAwakeFiles.restoreCommand, sudoWorks, files[KeepAwakeFiles.sudoersPath] != nil else {
                return CommandResult(status: 1, error: "sudo: a password is required")
            }
            if sleepDisabled != nil { sleepDisabled = false }
            return CommandResult(status: 0)
        case "/bin/ps":
            if args.count == 4, let pid = Int32(args[1]), let c = running[pid] { return CommandResult(status: 0, output: c + "\n") }
            return CommandResult(status: 1)
        case "/bin/launchctl":
            switch args.first {
            case "print": return CommandResult(status: loaded ? 0 : 113)
            case "bootout":
                loaded = false
                return CommandResult(status: 0)
            case "bootstrap":
                loaded = true
                return CommandResult(status: 0)
            default: return CommandResult(status: 1)
            }
        default:
            return CommandResult(status: 127, error: "not in the fake")
        }
    }

    /// Plays what each script would do as root.
    func runAsAdministrator(_ script: String, prompt: String) -> AdminResult {
        admin.append((script, prompt))
        log.append("admin")
        guard adminAnswer == .done else { return adminAnswer }
        if script == KeepAwakeFiles.enableScript(user: user) {
            files[KeepAwakeFiles.sudoersPath] = KeepAwakeFiles.sudoers(user: user)
            if sleepDisabled != nil { sleepDisabled = true }
        } else {
            if script.contains("/usr/bin/pmset -a disablesleep 0"), sleepDisabled != nil { sleepDisabled = false }
            if script.contains("/bin/rm -f \(KeepAwakeFiles.sudoersPath)") { files[KeepAwakeFiles.sudoersPath] = nil }
        }
        if readFailsAfterAdmin { sleepDisabled = nil }
        return .done
    }

    func read(_ url: URL) -> String? { files[url.path] }

    func write(_ text: String, to url: URL, permissions: Int) -> Bool {
        log.append("write \(url.path)")
        files[url.path] = text
        return true
    }

    func remove(_ url: URL) {
        if files[url.path] != nil { log.append("remove \(url.path)") }
        files[url.path] = nil
    }

    func exists(_ path: String) -> Bool { files[path] != nil }
}

/// The clock, power and heat the fake Mac reports.
final class FakeKeepAwakeWorld {
    var now: Date
    var power = PowerState(onBattery: false, percent: 80)
    var heat: ProcessInfo.ThermalState = .nominal
    init(now: Date) { self.now = now }
}

extension SelfTest {
    static let kaStart = Date(timeIntervalSince1970: 1_800_016_200) // 12:30 PM UTC
    static let kaUser = "tester"
    static let kaPid: Int32 = 4242
    static let kaRestore = "/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0"

    static func kaTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }

    static func makeKeepAwake(_ dir: URL, _ name: String, sleepDisabled: Bool? = false, permission: Bool = false)
        -> (KeepAwake, FakeKeepAwakeSystem, FakeKeepAwakeWorld) {
        let sys = FakeKeepAwakeSystem(user: kaUser)
        sys.sleepDisabled = sleepDisabled
        if permission { sys.files[KeepAwakeFiles.sudoersPath] = KeepAwakeFiles.sudoers(user: kaUser) }
        let world = FakeKeepAwakeWorld(now: kaStart)
        let folder = dir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let env = KeepAwakeEnvironment(system: sys, folder: folder.appendingPathComponent("data"),
                                       launchAgents: folder.appendingPathComponent("LaunchAgents"),
                                       user: kaUser, uid: 501, pid: kaPid, bundleID: "local.hantuu",
                                       now: { world.now }, power: { world.power }, thermal: { world.heat },
                                       time: kaTime, live: false, disabled: false)
        let settings = KeepAwakeSettings(file: folder.appendingPathComponent("settings.json"))
        return (KeepAwake(env: env, settings: settings), sys, world)
    }

    /// Starts a fresh Keep awake and switches it on.
    static func keepAwakeOn(_ dir: URL, _ name: String) -> (KeepAwake, FakeKeepAwakeSystem, FakeKeepAwakeWorld) {
        let t = makeKeepAwake(dir, name)
        t.0.start()
        t.0.toggle()
        return t
    }

    static func keepAwake(_ dir: URL) {
        let base = dir.appendingPathComponent("keep-awake", isDirectory: true)
        Paths.ensure(base)
        var fakes: [FakeKeepAwakeSystem] = []
        func track(_ t: (KeepAwake, FakeKeepAwakeSystem, FakeKeepAwakeWorld)) -> (KeepAwake, FakeKeepAwakeSystem, FakeKeepAwakeWorld) {
            fakes.append(t.1)
            return t
        }
        keepAwakeTexts(base)
        keepAwakeGuardScript(base)

        // Reading the setting.
        check("keep awake: no SleepDisabled line in pmset -g means sleep is on (this Mac's own output)",
              KeepAwake.parseSleepDisabled("System-wide power settings:\nCurrently in use:\n standby              1\n sleep                1 (sleep prevented by caffeinate)\n") == false)
        check("keep awake: an empty or strange pmset answer is unknown, not off",
              KeepAwake.parseSleepDisabled("") == nil && KeepAwake.parseSleepDisabled("pmset: error") == nil)

        // Switching on.
        do {
            let (ka, sys, _) = track(makeKeepAwake(base, "on"))
            ka.start()
            check("keep awake: starts off, read from pmset -g", ka.settingRead && ka.sleepDisabled == false && !ka.isOn && ka.statusText().detail == nil)
            sys.log.removeAll()
            ka.toggle()
            check("keep awake: turning on asks for the password exactly once", sys.admin.count == 1, "\(sys.admin.count)")
            check("keep awake: that prompt runs the enable script with hantuu's prompt text",
                  sys.admin.first?.script == KeepAwakeFiles.enableScript(user: kaUser) && sys.admin.first?.prompt == KeepAwakeFiles.enablePrompt)
            let journal = ka.journalURL.path
            let iJournal = sys.log.firstIndex(of: "write \(journal)") ?? 999
            let iBoot = sys.log.firstIndex { $0.hasPrefix("/bin/launchctl bootstrap gui/501 ") } ?? 999
            let iAdmin = sys.log.firstIndex(of: "admin") ?? -1
            check("keep awake: the journal and the crash check are in place before sleep changes", iJournal < iBoot && iBoot < iAdmin, "\(sys.log)")
            check("keep awake: it read whether sleep was already off before claiming it", sys.log.first == "/usr/bin/pmset -g")
            let s = ka.session
            check("keep awake: on, owned, for 4 hours", ka.isOn && s?.startedAt == kaStart && s?.endsAt == kaStart.addingTimeInterval(4 * 3600) && ka.sleepDisabled == true)
            check("keep awake: the journal records ownership",
                  sys.files[journal] == "owned=1\npid=4242\nstarted=1800016200\nends=1800030600\n", sys.files[journal] ?? "none")
            check("keep awake: the LaunchAgent and guard script are written exactly",
                  sys.files[ka.plistURL.path] == KeepAwakeFiles.launchAgentPlist(scriptPath: ka.guardScriptURL.path, logPath: ka.guardLogURL.path, bundleID: "local.hantuu")
                  && sys.files[ka.guardScriptURL.path] == KeepAwakeFiles.guardScript
                  && ka.plistURL.lastPathComponent == "local.hantuu.keepawake-guard.plist")
            check("keep awake: the footer says when it ends", ka.statusText().detail == "Until 4:30 PM" && ka.statusText().lit)
            check("keep awake: the tooltip says what's true on power",
                  ka.statusText().tooltip == "Keep awake on, ends 4:30 PM (on power). It also stops after 10 minutes with no agent working, below 20% battery once unplugged, if the Mac gets too warm, or when you quit hantuu. Right-click to add an hour.",
                  ka.statusText().tooltip)
            check("keep awake: Settings says it's on", ka.statusText().settingsLine == "On until 4:30 PM")

            // A second session reuses the guard that's already loaded.
            ka.appWillQuit()
            sys.log.removeAll()
            ka.toggle()
            check("keep awake: a second session asks again but doesn't reload the crash check",
                  sys.admin.count == 2 && !sys.log.contains { $0.hasPrefix("/bin/launchctl bootstrap") } && ka.session != nil, "\(sys.log)")
        }

        // Each limit ends the session with the restore command, silently.
        do {
            let (ka, sys, _) = track(keepAwakeOn(base, "idle"))
            ka.agentsWorking(true, now: kaStart.addingTimeInterval(120))
            ka.agentsWorking(false, now: kaStart.addingTimeInterval(11 * 60))
            check("keep awake: an agent working pushes the idle limit back", ka.session != nil)
            ka.agentsWorking(false, now: kaStart.addingTimeInterval(12 * 60 + 1))
            check("keep awake: 10 minutes with no agent working switches it off with sudo -n",
                  ka.session == nil && sys.log.contains(kaRestore) && sys.files[ka.journalURL.path] == nil && ka.lastEnd?.reason == .idle && sys.admin.count == 1,
                  "\(sys.log)")
            check("keep awake: the footer says why", ka.statusText().detail == "Off: agents idle" && ka.statusText().tooltip.hasPrefix("Off: no agent worked for 10 minutes.\n\n"))
        }
        do {
            let (ka, sys, world) = track(keepAwakeOn(base, "battery"))
            world.power = PowerState(onBattery: false, percent: 15)
            ka.tick(now: kaStart.addingTimeInterval(30))
            check("keep awake: a low battery on power doesn't end it", ka.session != nil)
            world.power = PowerState(onBattery: true, percent: 64)
            check("keep awake: the tooltip says what's true on battery",
                  ka.statusText().tooltip == "Keep awake on, ends 4:30 PM (on battery, stops below 20%). It also stops after 10 minutes with no agent working, if the Mac gets too warm, or when you quit hantuu. Right-click to add an hour.",
                  ka.statusText().tooltip)
            world.power = PowerState(onBattery: true, percent: 19)
            ka.tick(now: kaStart.addingTimeInterval(40))
            check("keep awake: below 20% on battery switches it off", ka.session == nil && sys.log.contains(kaRestore) && ka.lastEnd?.reason == .battery)
            check("keep awake: and says so", ka.statusText().detail == "Off: battery low" && ka.statusText().settingsLine == "Off: the battery fell below 20% while unplugged.")
        }
        do {
            let (ka, sys, world) = track(keepAwakeOn(base, "thermal"))
            world.heat = .fair
            ka.tick(now: kaStart.addingTimeInterval(10))
            check("keep awake: a fair thermal state doesn't end it", ka.session != nil)
            world.heat = .serious
            ka.tick(now: kaStart.addingTimeInterval(20))
            check("keep awake: a serious thermal state switches it off", ka.session == nil && sys.log.contains(kaRestore) && ka.lastEnd?.reason == .thermal)
            let (ka2, sys2, world2) = track(keepAwakeOn(base, "thermal-critical"))
            world2.heat = .critical
            ka2.tick(now: kaStart.addingTimeInterval(20))
            check("keep awake: so does critical", ka2.session == nil && sys2.log.contains(kaRestore) && ka2.lastEnd?.reason == .thermal)
        }
        do {
            let (ka, sys, world) = track(keepAwakeOn(base, "time"))
            world.now = kaStart.addingTimeInterval(3600)
            ka.extend()
            check("keep awake: Add 1 Hour moves the end and the journal",
                  ka.session?.endsAt == kaStart.addingTimeInterval(5 * 3600) && sys.files[ka.journalURL.path]?.contains("ends=1800034200") == true
                  && ka.statusText().detail == "Until 5:30 PM")
            ka.agentsWorking(true, now: kaStart.addingTimeInterval(4 * 3600))
            check("keep awake: still on at the old end", ka.session != nil)
            ka.agentsWorking(true, now: kaStart.addingTimeInterval(5 * 3600))
            check("keep awake: the session length switches it off, even with agents working",
                  ka.session == nil && sys.log.contains(kaRestore) && ka.lastEnd?.reason == .timeLimit)
            check("keep awake: and says when", ka.statusText().settingsLine == "Off: the session ended at 5:30 PM.")
        }
        do {
            let (ka, sys, _) = track(keepAwakeOn(base, "quit"))
            sys.log.removeAll()
            ka.appWillQuit()
            check("keep awake: quitting switches it off and clears the journal, without a prompt",
                  ka.session == nil && sys.log.first == kaRestore && sys.files[ka.journalURL.path] == nil && sys.admin.count == 1, "\(sys.log)")
        }

        // A failed switch-off never prompts by itself, stays on record, and is retried.
        do {
            let (ka, sys, world) = track(keepAwakeOn(base, "stuck"))
            sys.sudoWorks = false
            world.heat = .critical
            ka.tick(now: kaStart.addingTimeInterval(30))
            check("keep awake: a limit that can't switch it off doesn't ask for a password", sys.admin.count == 1 && ka.stuck && ka.session != nil && sys.files[ka.journalURL.path] != nil)
            check("keep awake: the footer says it couldn't", ka.statusText().detail == "Couldn't switch off" && ka.statusText().warning)
            sys.sudoWorks = true
            world.heat = .nominal
            ka.tick(now: kaStart.addingTimeInterval(95))
            check("keep awake: a minute later it tries again, and keeps the reason", ka.session == nil && !ka.stuck && ka.lastEnd?.reason == .thermal && sys.files[ka.journalURL.path] == nil)
        }
        do {
            let (ka, sys, _) = track(keepAwakeOn(base, "manual-fallback"))
            sys.sudoWorks = false
            ka.toggle()
            check("keep awake: switching off by hand when sudo can't falls back to one password prompt",
                  sys.admin.count == 2 && sys.admin.last?.script == KeepAwakeFiles.disableScript && sys.admin.last?.prompt == KeepAwakeFiles.disablePrompt && ka.session == nil)
            check("keep awake: switching off by hand shows no reason line", ka.statusText().detail == nil && ka.statusText().settingsLine == "Off")
        }

        // Someone else's override: never claimed, never cleared by a limit.
        do {
            let (ka, sys, world) = track(makeKeepAwake(base, "elsewhere", sleepDisabled: true, permission: true))
            ka.start()
            check("keep awake: an override from another app shows as on, set by another app",
                  ka.isOn && ka.session == nil && ka.statusText().detail == "Set by another app" && ka.statusText().settingsLine == "On, set by another app")
            ka.switchOn()
            check("keep awake: switching on over it doesn't prompt or write a journal",
                  sys.admin.isEmpty && sys.files[ka.journalURL.path] == nil && ka.session == nil)
            world.heat = .critical
            world.power = PowerState(onBattery: true, percent: 3)
            ka.agentsWorking(false, now: kaStart.addingTimeInterval(9 * 3600))
            ka.appWillQuit()
            check("keep awake: no limit or quit ever clears it", !sys.log.contains(kaRestore) && sys.sleepDisabled == true, "\(sys.log)")
        }

        // Turning on that doesn't go through.
        do {
            let (ka, sys, _) = track(makeKeepAwake(base, "cancel"))
            ka.start()
            sys.adminAnswer = .cancelled
            ka.toggle()
            check("keep awake: cancelling the prompt leaves nothing behind",
                  ka.session == nil && sys.files[ka.journalURL.path] == nil && sys.files[ka.plistURL.path] == nil
                  && sys.files[ka.guardScriptURL.path] == nil && !sys.loaded && ka.statusText().detail == nil, "\(sys.files.keys.sorted())")
        }
        do {
            let (ka, sys, _) = track(makeKeepAwake(base, "readback"))
            ka.start()
            sys.readFailsAfterAdmin = true
            ka.toggle()
            check("keep awake: a failed readback says Status unavailable and keeps the limits running",
                  ka.session != nil && ka.sleepDisabled == nil && sys.files[ka.journalURL.path] != nil
                  && ka.statusText().detail == "Status unavailable" && ka.statusText().warning)
        }
        do {
            let (ka, sys, world) = track(makeKeepAwake(base, "refused"))
            ka.start()
            world.power = PowerState(onBattery: true, percent: 12)
            ka.toggle()
            check("keep awake: below the battery limit it won't turn on, and doesn't ask",
                  sys.admin.isEmpty && ka.session == nil && ka.statusText().detail == "Battery below 20%")
            world.power = PowerState(onBattery: false, percent: 12)
            world.heat = .serious
            ka.toggle()
            check("keep awake: nor when the Mac runs hot", sys.admin.isEmpty && ka.session == nil && ka.statusText().detail == "Mac too warm")
            world.heat = .nominal
            sys.sleepDisabled = nil
            ka.toggle()
            check("keep awake: nor when the setting can't be read", sys.admin.isEmpty && ka.statusText().detail == "Status unavailable")
        }

        // Launch: putting right what an earlier hantuu left.
        do {
            let (ka, sys, _) = track(makeKeepAwake(base, "launch-crash", sleepDisabled: true, permission: true))
            sys.files[ka.journalURL.path] = KeepAwakeJournal(pid: 999, startedAt: kaStart, endsAt: kaStart.addingTimeInterval(4 * 3600)).text
            ka.start()
            check("keep awake: at launch, an override left by a crashed hantuu is switched off",
                  sys.log.contains(kaRestore) && sys.files[ka.journalURL.path] == nil && sys.sleepDisabled == false && ka.lastEnd?.reason == .stopped && ka.session == nil)
            check("keep awake: and the footer says so", ka.statusText().detail == "Off: hantuu stopped")
        }
        do {
            let (ka, sys, _) = track(makeKeepAwake(base, "launch-already", sleepDisabled: false, permission: true))
            sys.files[ka.journalURL.path] = KeepAwakeJournal(pid: 999, startedAt: kaStart, endsAt: kaStart).text
            ka.start()
            check("keep awake: at launch, a journal with sleep already on is just cleared", !sys.log.contains(kaRestore) && sys.files[ka.journalURL.path] == nil)
        }
        do {
            let (ka, sys, _) = track(makeKeepAwake(base, "launch-other-copy", sleepDisabled: true, permission: true))
            sys.files[ka.journalURL.path] = KeepAwakeJournal(pid: 999, startedAt: kaStart, endsAt: kaStart).text
            sys.running[999] = "/Applications/hantuu.app/Contents/MacOS/hantuu"
            ka.start()
            check("keep awake: at launch, another running hantuu's session is left alone",
                  !sys.log.contains(kaRestore) && sys.files[ka.journalURL.path] != nil && ka.statusText().detail == "Set by another app")
        }
        do {
            let (ka, sys, _) = track(makeKeepAwake(base, "launch-guard-note", sleepDisabled: false, permission: true))
            sys.files[ka.endedURL.path] = "reason=stopped\nat=1800020000\n"
            ka.start()
            check("keep awake: at launch, the crash check's note becomes the reason line",
                  ka.lastEnd == KeepAwakeEnd(reason: .stopped, at: Date(timeIntervalSince1970: 1_800_020_000)) && sys.files[ka.endedURL.path] == nil
                  && ka.statusText().settingsLine == "Off: hantuu stopped without switching it off (a crash, force quit or restart), so sleep was turned back on at 1:33 PM.",
                  ka.statusText().settingsLine)
        }
        do {
            let (ka, sys, _) = track(makeKeepAwake(base, "launch-stuck", sleepDisabled: true, permission: true))
            sys.sudoWorks = false
            sys.files[ka.journalURL.path] = KeepAwakeJournal(pid: 999, startedAt: kaStart, endsAt: kaStart.addingTimeInterval(3600)).text
            ka.start()
            check("keep awake: at launch, if sudo can't put it back, hantuu takes the session over and keeps trying",
                  ka.session?.endsAt == kaStart.addingTimeInterval(3600) && ka.stuck && sys.files[ka.journalURL.path]?.contains("pid=4242") == true
                  && sys.admin.isEmpty && ka.statusText().detail == "Couldn't switch off")
        }

        // While running: the crash check or something else turned sleep back on.
        do {
            let (ka, sys, _) = track(keepAwakeOn(base, "overdue"))
            sys.files[ka.journalURL.path] = nil
            sys.files[ka.endedURL.path] = "reason=overdue\nat=1800031200\n"
            sys.sleepDisabled = false
            ka.agentsWorking(true, now: kaStart.addingTimeInterval(61))
            check("keep awake: when the crash check ended an overdue session, hantuu catches up",
                  ka.session == nil && ka.lastEnd?.reason == .overdue && ka.statusText().detail == "Off: ran past its end")
        }
        do {
            let (ka, sys, _) = track(keepAwakeOn(base, "outside"))
            sys.sleepDisabled = false
            ka.agentsWorking(true, now: kaStart.addingTimeInterval(61))
            check("keep awake: sleep turned back on outside hantuu ends the session", ka.session == nil && ka.lastEnd?.reason == .outside && sys.files[ka.journalURL.path] == nil)
        }
        do {
            let (ka, sys, _) = track(keepAwakeOn(base, "journal-gone"))
            sys.files[ka.journalURL.path] = nil
            ka.agentsWorking(true, now: kaStart.addingTimeInterval(61))
            check("keep awake: a missing journal is written again while the session is on", ka.session != nil && sys.files[ka.journalURL.path] != nil)
        }

        // Removing the permission.
        do {
            let (ka, sys, _) = track(keepAwakeOn(base, "remove-on"))
            check("keep awake: the permission shows as installed", ka.permissionInstalled)
            sys.log.removeAll()
            ka.removePermission()
            check("keep awake: Remove asks once, turns sleep back on and deletes the sudoers rule",
                  sys.admin.count == 2 && sys.admin.last?.script == "/usr/bin/pmset -a disablesleep 0; /bin/rm -f /etc/sudoers.d/hantuu-keepawake"
                  && sys.admin.last?.prompt == KeepAwakeFiles.removePrompt && sys.files[KeepAwakeFiles.sudoersPath] == nil)
            check("keep awake: and unloads and deletes the LaunchAgent and guard script",
                  sys.log.contains("/bin/launchctl bootout gui/501/local.hantuu.keepawake-guard") && !sys.loaded
                  && sys.files[ka.plistURL.path] == nil && sys.files[ka.guardScriptURL.path] == nil && !ka.permissionInstalled)
            check("keep awake: the session ends with it", ka.session == nil && sys.files[ka.journalURL.path] == nil)
            let (ka2, sys2, _) = track(keepAwakeOn(base, "remove-off"))
            ka2.toggle()
            ka2.removePermission()
            check("keep awake: Remove while off leaves sleep alone", sys2.admin.last?.script == "/bin/rm -f /etc/sudoers.d/hantuu-keepawake" && !ka2.permissionInstalled)
        }

        // Settings.
        do {
            let file = base.appendingPathComponent("settings-test/settings.json")
            try? FileManager.default.removeItem(at: file)
            let s = KeepAwakeSettings(file: file)
            check("keep awake: limits default to 10 minutes idle, 4 hours, 20% battery", s.idleMinutes == 10 && s.sessionHours == 4 && s.batteryPercent == 20)
            s.idleMinutes = 30
            s.sessionHours = 8
            s.batteryPercent = 30
            let back = KeepAwakeSettings(file: file)
            check("keep awake: the limits are saved", back.idleMinutes == 30 && back.sessionHours == 8 && back.batteryPercent == 30)
            try? Data(#"{"idleMinutes":7,"sessionHours":4000,"batteryPercent":-1}"#.utf8).write(to: file)
            let odd = KeepAwakeSettings(file: file)
            check("keep awake: values that aren't a choice fall back to the defaults", odd.idleMinutes == 10 && odd.sessionHours == 4 && odd.batteryPercent == 20)
            let (ka, sys, _) = track(makeKeepAwake(base, "settings-apply"))
            ka.settings.idleMinutes = 5
            ka.settings.sessionHours = 1
            ka.start()
            ka.toggle()
            ka.agentsWorking(false, now: kaStart.addingTimeInterval(5 * 60 + 1))
            check("keep awake: the idle and session settings apply", ka.lastEnd?.reason == .idle && sys.log.contains(kaRestore))
        }

        // The text in each state.
        do {
            var f = KeepAwake.Facts(session: nil, sleepDisabled: false, settingRead: true, stuck: false, busy: nil, lastEnd: nil, problem: nil,
                                    power: PowerState(onBattery: false, percent: 90), idleMinutes: 10, sessionHours: 4, batteryPercent: 20, now: kaStart)
            check("keep awake: the off tooltip lists every limit",
                  KeepAwake.text(f, time: kaTime).tooltip == "Keep the Mac running with the lid shut, even on battery. Asks for your password. Ends by itself after 4 hours, after 10 minutes with no agent working, below 20% battery, if the Mac gets too warm, or when you quit hantuu. With the lid open, hantuu already stops idle sleep while agents work.")
            f.sleepDisabled = nil
            check("keep awake: an unreadable setting says Status unavailable", KeepAwake.text(f, time: kaTime).detail == "Status unavailable")
            f.sleepDisabled = false
            f.lastEnd = KeepAwakeEnd(reason: .idle, at: kaStart.addingTimeInterval(-13 * 3600))
            check("keep awake: an old reason line fades after 12 hours", KeepAwake.text(f, time: kaTime).detail == nil)
            f.busy = .turningOn
            check("keep awake: while the prompt is up it says so", KeepAwake.text(f, time: kaTime).detail == "Waiting for password")
            let all = [KeepAwake.text(f, time: kaTime).tooltip] + [KeepAwakeEnd.Reason.idle, .battery, .thermal, .timeLimit, .stopped, .overdue, .outside].compactMap {
                KeepAwake.endText(KeepAwakeEnd(reason: $0, at: kaStart), f, time: kaTime).map { $0.0 + " " + $0.1 }
            }
            check("keep awake: no em or en dashes or middle dots in its text", !all.joined().contains { "\u{2013}\u{2014}\u{00B7}".contains($0) })
        }

        check("keep awake: pmset is never run directly with anything but -g", fakes.allSatisfy { $0.badPmset.isEmpty })

        keepAwakeSnapshots(base)
    }

    // MARK: Texts

    static func keepAwakeTexts(_ base: URL) {
        let expectedSudoers = """
        # hantuu Keep awake: lets this user turn sleep back on without a password, and nothing else.
        # Remove it from hantuu Settings, or delete this file.
        tester ALL = (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0

        """
        let sudoers = KeepAwakeFiles.sudoers(user: kaUser)
        check("keep awake: the sudoers text is exactly as expected", sudoers == expectedSudoers, sudoers)
        let rules = sudoers.split(separator: "\n").filter { !$0.hasPrefix("#") }
        check("keep awake: the sudoers rule allows one command, which can only turn sleep back on",
              rules == ["tester ALL = (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0"])
        check("keep awake: no sudoers line has a quote that could break out of printf", !KeepAwakeFiles.sudoersLines(user: kaUser).joined().contains("'"))
        check("keep awake: only plain account names are used",
              KeepAwakeFiles.isPlainUserName("jappleseed") && KeepAwakeFiles.isPlainUserName("first.last_2")
              && !KeepAwakeFiles.isPlainUserName("") && !KeepAwakeFiles.isPlainUserName("a b") && !KeepAwakeFiles.isPlainUserName("x;rm")
              && !KeepAwakeFiles.isPlainUserName("-n") && !KeepAwakeFiles.isPlainUserName("x'y") && !KeepAwakeFiles.isPlainUserName("\u{00E9}mile"))

        // The printf step, run for real into a temp file, gives exactly that text, and visudo accepts it.
        let vdir = base.appendingPathComponent("visudo", isDirectory: true)
        Paths.ensure(vdir)
        let made = vdir.appendingPathComponent("from-printf")
        let sh = shell("/bin/sh", ["-c", "t='\(made.path)'; " + KeepAwakeFiles.printfCommand(user: kaUser)], env: ["PATH": "/bin"])
        let madeText = (try? String(contentsOf: made, encoding: .utf8)) ?? ""
        check("keep awake: the enable script's printf writes exactly the sudoers text", sh.ok && madeText == expectedSudoers, madeText)
        let good = shell("/usr/sbin/visudo", ["-cf", made.path])
        check("keep awake: visudo -cf accepts the sudoers text (run without root)", good.ok, good.output + good.error)
        let broken = vdir.appendingPathComponent("broken")
        try? Data("tester ALL = (root NOPASSWD: /usr/bin/pmset\n".utf8).write(to: broken)
        check("keep awake: and visudo -cf rejects a broken one, so the check means something", !shell("/usr/sbin/visudo", ["-cf", broken.path]).ok)

        let expectedEnable = "set -e; umask 077; t=$(/usr/bin/mktemp /private/var/tmp/hantuu-keepawake.XXXXXX); trap '/bin/rm -f \"$t\"' EXIT; "
            + "/usr/bin/printf '%s\\n' '# hantuu Keep awake: lets this user turn sleep back on without a password, and nothing else.' '# Remove it from hantuu Settings, or delete this file.' 'tester ALL = (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0' > \"$t\"; "
            + "/usr/sbin/visudo -cf \"$t\" >/dev/null 2>&1 || { echo 'The keep-awake sudoers rule failed its visudo check, so nothing was changed.' >&2; exit 3; }; "
            + "/usr/bin/install -m 0440 -o root -g wheel \"$t\" /etc/sudoers.d/hantuu-keepawake; "
            + "/usr/bin/sudo -n -l -U tester /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1 || { /bin/rm -f /etc/sudoers.d/hantuu-keepawake; echo 'macOS did not accept the keep-awake sudoers rule, so sleep was left alone.' >&2; exit 4; }; "
            + "/usr/bin/pmset -a disablesleep 1"
        let enable = KeepAwakeFiles.enableScript(user: kaUser)
        check("keep awake: the enable script is exactly as expected", enable == expectedEnable, enable)
        func at(_ s: String) -> Int { enable.range(of: s).map { enable.distance(from: enable.startIndex, to: $0.lowerBound) } ?? -1 }
        check("keep awake: it checks with visudo, installs 0440 root:wheel, confirms sudo, and only then turns sleep off",
              at("visudo -cf") >= 0 && at("visudo -cf") < at("install -m 0440 -o root -g wheel") && at("install -m 0440") < at("sudo -n -l -U")
              && at("sudo -n -l -U") < at("pmset -a disablesleep 1") && enable.hasSuffix("/usr/bin/pmset -a disablesleep 1"))
        check("keep awake: it never touches /etc/sudoers itself",
              enable.components(separatedBy: "/etc/sudoers").dropFirst().allSatisfy { $0.hasPrefix(".d/hantuu-keepawake") })
        check("keep awake: the enable script parses as sh", shell("/bin/sh", ["-n", "-c", enable]).ok)
        check("keep awake: the remove scripts are exactly as expected",
              KeepAwakeFiles.removeScript(restoreSleep: false) == "/bin/rm -f /etc/sudoers.d/hantuu-keepawake"
              && KeepAwakeFiles.removeScript(restoreSleep: true) == "/usr/bin/pmset -a disablesleep 0; /bin/rm -f /etc/sudoers.d/hantuu-keepawake")
        check("keep awake: the restore command is the one the rule allows", KeepAwakeFiles.restoreCommand.joined(separator: " ") == "/usr/bin/pmset -a disablesleep 0")

        let apple = KeepAwakeFiles.appleScript(enable, prompt: KeepAwakeFiles.enablePrompt)
        check("keep awake: the prompt text is exactly as expected",
              KeepAwakeFiles.enablePrompt == "hantuu wants to keep your Mac awake, even with the lid shut. This also lets hantuu turn sleep back on later without asking for your password.")
        check("keep awake: the AppleScript escapes quotes and backslashes",
              apple.hasPrefix("do shell script \"set -e; umask 077;") && apple.contains("'%s\\\\n'") && apple.contains("trap '/bin/rm -f \\\"$t\\\"' EXIT")
              && apple.hasSuffix(" with prompt \"\(KeepAwakeFiles.enablePrompt)\" with administrator privileges"))
        var compileError: NSDictionary?
        let compiled = NSAppleScript(source: apple)?.compileAndReturnError(&compileError) ?? false
        check("keep awake: the AppleScript compiles (compiled only, never run)", compiled, "\(String(describing: compileError))")

        let plist = KeepAwakeFiles.launchAgentPlist(scriptPath: "/Users/tester/Library/Application Support/hantuu/keep-awake/guard.sh",
                                                    logPath: "/Users/tester/Library/Application Support/hantuu/keep-awake/guard.log", bundleID: "local.hantuu")
        let expectedPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>local.hantuu.keepawake-guard</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>/bin/sh</string>
        \t\t<string>/Users/tester/Library/Application Support/hantuu/keep-awake/guard.sh</string>
        \t</array>
        \t<key>EnvironmentVariables</key>
        \t<dict>
        \t\t<key>PATH</key>
        \t\t<string>/usr/bin:/bin:/usr/sbin:/sbin</string>
        \t</dict>
        \t<key>StartInterval</key>
        \t<integer>60</integer>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>ProcessType</key>
        \t<string>Background</string>
        \t<key>StandardErrorPath</key>
        \t<string>/Users/tester/Library/Application Support/hantuu/keep-awake/guard.log</string>
        \t<key>AssociatedBundleIdentifiers</key>
        \t<string>local.hantuu</string>
        </dict>
        </plist>

        """
        check("keep awake: the LaunchAgent plist is exactly as expected", plist == expectedPlist, plist)
        let parsed = (try? PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil)) as? [String: Any]
        check("keep awake: the plist parses: a 60 second interval, at login too, running the guard under /bin/sh",
              parsed?["Label"] as? String == "local.hantuu.keepawake-guard" && parsed?["StartInterval"] as? Int == 60 && parsed?["RunAtLoad"] as? Bool == true
              && parsed?["ProgramArguments"] as? [String] == ["/bin/sh", "/Users/tester/Library/Application Support/hantuu/keep-awake/guard.sh"])
        let tricky = KeepAwakeFiles.launchAgentPlist(scriptPath: "/tmp/a&b<c>/guard.sh", logPath: "/tmp/l", bundleID: "local.hantuu")
        let trickyParsed = (try? PropertyListSerialization.propertyList(from: Data(tricky.utf8), format: nil)) as? [String: Any]
        check("keep awake: paths with & < > are escaped in the plist", (trickyParsed?["ProgramArguments"] as? [String])?.last == "/tmp/a&b<c>/guard.sh")
        check("keep awake: the guard script parses as sh", shell("/bin/sh", ["-n", "-c", KeepAwakeFiles.guardScript]).ok)
        check("keep awake: the guard script only ever runs the restore command through sudo",
              KeepAwakeFiles.guardScript.components(separatedBy: "sudo ").count == 2
              && KeepAwakeFiles.guardScript.components(separatedBy: "sudo ")[1].hasPrefix("-n /usr/bin/pmset -a disablesleep 0 "))
    }

    // MARK: The guard script, run for real with a fake sudo, pmset and ps

    struct GuardRun {
        var calls: [String]
        var journalLeft: Bool
        var ended: String?
        var log: String
        var state: String
    }

    static func keepAwakeGuardScript(_ base: URL) {
        let root = base.appendingPathComponent("guard", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let bin = root.appendingPathComponent("fakebin", isDirectory: true)
        Paths.ensure(bin)
        // Each fake logs its call into $FAKE_DIR/calls. None of them ever runs a real command.
        let fakes: [String: String] = [
            "sudo": """
            #!/bin/sh
            echo "sudo $*" >> "$FAKE_DIR/calls"
            [ "$(cat "$FAKE_DIR/sudo-works")" = 1 ] || { echo "sudo: a password is required" >&2; exit 1; }
            [ "$*" = "-n /usr/bin/pmset -a disablesleep 0" ] || exit 1
            echo 0 > "$FAKE_DIR/state"

            """,
            "pmset": """
            #!/bin/sh
            echo "pmset $*" >> "$FAKE_DIR/calls"
            [ "$*" = "-g" ] || { echo "fake pmset only answers -g" >&2; exit 64; }
            case $(cat "$FAKE_DIR/state") in
                1) printf 'System-wide power settings:\\n SleepDisabled\\t\\t1\\nCurrently in use:\\n standby 1\\n' ;;
                0) printf 'System-wide power settings:\\nCurrently in use:\\n standby 1\\n' ;;
                *) exit 1 ;;
            esac

            """,
            "ps": """
            #!/bin/sh
            echo "ps $*" >> "$FAKE_DIR/calls"
            while read -r p c; do
                [ "$p" = "$2" ] && { echo "$c"; exit 0; }
            done < "$FAKE_DIR/procs"
            exit 1

            """,
        ]
        for (name, text) in fakes {
            let url = bin.appendingPathComponent(name)
            try? Data(text.utf8).write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let now = Int(Date().timeIntervalSince1970)

        func run(_ name: String, journal: String?, state: String, sudoWorks: Bool = true, procs: String = "") -> GuardRun {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            let fake = dir.appendingPathComponent("fake", isDirectory: true)
            Paths.ensure(fake)
            let script = dir.appendingPathComponent("guard.sh")
            try? Data(KeepAwakeFiles.guardScript.utf8).write(to: script)
            if let journal { try? Data(journal.utf8).write(to: dir.appendingPathComponent("journal")) }
            try? Data("\(state)\n".utf8).write(to: fake.appendingPathComponent("state"))
            try? Data((sudoWorks ? "1\n" : "0\n").utf8).write(to: fake.appendingPathComponent("sudo-works"))
            try? Data(procs.utf8).write(to: fake.appendingPathComponent("procs"))
            try? Data().write(to: fake.appendingPathComponent("calls"))
            // /usr/bin isn't on PATH, so the real sudo and pmset can't be reached even by mistake.
            let r = shell("/bin/sh", [script.path], env: ["PATH": bin.path + ":/bin", "FAKE_DIR": fake.path])
            if !r.ok { print("      guard \(name) exited \(r.status): \(r.error)") }
            func text(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
            return GuardRun(calls: (text(fake.appendingPathComponent("calls")) ?? "").split(separator: "\n").map(String.init),
                            journalLeft: FileManager.default.fileExists(atPath: dir.appendingPathComponent("journal").path),
                            ended: text(dir.appendingPathComponent("ended")),
                            log: text(dir.appendingPathComponent("guard.log")) ?? "",
                            state: (text(fake.appendingPathComponent("state")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        func journal(pid: Int32 = 4242, ends: Int? = nil) -> String {
            KeepAwakeJournal(pid: pid, startedAt: Date(timeIntervalSince1970: TimeInterval(now - 600)),
                             endsAt: Date(timeIntervalSince1970: TimeInterval(ends ?? now + 3600))).text
        }
        let restore = "sudo -n /usr/bin/pmset -a disablesleep 0"
        let app = "4242 /Applications/hantuu.app/Contents/MacOS/hantuu\n"

        let none = run("no-journal", journal: nil, state: "1")
        check("guard: with no journal it does nothing at all", none.calls.isEmpty && none.state == "1", "\(none.calls)")
        let alive = run("owner-running", journal: journal(), state: "1", procs: app)
        check("guard: while the owning hantuu runs, it leaves sleep alone", alive.calls == ["ps -p 4242 -o comm="] && alive.journalLeft && alive.state == "1", "\(alive.calls)")
        let gone = run("owner-gone", journal: journal(), state: "1")
        check("guard: once that hantuu is gone, it turns sleep back on with sudo -n and reads it back",
              gone.calls == ["ps -p 4242 -o comm=", "pmset -g", restore, "pmset -g"] && gone.state == "0", "\(gone.calls)")
        check("guard: then clears the journal and leaves a note for hantuu",
              !gone.journalLeft && gone.ended?.hasPrefix("reason=stopped\nat=") == true && gone.log.contains("sleep is on again (stopped)"), gone.log)
        let reused = run("pid-reused", journal: journal(), state: "1", procs: "4242 /usr/libexec/somethingelse\n")
        check("guard: a reused pid isn't mistaken for hantuu", reused.calls.contains(restore) && !reused.journalLeft && reused.state == "0")
        let notOwned = run("not-owned", journal: "owned=0\npid=4242\nstarted=1\nends=2\n", state: "1")
        check("guard: a journal that doesn't claim ownership is ignored", notOwned.calls.isEmpty && notOwned.state == "1")
        let already = run("already-on", journal: journal(), state: "0")
        check("guard: when sleep is already on it just clears the journal", !already.calls.contains(restore) && !already.journalLeft && already.ended == nil)
        let fails = run("sudo-fails", journal: journal(), state: "1", sudoWorks: false)
        check("guard: when sudo fails it keeps the journal to try again next minute",
              fails.calls.contains(restore) && fails.journalLeft && fails.state == "1" && fails.log.contains("couldn't turn sleep back on"), fails.log)
        let overdue = run("overdue", journal: journal(ends: now - 700), state: "1", procs: app)
        check("guard: a session 10 minutes past its end is ended even if hantuu is running (hung)",
              overdue.calls.contains(restore) && !overdue.journalLeft && overdue.ended?.hasPrefix("reason=overdue") == true)
        let early = run("not-yet-overdue", journal: journal(ends: now - 300), state: "1", procs: app)
        check("guard: but not before those 10 minutes", !early.calls.contains(restore) && early.journalLeft)
        let unreadable = run("pmset-unreadable", journal: journal(), state: "x", sudoWorks: false)
        check("guard: if pmset can't be read it still tries sudo, and keeps the journal until it can confirm", unreadable.calls.contains(restore) && unreadable.journalLeft)
        let allCalls = [none, alive, gone, reused, notOwned, already, fails, overdue, early, unreadable].flatMap(\.calls)
        check("guard: it never calls pmset with anything but -g, or sudo with anything but the restore command",
              allCalls.allSatisfy { $0 == "pmset -g" || $0 == restore || $0.hasPrefix("ps -p ") }, "\(allCalls)")
    }

    struct ShellResult {
        var status: Int32
        var output: String
        var error: String
        var ok: Bool { status == 0 }
    }

    /// Runs a local, read-only command for the checks above (sh and visudo -cf).
    static func shell(_ exe: String, _ args: [String], env: [String: String]? = nil) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let env { p.environment = env }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return ShellResult(status: -1, output: "", error: error.localizedDescription) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ShellResult(status: p.terminationStatus, output: String(decoding: o, as: UTF8.self), error: String(decoding: e, as: UTF8.self))
    }

    // MARK: Snapshots

    static func keepAwakeSnapshots(_ base: URL) {
        let out = base.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("snapshots", isDirectory: true)
        Paths.ensure(out)
        Theme.configure(from: GhosttyApp.shared)
        let snaps = base.appendingPathComponent("snapshots", isDirectory: true)

        // One Keep awake per state, driven there through the fake.
        let off = makeKeepAwake(snaps, "off").0
        off.start()
        let (on, _, onWorld) = keepAwakeOn(snaps, "on")
        onWorld.power = PowerState(onBattery: true, percent: 64)
        let other = makeKeepAwake(snaps, "other", sleepDisabled: true).0
        other.start()
        let unavailable = makeKeepAwake(snaps, "unavailable", sleepDisabled: nil).0
        unavailable.start()
        let idle = keepAwakeOn(snaps, "idle").0
        idle.agentsWorking(false, now: kaStart.addingTimeInterval(11 * 60))
        let (stuck, stuckSys, stuckWorld) = keepAwakeOn(snaps, "stuck")
        stuckSys.sudoWorks = false
        stuckWorld.heat = .critical
        stuck.tick(now: kaStart.addingTimeInterval(20))
        let states = [off, on, other, unavailable, idle, stuck]

        let w = makeWindow()
        func render<V: View>(_ view: V, size: NSSize, name: String, dark: Bool) -> Bool {
            let host = NSHostingView(rootView: AnyView(view.environmentObject(AppModel.shared).environment(\.colorScheme, dark ? .dark : .light)))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: size)
            w.contentView?.addSubview(host)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            defer { host.removeFromSuperview() }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
            host.cacheDisplay(in: host.bounds, to: rep)
            return (rep.representation(using: .png, properties: [:]).flatMap { try? $0.write(to: out.appendingPathComponent(name)) }) != nil
        }

        // The footer as it sits in the sidebar, with room held on the left for the usage rings
        // another branch adds (two faint circles stand in for them here).
        func footer(_ ka: KeepAwake) -> some View {
            HStack(spacing: 4) {
                HStack(spacing: 5) {
                    Circle().stroke(Color.hDivider, lineWidth: 2).frame(width: 14, height: 14)
                    Circle().stroke(Color.hDivider, lineWidth: 2).frame(width: 14, height: 14)
                }
                Spacer()
                KeepAwakeControl(keepAwake: ka)
                IconButton(symbol: "gearshape", help: "Settings") {}
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
        }
        func sheet(width: CGFloat) -> some View {
            VStack(spacing: 0) {
                ForEach(states.indices, id: \.self) { i in
                    Rectangle().fill(Color.hDivider).frame(height: 1)
                    footer(states[i])
                }
            }
            .frame(width: width)
            .background(Color.hChrome)
        }
        let height = CGFloat(states.count) * 39
        var ok = true
        for width in [200, 260] as [CGFloat] {
            for dark in [true, false] {
                ok = render(sheet(width: width), size: NSSize(width: width, height: height),
                            name: "keep-awake-footer-\(Int(width))-\(dark ? "dark" : "light").png", dark: dark) && ok
            }
        }
        check("snapshot: the Keep awake footer off, on, set by another app, unavailable, off after idle and stuck, at 200 and 260 pt, light and dark", ok)

        func settingsView(_ ka: KeepAwake) -> some View {
            Form { KeepAwakeSettingsSection(keepAwake: ka) }
                .formStyle(.grouped)
                .frame(width: 520, height: 420)
        }
        let s1 = render(settingsView(on), size: NSSize(width: 520, height: 420), name: "keep-awake-settings-on-dark.png", dark: true)
        let s2 = render(settingsView(on), size: NSSize(width: 520, height: 420), name: "keep-awake-settings-on-light.png", dark: false)
        let s3 = render(settingsView(off), size: NSSize(width: 520, height: 420), name: "keep-awake-settings-off-light.png", dark: false)
        check("snapshot: the Keep awake section in Settings, on and off, light and dark", s1 && s2 && s3)
        print("      keep awake snapshots in \(out.path)")
    }
}
