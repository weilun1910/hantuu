import AppKit
import IOKit.pwr_mgt

/// The global "keep the Mac awake" switch. It keeps the Mac running with the lid shut via
/// `sudo pmset -a disablesleep 1` (and undoes it with `disablesleep 0`). Turning this on
/// runs that through macOS's standard administrator prompt and also holds an IOKit
/// no-sleep assertion while hantuu is open. The real state is read from `pmset -g` because
/// it can be changed outside the app.
final class KeepAwake: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var busy = false
    @Published private(set) var lastError: String?
    private var assertion: IOPMAssertionID = 0

    /// Test launches set HANTUU_NO_PMSET=1 so the app never calls pmset at all.
    static var systemAccessDisabled: Bool {
        ProcessInfo.processInfo.environment["HANTUU_NO_PMSET"] == "1" || CommandLine.arguments.contains("--no-pmset")
    }

    func refresh() {
        guard !Self.systemAccessDisabled else { return }
        DispatchQueue.global(qos: .utility).async {
            let out = Self.runPmsetQuery()
            let on = Self.parseSleepDisabled(out) ?? false
            DispatchQueue.main.async {
                self.isOn = on
                if on { self.holdAssertion() } else { self.releaseAssertion() }
            }
        }
    }

    func toggle() {
        guard !busy else { return }
        guard !Self.systemAccessDisabled else {
            lastError = "Keep awake is disabled in this test launch."
            return
        }
        let target = !isOn
        busy = true
        lastError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let script = "do shell script \"/usr/bin/pmset -a disablesleep \(target ? 1 : 0)\" with administrator privileges"
            var err: NSDictionary?
            let ok = NSAppleScript(source: script)?.executeAndReturnError(&err) != nil
            let out = Self.runPmsetQuery()
            let now = Self.parseSleepDisabled(out) ?? (ok ? target : !target)
            DispatchQueue.main.async {
                self.busy = false
                self.isOn = now
                if now { self.holdAssertion() } else { self.releaseAssertion() }
                if !ok, let e = err?[NSAppleScript.errorNumber] as? Int, e != -128 {
                    self.lastError = (err?[NSAppleScript.errorMessage] as? String) ?? "pmset failed"
                }
            }
        }
    }

    private func holdAssertion() {
        guard assertion == 0 else { return }
        let reason = "hantuu Keep awake" as CFString
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion)
    }

    private func releaseAssertion() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }

    /// Read-only query of the current power settings.
    private static func runPmsetQuery() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// `pmset -g` prints " SleepDisabled\t\t1" when disablesleep is on.
    static func parseSleepDisabled(_ output: String) -> Bool? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
        }
        return output.isEmpty ? nil : false
    }
}
