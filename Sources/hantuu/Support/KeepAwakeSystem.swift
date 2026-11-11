import AppKit
import IOKit.ps

/// What a command printed and how it ended.
struct CommandResult: Equatable {
    var status: Int32
    var output: String = ""
    var error: String = ""
    var ok: Bool { status == 0 }
}

/// How an administrator prompt ended.
enum AdminResult: Equatable {
    case done
    case cancelled
    case failed(String)
}

/// Every call Keep awake makes outside hantuu goes through this: commands (pmset -g, sudo,
/// launchctl, ps), the administrator prompt, and the files it reads and writes. The app uses
/// `LiveKeepAwakeSystem`. The self test uses a fake that records each call and returns
/// scripted answers, so it never touches the Mac's power settings, sudo, /etc or launchd.
protocol KeepAwakeSystem: AnyObject {
    func run(_ executable: String, _ arguments: [String]) -> CommandResult
    func runAsAdministrator(_ shellScript: String, prompt: String) -> AdminResult
    func read(_ url: URL) -> String?
    @discardableResult func write(_ text: String, to url: URL, permissions: Int) -> Bool
    func remove(_ url: URL)
    func exists(_ path: String) -> Bool
}

final class LiveKeepAwakeSystem: KeepAwakeSystem {
    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return CommandResult(status: -1, error: error.localizedDescription) }
        // Read stderr on the side so a chatty command can't fill one pipe while we wait on the other.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return CommandResult(status: p.terminationStatus,
                             output: String(decoding: outData, as: UTF8.self),
                             error: String(decoding: errData, as: UTF8.self))
    }

    /// macOS's standard administrator prompt, through AppleScript's `do shell script`.
    func runAsAdministrator(_ shellScript: String, prompt: String) -> AdminResult {
        // NSAppleScript belongs on the main thread. The prompt itself is another process, so the
        // wait is only as long as the typing.
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { self.runAsAdministrator(shellScript, prompt: prompt) }
        }
        var err: NSDictionary?
        let done = NSAppleScript(source: KeepAwakeFiles.appleScript(shellScript, prompt: prompt))?.executeAndReturnError(&err) != nil
        if done { return .done }
        if (err?[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        return .failed((err?[NSAppleScript.errorMessage] as? String) ?? "The administrator prompt failed.")
    }

    func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    func write(_ text: String, to url: URL, permissions: Int) -> Bool {
        Paths.ensure(url.deletingLastPathComponent())
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            return true
        } catch {
            Log.write("keep awake: couldn't write \(url.path): \(error.localizedDescription)")
            return false
        }
    }

    func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
}

// MARK: - Power

/// Where the Mac's power comes from, and the internal battery's charge.
struct PowerState: Equatable {
    var onBattery: Bool
    /// nil on a Mac without a battery, or when it can't be read.
    var percent: Int?
}

enum PowerReader {
    static func current() -> PowerState {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return PowerState(onBattery: false, percent: nil) }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        var percent: Int?
        if let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                      (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                      let now = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                percent = now * 100 / max
            }
        }
        return PowerState(onBattery: providing == kIOPSBatteryPowerValue, percent: percent)
    }
}

/// Calls back on the main run loop whenever the power source or the battery level changes.
final class PowerWatcher {
    private var source: CFRunLoopSource?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerWatcher>.fromOpaque(ctx).takeUnretainedValue().onChange()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            source = src
        }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}

// MARK: - The exact text of everything Keep awake installs or runs

enum KeepAwakeFiles {
    static let sudoersPath = "/etc/sudoers.d/hantuu-keepawake"
    static let guardLabel = "local.hantuu.keepawake-guard"
    /// The one command the sudoers rule allows. It can only turn sleep back on.
    static let restoreCommand = ["/usr/bin/pmset", "-a", "disablesleep", "0"]

    static let enablePrompt = "hantuu wants to keep your Mac awake, even with the lid shut. This also lets hantuu turn sleep back on later without asking for your password."
    static let disablePrompt = "hantuu wants to turn sleep back on."
    static let removePrompt = "hantuu wants to remove its keep-awake permission."

    /// Only a plain account name goes into the sudoers rule and the scripts.
    static func isPlainUserName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !name.hasPrefix("-")
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// The lines of /etc/sudoers.d/hantuu-keepawake. No line has a single quote, so each can be
    /// passed to printf in single quotes.
    static func sudoersLines(user: String) -> [String] {
        ["# hantuu Keep awake: lets this user turn sleep back on without a password, and nothing else.",
         "# Remove it from hantuu Settings, or delete this file.",
         "\(user) ALL = (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0"]
    }

    static func sudoers(user: String) -> String { sudoersLines(user: user).joined(separator: "\n") + "\n" }

    /// Writes the sudoers text into "$t". Part of the enable script, and run on its own by the self test.
    static func printfCommand(user: String) -> String {
        "/usr/bin/printf '%s\\n' " + sudoersLines(user: user).map { "'\($0)'" }.joined(separator: " ") + " > \"$t\""
    }

    /// Runs as root behind the one administrator prompt when Keep awake is switched on. It
    /// writes the rule into a root-owned temp file (so nothing else can swap it), checks it with
    /// `visudo -cf`, installs it with `install -m 0440 -o root -g wheel`, checks that sudo now
    /// allows the restore command, and only then turns sleep off. /etc/sudoers itself is never
    /// touched. Any failed step stops the script before sleep is changed.
    static func enableScript(user: String) -> String {
        [
            "set -e",
            "umask 077",
            "t=$(/usr/bin/mktemp /private/var/tmp/hantuu-keepawake.XXXXXX)",
            "trap '/bin/rm -f \"$t\"' EXIT",
            printfCommand(user: user),
            "/usr/sbin/visudo -cf \"$t\" >/dev/null 2>&1 || { echo 'The keep-awake sudoers rule failed its visudo check, so nothing was changed.' >&2; exit 3; }",
            "/usr/bin/install -m 0440 -o root -g wheel \"$t\" \(sudoersPath)",
            "/usr/bin/sudo -n -l -U \(user) /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1 || { /bin/rm -f \(sudoersPath); echo 'macOS did not accept the keep-awake sudoers rule, so sleep was left alone.' >&2; exit 4; }",
            "/usr/bin/pmset -a disablesleep 1",
        ].joined(separator: "; ")
    }

