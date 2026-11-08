import Combine
import Foundation
import SwiftUI

/// Which face a chat shows in the main area: the reader with a message box, or the agent's
/// own terminal. The agent always runs in its terminal; this only decides what's on top.
enum ChatFace: String, Codable {
    case reader, terminal
}

/// "Show chats as the reader" (off by default) and the chats flipped away from it with the
/// header button or Option-Cmd-R. Stored in <data dir>/chat-settings.json, the same way
/// TerminalSettings stores its switch.
final class ChatSettings: ObservableObject {
    static let shared = ChatSettings(file: Paths.dataDir.appendingPathComponent("chat-settings.json"))

    @Published var showChatsAsReader: Bool {
        didSet { if showChatsAsReader != oldValue { save() } }
    }
    /// Chats whose face differs from the default. Flipping a chat back to the default drops it.
    @Published private(set) var flipped: [UUID: ChatFace] = [:]

    let file: URL

    private struct Stored: Codable {
        var showChatsAsReader = false
        var flipped: [String: ChatFace]? = nil
    }

    init(file: URL) {
        self.file = file
        let stored = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        showChatsAsReader = stored?.showChatsAsReader ?? false
        var f: [UUID: ChatFace] = [:]
        for (k, v) in stored?.flipped ?? [:] { if let id = UUID(uuidString: k) { f[id] = v } }
        flipped = f
    }

    /// The face a chat gets unless it was flipped. Agents without a transcript hantuu can read
    /// would show an empty reader, so they keep the terminal.
    func defaultFace(for chat: Chat) -> ChatFace {
        showChatsAsReader && chat.agent.transcript != nil ? .reader : .terminal
    }

    func face(for chat: Chat) -> ChatFace { flipped[chat.id] ?? defaultFace(for: chat) }

    /// Flips one chat between the reader and its terminal, whatever the setting says.
    func toggle(_ chat: Chat) {
        let next: ChatFace = face(for: chat) == .reader ? .terminal : .reader
        flipped[chat.id] = next == defaultFace(for: chat) ? nil : next
        save()
    }

    /// Drops flips for chats that are gone.
    func forget(except ids: Set<UUID>) {
        let stale = flipped.keys.filter { !ids.contains($0) }
        guard !stale.isEmpty else { return }
        for id in stale { flipped[id] = nil }
        save()
    }

    private func save() {
        Paths.ensure(file.deletingLastPathComponent())
        var s = Stored(showChatsAsReader: showChatsAsReader)
        if !flipped.isEmpty { s.flipped = Dictionary(uniqueKeysWithValues: flipped.map { ($0.key.uuidString, $0.value) }) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) { try? data.write(to: file, options: .atomic) }
    }
}

/// The Chat section of Settings.
struct ChatSettingsSection: View {
    @ObservedObject var settings = ChatSettings.shared

    var body: some View {
        Section {
            Toggle("Show chats as the reader", isOn: $settings.showChatsAsReader)
        } header: { Text("Chat") } footer: {
            Text("Turn this on to read chats as easy-to-read text with a message box underneath, instead of the agent's terminal. The agent still runs in its terminal, and ⌥⌘R switches one chat between the two.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
