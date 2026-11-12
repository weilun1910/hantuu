import Foundation

/// A read failure never clears the last successfully decoded conversation.
struct ReaderHealth: Codable, Equatable {
    var state: String
    var message: String

    static let locating = ReaderHealth(state: "locating", message: "Locating this conversation's transcript.")
    static let loading = ReaderHealth(state: "loading", message: "Loading conversation history.")
    static let connected = ReaderHealth(state: "ready", message: "")
    static let waiting = ReaderHealth(state: "waiting", message: "Connected. Waiting for a complete transcript record.")
    static let missing = ReaderHealth(state: "missing", message: "The transcript is not available yet. The last readable conversation is still shown.")
    static let unreadable = ReaderHealth(state: "unreadable", message: "The transcript could not be read. Retry reading or open the terminal.")
    static let incomplete = ReaderHealth(state: "incomplete", message: "The last record is incomplete. The reader is waiting for the provider to finish writing it.")
    static let malformed = ReaderHealth(state: "unsupported", message: "Some transcript records could not be decoded. The readable parts are still shown.")
    static let disconnected = ReaderHealth(state: "disconnected", message: "The agent process has ended. This is the last readable conversation.")
}
