import AppKit
import Combine
import SwiftUI

/// Light, dark, or whatever macOS is showing.
enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil lets the app follow macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// hantuu's appearance. Stored in <data dir>/appearance-settings.json.
///
/// It sets NSApp.appearance, and every window, the reader pages (through
/// prefers-color-scheme) and Theme's colours follow from that. Whenever the effective
/// appearance changes, including macOS switching while this is on System, the terminals
/// are told too, so the `theme = light:…,dark:…` line in the terminal config picks the
/// matching colours. That line is in hantuu's own look, and in the user's Ghostty config if
/// they use one like it.
final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()

    @Published var mode: AppearanceMode {
        didSet {
            guard mode != oldValue else { return }
            save()
            apply()
        }
    }

    private var observation: NSKeyValueObservation?
    private struct Stored: Codable { var mode: AppearanceMode = .system }
    private static var file: URL { Paths.dataDir.appendingPathComponent("appearance-settings.json") }

    private init() {
        let stored = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        mode = stored?.mode ?? .system
    }

    /// Sets the app's appearance. Call before the terminal engine starts, so the first
    /// terminals already open in the right colours.
    func apply() {
        NSApp.appearance = mode.nsAppearance
    }

    /// Keeps the terminals in step with the app's effective appearance from now on.
    func start() {
        apply()
        observation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { _, _ in
            let sync: () -> Void = { GhosttyApp.shared?.setColorScheme(dark: NSApp.effectiveAppearance.isDark) }
            if Thread.isMainThread { sync() } else { DispatchQueue.main.async(execute: sync) }
        }
    }

    private func save() {
        Paths.ensure(Paths.dataDir)
        if let data = try? JSONEncoder().encode(Stored(mode: mode)) {
            try? data.write(to: Self.file, options: .atomic)
        }
    }
}

/// The Appearance row at the top of Settings.
struct AppearanceSettingsSection: View {
    @ObservedObject var settings = AppearanceSettings.shared

    var body: some View {
        Section {
            Picker("Appearance", selection: $settings.mode) {
                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        } footer: {
            Text("The window, the reader and the terminals switch together. System follows macOS whenever it changes between light and dark.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
