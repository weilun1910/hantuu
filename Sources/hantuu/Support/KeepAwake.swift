import AppKit
import IOKit.pwr_mgt

/// A Keep awake session hantuu started and owns.
struct KeepAwakeSession: Equatable {
    var startedAt: Date
    var endsAt: Date
}

/// Why the last session ended.
struct KeepAwakeEnd: Equatable {
    enum Reason: String {
        /// Switched off with the switch, or the permission was removed.
        case manual
        /// No chat worked or ran background work for the idle limit.
        case idle
        case quit
        /// Below the battery limit while unplugged.
        case battery
        /// ProcessInfo thermal state reached serious or critical.
        case thermal
        /// The session's end time came.
        case timeLimit
        /// hantuu stopped without switching it off. Put right by the crash check or the next launch.
        case stopped
        /// The crash check ended a session that ran 10 minutes past its end.
        case overdue
        /// Sleep was turned back on by something other than hantuu.
        case outside
    }
    var reason: Reason
    var at: Date
}

enum KeepAwakeBusy: Equatable { case turningOn, turningOff, removing }

/// What Keep awake needs from the Mac. The app uses `.live()`; the self test passes a fake
/// system, its own folders and clock, and fixed power and heat.
struct KeepAwakeEnvironment {
    var system: KeepAwakeSystem
    /// <data dir>/keep-awake: the journal, the guard script and its log, settings.
    var folder: URL
    var launchAgents: URL
    var user: String
    var uid: UInt32
    var pid: Int32
    var bundleID: String
    var now: () -> Date
    var power: () -> PowerState
    var thermal: () -> ProcessInfo.ThermalState
    var time: (Date) -> String
    /// The app: slow calls run off the main thread, and power and heat changes are watched.
    /// The self test runs everything inline.
    var live: Bool
    /// Test launches (HANTUU_NO_PMSET=1): no system calls at all.
    var disabled: Bool

    static func live() -> KeepAwakeEnvironment {
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        return KeepAwakeEnvironment(
            system: LiveKeepAwakeSystem(),
            folder: Paths.dataDir.appendingPathComponent("keep-awake", isDirectory: true),
            launchAgents: Paths.home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            user: NSUserName(), uid: getuid(), pid: getpid(),
            bundleID: Bundle.main.bundleIdentifier ?? "local.hantuu",
            now: Date.init, power: PowerReader.current, thermal: { ProcessInfo.processInfo.thermalState },
            time: { fmt.string(from: $0) },
            live: true, disabled: KeepAwake.systemAccessDisabled)
    }
}

/// Two ways hantuu keeps the Mac awake.
///
/// Automatic, always on: while any chat's agent is working, hantuu holds an idle-sleep
/// assertion, so the Mac doesn't doze off mid-task with the lid open. It needs no password and
/// lets go a minute after the last agent stops. Closing the lid still sleeps the Mac.
///
/// The Keep awake switch keeps the Mac running with the lid shut, even on battery, with
/// `pmset -a disablesleep 1`. That setting is global and outlives hantuu, so a session here
/// always ends by itself: after the session length, after a stretch with no agent working,
/// below a battery level while unplugged, when the Mac runs hot, and when hantuu quits. Turning
/// on goes through one administrator prompt, which also installs a sudoers rule allowing only
/// `/usr/bin/pmset -a disablesleep 0`, so every one of those endings can turn sleep back on
/// without a password. A journal written before sleep changes, plus a LaunchAgent that checks
/// it every minute, turns sleep back on if hantuu crashes. hantuu only ever ends an override
/// it started.
final class KeepAwake: ObservableObject {
    // MARK: Idle hold while agents work

    /// True while the automatic idle-sleep assertion is held for working agents.
    @Published private(set) var preventingIdleSleep = false
    private var workAssertion: IOPMAssertionID = 0
    private var workTimer: Timer?
    private(set) var lastWorkingAt: Date?
    /// How long the assertion outlives the last working agent, so the gap between one turn
    /// and the next (a background task reporting back, a quick reply) doesn't let the Mac sleep.
    static let workGrace: TimeInterval = 60

