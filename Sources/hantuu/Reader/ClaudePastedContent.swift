import Foundation

/// Claude encloses a long native paste in a matching pair of numbered envelope tags.
/// Only a complete outer envelope is removed; quoted or malformed tags remain text.
enum ClaudePastedContent {
    static func unwrap(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("<pasted_content id=") else { return text }
        let pattern = #"\A<pasted_content id="([0-9]+)">\r?\n([\s\S]*)\r?\n</pasted_content id="\1">\z"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let body = Range(match.range(at: 2), in: text) else { return text }
        return String(text[body]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
