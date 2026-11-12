import Combine
import Foundation
import SwiftUI

/// Which terminal config the chats and shells use. By default it's hantuu's own look
/// (Resources/terminal.ghostty). Turning on "Use my Ghostty config" loads the user's Ghostty
/// config files on top of it, so anything they set there wins. Stored in
/// <data dir>/terminal-settings.json, read before the terminal engine starts.
final class TerminalSettings: ObservableObject {
    static let shared = TerminalSettings(file: Paths.dataDir.appendingPathComponent("terminal-settings.json")) {
        GhosttyApp.shared?.reloadConfig(resetFontSize: $0)
    }

    @Published var useGhosttyConfig: Bool {
        didSet {
            guard useGhosttyConfig != oldValue else { return }
            save()
            onChange(true)
        }
    }

    @Published var fontFamily: String {
        didSet {
            let clean = Self.cleanFamily(fontFamily)
            if clean != fontFamily { fontFamily = clean }
            guard fontFamily != oldValue else { return }
            save()
            if !useGhosttyConfig { onChange(false) }
        }
    }

    @Published var fontSize: Int {
        didSet {
            let bounded = min(18, max(11, fontSize))
            if bounded != fontSize { fontSize = bounded }
            guard fontSize != oldValue else { return }
            save()
            if !useGhosttyConfig { onChange(true) }
        }
    }

    private struct Stored: Codable {
        var useGhosttyConfig: Bool?
        var fontFamily: String?
        var fontSize: Int?
    }
    private let file: URL
    private let onChange: (Bool) -> Void
    var fontConfigFile: URL { file.deletingLastPathComponent().appendingPathComponent("terminal-font.ghostty") }

    /// Tests supply a fixture file and reload callback, never the user's settings.
    init(file: URL, onChange: @escaping (Bool) -> Void = { _ in }) {
        self.file = file
        self.onChange = onChange
        let stored = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        useGhosttyConfig = stored?.useGhosttyConfig ?? false
        fontFamily = Self.cleanFamily(stored?.fontFamily ?? "SF Mono")
        fontSize = min(18, max(11, stored?.fontSize ?? 13))
    }

    private static func cleanFamily(_ family: String) -> String {
        let name = family.trimmingCharacters(in: .whitespacesAndNewlines)
        // A saved setting must stay one quoted config value, even if edited outside the app.
        guard !name.isEmpty, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !name.contains("\""), !name.contains("\\") else { return "SF Mono" }
        return name
    }

    func fontFamilies(sfMonoAvailable: Bool) -> [String] {
        let primary = fontFamily == "SF Mono" && !sfMonoAvailable ? "JetBrains Mono" : fontFamily
        return primary == "JetBrains Mono" ? [primary] : [primary, "JetBrains Mono"]
    }

    func fontConfig(sfMonoAvailable: Bool, useGhosttyConfig: Bool) -> String {
        // Repeated families append across files. Clear the shipped list before either
        // our selection or the user's config so their primary font really comes first.
        let reset = "font-family = \"\"\n"
        guard !useGhosttyConfig else { return reset }
        return reset + fontFamilies(sfMonoAvailable: sfMonoAvailable).map { "font-family = \"\($0)\"\n" }.joined()
            + "font-size = \(fontSize)\n"
    }

    private func save() {
        Paths.ensure(file.deletingLastPathComponent())
        if let data = try? JSONEncoder().encode(Stored(useGhosttyConfig: useGhosttyConfig, fontFamily: fontFamily, fontSize: fontSize)) {
            try? data.write(to: file, options: .atomic)
        }
    }
}

/// The Terminal section of Settings.
struct TerminalSettingsSection: View {
    @ObservedObject var settings = TerminalSettings.shared
    @State private var fonts = TerminalFonts.installedFamilies()

    var body: some View {
        Section("Terminal") {
            Toggle("Use my Ghostty config", isOn: $settings.useGhosttyConfig)
            HStack {
                Picker("Font", selection: $settings.fontFamily) {
                    ForEach(fontChoices, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                Stepper("\(settings.fontSize) pt", value: $settings.fontSize, in: 11...18)
                    .fixedSize()
                    .accessibilityLabel("Terminal font size")
            }
            .disabled(settings.useGhosttyConfig)
            Text(settings.useGhosttyConfig
                 ? "Your Ghostty config is loaded on top of hantuu's look, so anything you set there wins. hantuu only reads it. A theme = light:…,dark:… line in it follows the Appearance setting. The sidebar picks up new colours after you reopen hantuu."
                 : "Chats and shells use hantuu's own terminal look. Turn this on to use the fonts, colours and padding from your Ghostty config instead.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if settings.useGhosttyConfig {
                LabeledContent("Config") {
                    Text("~/Library/Application Support/com.mitchellh.ghostty/config.ghostty").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Button("Reload Ghostty Config") { GhosttyApp.shared?.reloadConfig() }
            }
        }
        .onAppear { fonts = TerminalFonts.installedFamilies() }
    }

    private var fontChoices: [String] {
        fonts.contains(settings.fontFamily) ? fonts : fonts + [settings.fontFamily]
    }
}