    // MARK: The Keep awake switch

    /// The last readback of `pmset -g`. nil when it couldn't be read.
    @Published private(set) var sleepDisabled: Bool?
    /// False until the setting has been read once.
    @Published private(set) var settingRead = false
    /// Set while hantuu owns the override.
    @Published private(set) var session: KeepAwakeSession?
    /// hantuu tried to end its session and couldn't confirm sleep is back on. Retried every minute.
    @Published private(set) var stuck = false
    @Published private(set) var lastEnd: KeepAwakeEnd?
    /// The last thing that went wrong, short for the footer and long for the tooltip.
    @Published private(set) var problem: (short: String, long: String)?
    @Published private(set) var busy: KeepAwakeBusy?
    /// The sudoers rule or the LaunchAgent is in place.
    @Published private(set) var permissionInstalled = false
    @Published private(set) var power: PowerState

    let env: KeepAwakeEnvironment
    let settings: KeepAwakeSettings
    private let queue = DispatchQueue(label: "hantuu.keep-awake")
    private var lastCheck: Date?
    /// Why a session that got stuck was ending, for when a retry succeeds.
    private var pendingReason: KeepAwakeEnd.Reason?
    private var activity: NSObjectProtocol?
    private var powerWatcher: PowerWatcher?
    private var thermalObserver: NSObjectProtocol?

    var journalURL: URL { env.folder.appendingPathComponent("journal") }
    var endedURL: URL { env.folder.appendingPathComponent("ended") }
    var guardScriptURL: URL { env.folder.appendingPathComponent("guard.sh") }
    var guardLogURL: URL { env.folder.appendingPathComponent("guard.log") }
    var plistURL: URL { env.launchAgents.appendingPathComponent("\(KeepAwakeFiles.guardLabel).plist") }

    /// What the switch shows.
    var isOn: Bool { session != nil || sleepDisabled == true }

    /// Test launches set HANTUU_NO_PMSET=1 so the app never calls pmset at all.
    static var systemAccessDisabled: Bool {
        ProcessInfo.processInfo.environment["HANTUU_NO_PMSET"] == "1" || CommandLine.arguments.contains("--no-pmset")
    }

    init(env: KeepAwakeEnvironment = .live(), settings: KeepAwakeSettings? = nil) {
        self.env = env
        self.settings = settings ?? KeepAwakeSettings(file: env.folder.appendingPathComponent("settings.json"))
        self.power = PowerState(onBattery: false, percent: nil)
    }

    // MARK: Idle hold

