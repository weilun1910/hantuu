import AppKit
import CoreText
import GhosttyKit

extension SelfTest {
    static func terminalFonts(_ dir: URL) {
        let root = dir.appendingPathComponent("terminal-fonts", isDirectory: true)
        Paths.ensure(root)
        let file = root.appendingPathComponent("terminal-settings.json")
        try? Data(#"{"useGhosttyConfig":false}"#.utf8).write(to: file)
        var reloads: [Bool] = []
        let settings = TerminalSettings(file: file) { reloads.append($0) }
        check("fonts: old settings default to SF Mono 13", settings.fontFamily == "SF Mono" && settings.fontSize == 13 && !settings.useGhosttyConfig)
        check("fonts: bundled config lists SF Mono before JetBrains Mono", Paths.terminalTheme.flatMap {
            try? String(contentsOf: $0, encoding: .utf8)
        }?.contains("font-family = \"SF Mono\"\nfont-family = \"JetBrains Mono\"") == true)

        let registration = TerminalFonts.registration
        check("fonts: all Terminal.app weights register for the process", registration.found > 0 && registration.registered == registration.found && registration.available,
              "registered=\(registration.registered)/\(registration.found)")
        check("fonts: CoreText resolves SF Mono after registration",
              CTFontCopyFamilyName(CTFontCreateWithName("SFMono-Regular" as CFString, 13, nil)) as String == "SF Mono")
        let again = TerminalFonts.register(in: TerminalFonts.directory)
        check("fonts: registration tolerates already registered fonts", again.available && again.registered == registration.found)
        let missing = TerminalFonts.register(in: root.appendingPathComponent("Missing-Terminal.app/Contents/Resources/Fonts"))
        check("fonts: missing Terminal.app selects built-in fallback", !missing.available && missing.found == 0
              && settings.fontFamilies(sfMonoAvailable: missing.available) == ["JetBrains Mono"])
        check("fonts: effective font list preserves fallback order", settings.fontFamilies(sfMonoAvailable: true) == ["SF Mono", "JetBrains Mono"])

        settings.fontFamily = "Menlo"
        settings.fontSize = 18
        let restored = TerminalSettings(file: file)
        check("fonts: family and size persist", restored.fontFamily == "Menlo" && restored.fontSize == 18)
        check("fonts: family reloads and explicit size resets zoom", reloads == [false, true])
        settings.fontSize = 25
        check("fonts: upper size bound", settings.fontSize == 18)
        settings.fontSize = 2
        check("fonts: lower size bound", settings.fontSize == 11)
        settings.fontFamily = "bad\nfont-size = 99"
        check("fonts: saved family cannot inject config lines", settings.fontFamily == "SF Mono")
        settings.useGhosttyConfig = true
        let beforeIgnoredEdits = reloads.count
        settings.fontFamily = "JetBrains Mono"
        settings.fontSize = 16
        check("fonts: personal config ignores hantuu font controls", reloads.count == beforeIgnoredEdits
              && settings.fontConfig(sfMonoAvailable: true, useGhosttyConfig: true) == "font-family = \"\"\n")
        settings.useGhosttyConfig = false
        check("fonts: returning to hantuu preserves its selection", settings.fontFamily == "JetBrains Mono" && settings.fontSize == 16)
        check("fonts: built-in font has no duplicate fallback", settings.fontFamilies(sfMonoAvailable: true) == ["JetBrains Mono"])
        let installed = TerminalFonts.installedFamilies()
        check("fonts: picker includes defaults and installed monospace fonts", installed.starts(with: ["SF Mono", "JetBrains Mono"]) && installed.contains("Menlo") && Set(installed).count == installed.count)

        guard let ghostty = GhosttyApp.shared else { check("fonts: live engine exists", false); return }
        let liveFile = root.appendingPathComponent("live/terminal-settings.json")
        let userConfig = root.appendingPathComponent("user.ghostty")
        try? "font-family = Menlo\nfont-size = 12\n".write(to: userConfig, atomically: true, encoding: .utf8)
        var liveSettings: TerminalSettings!
        liveSettings = TerminalSettings(file: liveFile) { reset in
            ghostty.reloadConfig(settings: liveSettings, resetFontSize: reset, userConfigFiles: [userConfig])
        }
        defer {
            // Release the callback's capture and restore the self-test app's original config.
            liveSettings = nil
            ghostty.reloadConfig(resetFontSize: true)
        }
        ghostty.reloadConfig(settings: liveSettings, resetFontSize: true)
        let window = makeWindow()
        let chat = TerminalView(app: ghostty.app, launch: .init(workingDirectory: root.path, command: "/bin/cat"), handlesChildExit: true)
        let shell = TerminalView(app: ghostty.app, launch: .init(workingDirectory: root.path, command: "/bin/cat"), handlesChildExit: false)
        defer { chat.destroy(); shell.destroy() }
        chat.frame = NSRect(x: 0, y: 0, width: 800, height: 250)
        shell.frame = NSRect(x: 0, y: 250, width: 800, height: 250)
        window.contentView?.addSubview(chat)
        window.contentView?.addSubview(shell)
        let views = [chat, shell]
        check("fonts: live chat and panel shell use SF Mono 13", waitUntil(5) {
            views.allSatisfy { terminalFontMatches($0, family: "SF Mono", size: 13) && $0.cellSize.height > 0 }
        })
        let applied = try? String(contentsOf: liveSettings.fontConfigFile, encoding: .utf8)
        check("fonts: config handed to Ghostty resets then lists SF Mono and fallback", applied == "font-family = \"\"\nfont-family = \"SF Mono\"\nfont-family = \"JetBrains Mono\"\nfont-size = 13\n")
        let originalCells = views.map(\.cellSize)
        liveSettings.fontSize = 18
        check("fonts: changing size updates config and both live cell grids", waitUntil(5) {
            var size: Float = 0
            return ghostty_config_get(ghostty.config, &size, "font-size", 9) && size == 18
                && views.enumerated().allSatisfy { index, view in
                    terminalFontMatches(view, family: "SF Mono", size: 18)
                        && view.cellSize.height > originalCells[index].height && view.cellSize.width > originalCells[index].width
                }
        })
        liveSettings.fontFamily = "JetBrains Mono"
        check("fonts: changing family updates both live primary faces", waitUntil(5) {
            views.allSatisfy { terminalFontMatches($0, family: "JetBrains Mono", size: 18) }
        })
        chat.perform(binding: "increase_font_size:3")
        shell.setVisible(false)
        liveSettings.fontSize = 14
        check("fonts: explicit size replaces zoom and reaches hidden shells", waitUntil(5) {
            views.allSatisfy { terminalFontMatches($0, family: "JetBrains Mono", size: 14) }
        })
        let later = TerminalView(app: ghostty.app, launch: .init(workingDirectory: root.path, command: "/bin/cat"), handlesChildExit: false)
        check("fonts: new terminals inherit the current selection", waitUntil(5) {
            terminalFontMatches(later, family: "JetBrains Mono", size: 14)
        })
        later.destroy()
        shell.setVisible(true)
        liveSettings.useGhosttyConfig = true
        check("fonts: personal fixture config takes precedence", waitUntil(5) {
            views.allSatisfy { terminalFontMatches($0, family: "Menlo", size: 12) }
        })
        liveSettings.fontFamily = "SF Mono"
        liveSettings.fontSize = 13
        check("fonts: own settings cannot change personal config's live font", views.allSatisfy { terminalFontMatches($0, family: "Menlo", size: 12) })
        liveSettings.useGhosttyConfig = false
        check("fonts: disabling personal config restores SF Mono", waitUntil(5) {
            views.allSatisfy { terminalFontMatches($0, family: "SF Mono", size: 13) }
        })
        ghostty.reloadConfig(settings: liveSettings, resetFontSize: true, sfMonoAvailable: missing.available)
        check("fonts: missing Terminal.app renders with built-in JetBrains Mono", waitUntil(5) {
            views.allSatisfy { terminalFontMatches($0, family: "JetBrains Mono", size: 13) }
        })
        check("fonts: missing Terminal.app produces no config diagnostics", ghostty_config_diagnostics_count(ghostty.config) == 0)
        ghostty.reloadConfig(settings: liveSettings, resetFontSize: true)
        let previousDark = ghostty.surfaceScheme == GHOSTTY_COLOR_SCHEME_DARK
        defer { ghostty.setColorScheme(dark: previousDark) }
        for dark in [false, true] {
            ghostty.setColorScheme(dark: dark)
            check("fonts: SF Mono survives \(dark ? "dark" : "light") theme reload", waitUntil(5) {
                views.allSatisfy { terminalFontMatches($0, family: "SF Mono", size: 13) }
            })
        }
    }

    private static func terminalFontMatches(_ view: TerminalView, family: String, size: CGFloat) -> Bool {
        guard let surface = view.surface, let raw = ghostty_surface_quicklook_font(surface) else { return false }
        // libghostty returns a retained copy of the primary font at its logical point size.
        let font = Unmanaged<CTFont>.fromOpaque(raw).takeRetainedValue()
        return CTFontCopyFamilyName(font) as String == family && abs(CTFontGetSize(font) - size) < 0.1
    }
}
