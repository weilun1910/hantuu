import Combine
import Foundation
import SwiftUI

/// Which terminal config the chats and shells use. By default it's hantuu's own look
/// (Resources/terminal.ghostty). Turning on "Use my Ghostty config" loads the user's Ghostty
/// config files on top of it, so anything they set there wins. Stored in
/// <data dir>/terminal-settings.json, read before the terminal engine starts.
final class TerminalSettings: ObservableObject {
    static let shared = TerminalSettings()

    @Published var useGhosttyConfig: Bool {
        didSet {
            guard useGhosttyConfig != oldValue else { return }
            save()
            GhosttyApp.shared?.reloadConfig()
        }
    }

    private struct Stored: Codable { var useGhosttyConfig = false }
    private static var file: URL { Paths.dataDir.appendingPathComponent("terminal-settings.json") }

    private init() {
        let stored = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        useGhosttyConfig = stored?.useGhosttyConfig ?? false
    }

    private func save() {
        Paths.ensure(Paths.dataDir)
        if let data = try? JSONEncoder().encode(Stored(useGhosttyConfig: useGhosttyConfig)) {
            try? data.write(to: Self.file, options: .atomic)
        }
    }
}

/// The Terminal section of Settings.
struct TerminalSettingsSection: View {
    @ObservedObject var settings = TerminalSettings.shared

    var body: some View {
        Section("Terminal") {
            Toggle("Use my Ghostty config", isOn: $settings.useGhosttyConfig)
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
    }
}