    /// For switching off by hand when sudo -n can't (the rule was removed).
    static let disableScript = "/usr/bin/pmset -a disablesleep 0"

    /// "Remove keep-awake permission". Turns sleep back on first when hantuu has it off.
    static func removeScript(restoreSleep: Bool) -> String {
        ((restoreSleep ? ["/usr/bin/pmset -a disablesleep 0"] : []) + ["/bin/rm -f \(sudoersPath)"])
            .joined(separator: "; ")
    }

    /// `do shell script "..." with prompt "..." with administrator privileges`.
    static func appleScript(_ shell: String, prompt: String) -> String {
        func literal(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "do shell script \(literal(shell)) with prompt \(literal(prompt)) with administrator privileges"
    }

    /// ~/Library/LaunchAgents/local.hantuu.keepawake-guard.plist: runs the guard script every
    /// 60 seconds, and once at login.
    static func launchAgentPlist(scriptPath: String, logPath: String, bundleID: String) -> String {
        func x(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(guardLabel)</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>/bin/sh</string>
        \t\t<string>\(x(scriptPath))</string>
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
        \t<string>\(x(logPath))</string>
        \t<key>AssociatedBundleIdentifiers</key>
        \t<string>\(x(bundleID))</string>
        </dict>
        </plist>

        """
    }

    /// The crash check launchd runs every minute. Fixed text: nothing from outside is pasted in.
    /// It finds the journal next to itself.
    static let guardScript = #"""
    #!/bin/sh
    # hantuu Keep awake crash check. launchd runs it every 60 seconds, from
    # ~/Library/LaunchAgents/local.hantuu.keepawake-guard.plist.
    #
    # While hantuu's Keep awake switch has sleep turned off, hantuu keeps a journal next to
    # this script. If that hantuu is no longer running (a crash, a force quit, a restart), or
    # its session ran more than 10 minutes past its end, this turns sleep back on with the one
    # command hantuu's sudoers rule allows, then clears the journal. It never turns sleep off,
    # and with no journal it does nothing, so a setting another app made is left alone.

    dir=${0%/*}
    journal="$dir/journal"
    [ -f "$journal" ] || exit 0

    owned=
    pid=
    ends=
    while IFS='=' read -r key value; do
        case $key in
            owned) owned=$value ;;
            pid) pid=$value ;;
            ends) ends=$value ;;
        esac
    done < "$journal"
    [ "$owned" = 1 ] || exit 0

    now=$(date +%s)

    log() {
        echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$dir/guard.log"
    }

    # Prints 1 when sleep is turned off, 0 when it's on, and nothing when pmset can't be read.
    sleep_disabled() {
        out=$(pmset -g 2>/dev/null) || return 0
        case $out in
            *SleepDisabled*)
                printf '%s\n' "$out" | while read -r name value rest; do
                    [ "$name" = SleepDisabled ] && echo "$value"
                done ;;
            *"Currently in use"*|*"System-wide power settings"*) echo 0 ;;
        esac
    }

    owner_running() {
        case $pid in ''|*[!0-9]*) return 1 ;; esac
        comm=$(ps -p "$pid" -o comm= 2>/dev/null)
        case $comm in */hantuu|hantuu) return 0 ;; esac
        return 1
    }

    overdue=0
    case $ends in
        ''|*[!0-9]*) ;;
        *) [ "$now" -ge $((ends + 600)) ] && overdue=1 ;;
    esac

    if owner_running; then
        [ "$overdue" = 1 ] || exit 0
        reason=overdue
    else
        reason=stopped
    fi

    state=$(sleep_disabled)
    if [ "$state" != 0 ]; then
        sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1
        state=$(sleep_disabled)
        [ "$state" = 0 ] && printf 'reason=%s\nat=%s\n' "$reason" "$now" > "$dir/ended"
    fi
    if [ "$state" = 0 ]; then
        rm -f "$journal"
        log "sleep is on again ($reason), journal cleared"
    else
        log "couldn't turn sleep back on ($reason), trying again in a minute"
    fi

    """#
}

/// hantuu's record that it turned sleep off, written before the change. The guard script and
/// the next launch read it to put sleep back after a crash.
struct KeepAwakeJournal: Equatable {
    var pid: Int32
    var startedAt: Date
    var endsAt: Date

    var text: String {
        "owned=1\npid=\(pid)\nstarted=\(Int(startedAt.timeIntervalSince1970))\nends=\(Int(endsAt.timeIntervalSince1970))\n"
    }

    static func parse(_ text: String) -> KeepAwakeJournal? {
        let f = keyValues(text)
        guard f["owned"] == "1", let pid = f["pid"].flatMap({ Int32($0) }),
              let s = f["started"].flatMap({ Double($0) }), let e = f["ends"].flatMap({ Double($0) }) else { return nil }
        return KeepAwakeJournal(pid: pid, startedAt: Date(timeIntervalSince1970: s), endsAt: Date(timeIntervalSince1970: e))
    }

    static func keyValues(_ text: String) -> [String: String] {
        var f: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { f[String(parts[0])] = String(parts[1]) }
        }
        return f
    }
}