    /// Checks every few seconds whether any agent is working. `isWorking` reads the chats.
    func watchAgents(_ isWorking: @escaping () -> Bool) {
        workTimer?.invalidate()
        workTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.agentsWorking(isWorking())
        }
        agentsWorking(isWorking())
    }

    func agentsWorking(_ working: Bool, now: Date = Date()) {
        if working { lastWorkingAt = now }
        let hold = working || (lastWorkingAt.map { now.timeIntervalSince($0) < Self.workGrace } ?? false)
        if hold != preventingIdleSleep {
            preventingIdleSleep = hold
            // Test launches track the state but never touch the real power settings.
            if !Self.systemAccessDisabled && env.live {
                if hold {
                    IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "hantuu: agents are working" as CFString, &workAssertion)
                } else if workAssertion != 0 {
                    IOPMAssertionRelease(workAssertion)
                    workAssertion = 0
                }
            }
        }
        tick(now: now)
    }

    // MARK: Launch

    /// Reads the setting, and puts sleep back if an earlier hantuu left it off.
    func start() {
        guard !env.disabled else { return }
        refreshPermission()
        power = env.power()
        startWatching()
        perform(findAtLaunch) { finding in
            self.settingRead = true
            self.lastCheck = self.env.now()
            switch finding {
            case .nothing(let current, let end):
                self.sleepDisabled = current
                if let end { self.lastEnd = end }
            case .elsewhere(let current):
                self.sleepDisabled = current
            case .restored(let end):
                self.sleepDisabled = false
                self.lastEnd = end
                Log.write("keep awake: an earlier hantuu left sleep off; turned it back on")
            case .stuck(let s, let current):
                // Still off, and sudo couldn't put it back. Keep owning it so the limits, the
                // retry and the switch can still end it.
                self.session = s
                self.stuck = true
                self.pendingReason = .stopped
                self.sleepDisabled = current
                self.problem = ("Couldn't switch off", "Keep awake is still on from an earlier hantuu, and hantuu couldn't turn sleep back on. It tries again every minute. Switching it off here asks for your password.")
                self.holdActivity(true)
                Log.write("keep awake: an earlier hantuu left sleep off and sudo couldn't put it back")
            }
        }
    }

    enum LaunchFinding {
        case nothing(Bool?, KeepAwakeEnd?)
        case elsewhere(Bool?)
        case restored(KeepAwakeEnd)
        case stuck(KeepAwakeSession, Bool?)
    }

    private func findAtLaunch() -> LaunchFinding {
        let sys = env.system
        var guardEnd: KeepAwakeEnd?
        if let text = sys.read(endedURL) {
            guardEnd = Self.parseEnded(text)
            sys.remove(endedURL)
        }
        let current = readSleepDisabled()
        guard let j = sys.read(journalURL).flatMap(KeepAwakeJournal.parse) else { return .nothing(current, guardEnd) }
        // Another copy of hantuu that's still running owns it.
        if j.pid != env.pid && ownerRunning(j.pid) { return .elsewhere(current) }
        if current == false {
            sys.remove(journalURL)
            return .nothing(false, guardEnd)
        }
        let after = restoreSleep()
        if after == false {
            sys.remove(journalURL)
            return .restored(KeepAwakeEnd(reason: .stopped, at: env.now()))
        }
        let s = KeepAwakeSession(startedAt: j.startedAt, endsAt: j.endsAt)
        sys.write(KeepAwakeJournal(pid: env.pid, startedAt: s.startedAt, endsAt: s.endsAt).text, to: journalURL, permissions: 0o600)
        return .stuck(s, after)
    }

    // MARK: The switch

    func toggle() {
        guard busy == nil else { return }
        if isOn { switchOff(.manual, at: env.now()) } else { switchOn() }
    }

    func switchOn() {
        guard busy == nil, session == nil else { return }
        guard !env.disabled else {
            problem = ("Off in test launch", "Keep awake is disabled in this test launch.")
            return
        }
        busy = .turningOn
        problem = nil
        let hours = settings.sessionHours, limit = settings.batteryPercent
        perform({ self.performSwitchOn(hours: hours, batteryLimit: limit) }) { result in
            self.busy = nil
            self.settingRead = true
            self.refreshPermission()
            switch result {
            case .on(let s, let verified):
                self.session = s
                self.stuck = false
                self.sleepDisabled = verified ? true : nil
                self.lastEnd = nil
                self.lastCheck = self.env.now()
                self.holdActivity(true)
                Log.write("keep awake: on until \(s.endsAt)\(verified ? "" : " (readback failed)")")
            case .elsewhere:
                self.sleepDisabled = true
            case .cancelled:
                break
            case .refused(let short, let long):
                self.problem = (short, long)
            case .failed(let short, let long, let current):
                self.sleepDisabled = current
                self.problem = (short, long)
                Log.write("keep awake: couldn't turn on: \(long)")
            }
        }
    }

    enum OnResult {
        case on(KeepAwakeSession, verified: Bool)
        case elsewhere
        case cancelled
        case refused(String, String)
        case failed(String, String, Bool?)
    }

    func performSwitchOn(hours: Int, batteryLimit: Int) -> OnResult {
        let sys = env.system
        guard let before = readSleepDisabled() else {
            return .failed("Status unavailable", "Status unavailable: hantuu couldn't read the Mac's sleep setting, so Keep awake stayed off.", nil)
        }
        // Already off because of something else: say so, and don't claim it.
        if before { return .elsewhere }
        let p = env.power()
        if p.onBattery, let pct = p.percent, pct < batteryLimit {
            return .refused("Battery below \(batteryLimit)%", "Keep awake stayed off: the battery is at \(pct)%, below the \(batteryLimit)% limit. Plug in, or lower the limit in Settings.")
        }
        let heat = env.thermal()
        if heat == .serious || heat == .critical {
            return .refused("Mac too warm", "Keep awake stayed off: the Mac is running hot.")
        }
        guard KeepAwakeFiles.isPlainUserName(env.user) else {
            return .refused("Can't turn on", "Keep awake can't set up a sudoers rule for the account name \(env.user).")
        }
        let start = Date(timeIntervalSince1970: env.now().timeIntervalSince1970.rounded(.down))
        let s = KeepAwakeSession(startedAt: start, endsAt: start.addingTimeInterval(TimeInterval(hours) * 3600))
        // The journal goes down before anything changes, so a crash from here on is caught.
        guard sys.write(KeepAwakeJournal(pid: env.pid, startedAt: s.startedAt, endsAt: s.endsAt).text, to: journalURL, permissions: 0o600) else {
            return .failed("Couldn't turn on", "Keep awake stayed off: hantuu couldn't write its journal in \(env.folder.path).", false)
        }
        let hadGuard = sys.exists(plistURL.path)
        guard installGuard() else {
            sys.remove(journalURL)
            return .failed("Couldn't turn on", "Keep awake stayed off: hantuu couldn't start its crash check (launchctl bootstrap failed).", false)
        }
        // Tidies up after a first try that didn't go through, so nothing is left behind.
        func undo() {
            sys.remove(journalURL)
            if !hadGuard && !sys.exists(KeepAwakeFiles.sudoersPath) { uninstallGuard() }
        }
        switch sys.runAsAdministrator(KeepAwakeFiles.enableScript(user: env.user), prompt: KeepAwakeFiles.enablePrompt) {
        case .cancelled:
            undo()
            return .cancelled
        case .failed(let message):
            let current = readSleepDisabled()
            if current == true { return .on(s, verified: true) }
            undo()
            return .failed("Couldn't turn on", "Keep awake stayed off: \(message)", current)
        case .done:
            break
        }
        switch readSleepDisabled() {
        case true?: return .on(s, verified: true)
        case nil: return .on(s, verified: false)
        case false?:
            undo()
            return .failed("Couldn't turn on", "Keep awake stayed off: sleep was still on after the password prompt.", false)
        }
    }

    /// The switch, or a limit. Only a manual switch-off may ask for a password.
    func switchOff(_ reason: KeepAwakeEnd.Reason, at: Date) {
        guard !env.disabled, busy == nil else { return }
        let owned = session != nil
        guard owned || sleepDisabled == true else { return }
        busy = .turningOff
        perform({ self.performSwitchOff(owned: owned, allowPrompt: reason == .manual) }) { result in
            self.busy = nil
            self.apply(result, reason: reason, owned: owned, at: at)
        }
    }

    enum OffResult: Equatable {
        case off
        case stillOn(String)
        case unavailable
        case cancelled
    }

    func performSwitchOff(owned: Bool, allowPrompt: Bool) -> OffResult {
        let sys = env.system
        let sudo = sys.run("/usr/bin/sudo", ["-n"] + KeepAwakeFiles.restoreCommand)
        var after = readSleepDisabled()
        var why = sudo.error.trimmingCharacters(in: .whitespacesAndNewlines)
        if after != false && allowPrompt {
            switch sys.runAsAdministrator(KeepAwakeFiles.disableScript, prompt: KeepAwakeFiles.disablePrompt) {
            case .cancelled: return .cancelled
            case .failed(let m): why = m
            case .done: after = readSleepDisabled()
            }
        }
        if after == false {
            if owned { sys.remove(journalURL) }
            return .off
        }
        if after == nil { return .unavailable }
        return .stillOn(why.isEmpty ? "sleep is still switched off" : why)
    }

    private func apply(_ result: OffResult, reason: KeepAwakeEnd.Reason, owned: Bool, at: Date) {
        settingRead = true
        switch result {
        case .off:
            sleepDisabled = false
            endSession(reason, at: at)
        case .cancelled:
            break
        case .stillOn(let why):
            sleepDisabled = true
            if owned {
                stuck = true
                pendingReason = reason
            }
            problem = ("Couldn't switch off", "Keep awake is still on: hantuu couldn't turn sleep back on (\(why)). \(owned ? "It tries again every minute. " : "")Switching it off here asks for your password.")
            Log.write("keep awake: couldn't switch off (\(reason.rawValue)): \(why)")
        case .unavailable:
            sleepDisabled = nil
            if owned {
                stuck = true
                pendingReason = reason
            }
            problem = nil
        }
    }

    private func endSession(_ reason: KeepAwakeEnd.Reason, at: Date) {
        let had = session != nil
        session = nil
        stuck = false
        pendingReason = nil
        problem = nil
        env.system.remove(journalURL)
        if had || reason != .manual { lastEnd = KeepAwakeEnd(reason: reason, at: at) }
        holdActivity(false)
        Log.write("keep awake: off (\(reason.rawValue))")
    }

    /// One more hour (or `seconds`) on the session.
    func extend(by seconds: TimeInterval = 3600) {
        guard var s = session else { return }
        s.endsAt = max(s.endsAt, env.now()).addingTimeInterval(seconds)
        session = s
        env.system.write(KeepAwakeJournal(pid: env.pid, startedAt: s.startedAt, endsAt: s.endsAt).text, to: journalURL, permissions: 0o600)
    }

    /// hantuu is quitting. Synchronous, and never asks for a password: if sudo fails, the
    /// journal stays and the crash check takes over within a minute.
    func appWillQuit() {
        guard !env.disabled, session != nil else { return }
        let result = performSwitchOff(owned: true, allowPrompt: false)
        if result == .off {
            sleepDisabled = false
            endSession(.quit, at: env.now())
        }
        Log.write("keep awake: quit, switch-off \(result == .off ? "done" : "failed; the crash check will retry")")
    }

    // MARK: Limits

    /// Which limit, if any, ends the session now.
    func limitReached(now: Date) -> KeepAwakeEnd.Reason? {
        guard let s = session else { return nil }
        let heat = env.thermal()
        if heat == .serious || heat == .critical { return .thermal }
        let p = env.power()
        if p.onBattery, let pct = p.percent, pct < settings.batteryPercent { return .battery }
        if now >= s.endsAt { return .timeLimit }
        let idleSince = max(s.startedAt, lastWorkingAt ?? s.startedAt)
        if now.timeIntervalSince(idleSince) >= TimeInterval(settings.idleMinutes * 60) { return .idle }
        return nil
    }

    /// Every few seconds (from the agent check) and on power and heat changes: ends the session
    /// at a limit. Once a minute it also reads the setting back and retries a stuck switch-off.
    func tick(now: Date) {
        guard !env.disabled, busy == nil, settingRead || session != nil else { return }
        if session != nil, !stuck, let reason = limitReached(now: now) {
            switchOff(reason, at: now)
            return
        }
        if let last = lastCheck, now.timeIntervalSince(last) < 60 { return }
        lastCheck = now
        reconcile(now: now)
    }

    private func reconcile(now: Date) {
        let owned = session != nil, retry = stuck
        perform({ () -> (Bool?, Bool, KeepAwakeEnd?) in
            if retry { _ = self.env.system.run("/usr/bin/sudo", ["-n"] + KeepAwakeFiles.restoreCommand) }
            let current = self.readSleepDisabled()
            let journal = self.env.system.read(self.journalURL) != nil
            var guardEnd: KeepAwakeEnd?
            if owned, !journal, let t = self.env.system.read(self.endedURL) {
                guardEnd = Self.parseEnded(t)
                self.env.system.remove(self.endedURL)
            }
            return (current, journal, guardEnd)
        }) { current, journal, guardEnd in
            self.power = self.env.power()
            self.sleepDisabled = current
            self.settingRead = true
            guard let s = self.session else { return }
            if current == false {
                // Sleep is back on: a retry that worked, the crash check ending an overdue
                // session, or something outside hantuu.
                let reason = retry ? (self.pendingReason ?? .manual) : (guardEnd?.reason ?? .outside)
                self.endSession(reason, at: guardEnd?.at ?? now)
            } else if current == true && !journal {
                // Still ours: put the journal back so the crash check keeps watching.
                self.env.system.write(KeepAwakeJournal(pid: self.env.pid, startedAt: s.startedAt, endsAt: s.endsAt).text, to: self.journalURL, permissions: 0o600)
            }
        }
    }

    private func startWatching() {
        guard env.live, powerWatcher == nil else { return }
        powerWatcher = PowerWatcher { [weak self] in
            guard let self else { return }
            self.power = self.env.power()
            self.tick(now: self.env.now())
        }
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.tick(now: self.env.now())
        }
    }

    // MARK: Permission

    /// "Remove keep-awake permission": one administrator prompt removes the sudoers rule (and
    /// turns sleep back on first if hantuu has it off), then the LaunchAgent goes.
    func removePermission() {
        guard !env.disabled, busy == nil else { return }
        busy = .removing
        let owned = session != nil
        perform({ () -> (AdminResult, Bool?) in
            let sys = self.env.system
            if sys.exists(KeepAwakeFiles.sudoersPath) || owned {
                let r = sys.runAsAdministrator(KeepAwakeFiles.removeScript(restoreSleep: owned), prompt: KeepAwakeFiles.removePrompt)
                if r != .done { return (r, nil) }
            }
            self.uninstallGuard()
            return (.done, self.readSleepDisabled())
        }) { result, after in
            self.busy = nil
            self.refreshPermission()
            switch result {
            case .done:
                Log.write("keep awake: permission removed")
                self.sleepDisabled = after
                guard owned else { break }
                if after == false {
                    self.endSession(.manual, at: self.env.now())
                } else {
                    // Sleep didn't come back on. With the rule gone, only a password can end it.
                    self.stuck = true
                    self.pendingReason = .manual
                    self.problem = ("Couldn't switch off", "The permission is gone, but sleep is still switched off. Switching Keep awake off asks for your password.")
                }
            case .cancelled: break
            case .failed(let m): self.problem = ("Couldn't remove", "The keep-awake permission wasn't removed: \(m)")
            }
        }
    }

    private func refreshPermission() {
        permissionInstalled = env.system.exists(KeepAwakeFiles.sudoersPath) || env.system.exists(plistURL.path)
    }

    /// Writes the guard script and the LaunchAgent, and loads it, unless it's already loaded as is.
    func installGuard() -> Bool {
        let sys = env.system
        let plist = KeepAwakeFiles.launchAgentPlist(scriptPath: guardScriptURL.path, logPath: guardLogURL.path, bundleID: env.bundleID)
        var changed = false
        if sys.read(guardScriptURL) != KeepAwakeFiles.guardScript {
            guard sys.write(KeepAwakeFiles.guardScript, to: guardScriptURL, permissions: 0o700) else { return false }
            changed = true
        }
        if sys.read(plistURL) != plist {
            guard sys.write(plist, to: plistURL, permissions: 0o644) else { return false }
            changed = true
        }
        let target = "gui/\(env.uid)/\(KeepAwakeFiles.guardLabel)"
        let loaded = sys.run("/bin/launchctl", ["print", target]).ok
        if loaded && !changed { return true }
        if loaded { _ = sys.run("/bin/launchctl", ["bootout", target]) }
        if sys.run("/bin/launchctl", ["bootstrap", "gui/\(env.uid)", plistURL.path]).ok { return true }
        // launchd can still be finishing the bootout. One more try.
        if env.live { Thread.sleep(forTimeInterval: 0.5) }
        return sys.run("/bin/launchctl", ["bootstrap", "gui/\(env.uid)", plistURL.path]).ok
    }

    private func uninstallGuard() {
        _ = env.system.run("/bin/launchctl", ["bootout", "gui/\(env.uid)/\(KeepAwakeFiles.guardLabel)"])
        env.system.remove(plistURL)
        env.system.remove(guardScriptURL)
    }

    // MARK: Reading the Mac

    /// `pmset -g`, read only. nil when it can't be read.
    func readSleepDisabled() -> Bool? {
        let r = env.system.run("/usr/bin/pmset", ["-g"])
        guard r.ok else { return nil }
        return Self.parseSleepDisabled(r.output)
    }

    /// `sudo -n` with the one command the sudoers rule allows, then a readback.
    private func restoreSleep() -> Bool? {
        _ = env.system.run("/usr/bin/sudo", ["-n"] + KeepAwakeFiles.restoreCommand)
        return readSleepDisabled()
    }

    /// Whether `pid` is a running hantuu (its executable is named hantuu).
    private func ownerRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let r = env.system.run("/bin/ps", ["-p", "\(pid)", "-o", "comm="])
        let comm = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && (comm == "hantuu" || comm.hasSuffix("/hantuu"))
    }

    /// `pmset -g` prints " SleepDisabled\t\t1" when disablesleep is on. With sleep allowed,
    /// current macOS leaves the line out, so a normal listing without it means 0. nil when
    /// the output isn't a pmset listing at all.
    static func parseSleepDisabled(_ output: String) -> Bool? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
        }
        if output.contains("Currently in use") || output.contains("System-wide power settings") { return false }
        return nil
    }

    /// The crash check's note of what it did: "reason=stopped|overdue" and "at=<epoch>".
    static func parseEnded(_ text: String) -> KeepAwakeEnd? {
        let f = KeepAwakeJournal.keyValues(text)
        guard let raw = f["reason"], let reason = KeepAwakeEnd.Reason(rawValue: raw), let at = f["at"].flatMap(Double.init) else { return nil }
        return KeepAwakeEnd(reason: reason, at: Date(timeIntervalSince1970: at))
    }

    // MARK: Plumbing

    /// Runs `work` off the main thread in the app (inline in the self test), then `done` on main.
    private func perform<T>(_ work: @escaping () -> T, then done: @escaping (T) -> Void) {
        guard env.live else { done(work()); return }
        queue.async {
            let r = work()
            DispatchQueue.main.async { done(r) }
        }
    }

    /// Keeps App Nap from delaying the limit checks while a session is on.
    private func holdActivity(_ on: Bool) {
        guard env.live else { return }
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Keep awake is on and checking its limits")
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }
}

/// The Keep awake limits, in `<data dir>/keep-awake/settings.json`.
final class KeepAwakeSettings: ObservableObject {
    static let idleChoices = [5, 10, 15, 30, 60]
    static let hourChoices = [1, 2, 4, 8, 12]
    static let batteryChoices = [10, 20, 30, 50]

    /// Ends the session after this many minutes with no chat working.
    @Published var idleMinutes = 10 { didSet { save() } }
    /// How long a session lasts before it ends by itself.
    @Published var sessionHours = 4 { didSet { save() } }
    /// Ends the session below this battery level while unplugged.
    @Published var batteryPercent = 20 { didSet { save() } }

    let file: URL
    private var loading = false

    private struct Stored: Codable {
        var idleMinutes: Int?
        var sessionHours: Int?
        var batteryPercent: Int?
    }

    init(file: URL) {
        self.file = file
        loading = true
        if let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            if let v = s.idleMinutes, Self.idleChoices.contains(v) { idleMinutes = v }
            if let v = s.sessionHours, Self.hourChoices.contains(v) { sessionHours = v }
            if let v = s.batteryPercent, Self.batteryChoices.contains(v) { batteryPercent = v }
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        Paths.ensure(file.deletingLastPathComponent())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(Stored(idleMinutes: idleMinutes, sessionHours: sessionHours, batteryPercent: batteryPercent)) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
