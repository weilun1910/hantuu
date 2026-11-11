import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// The pop-out button on images and PDFs in the reader: opens the file as a tab in the Code
/// tab. Images the transcript holds only as data (pasted images, tool results) are written once
/// to `<data dir>/attachments/reader/`, named by a hash of their bytes, and opened from there.
enum ReaderPopout {
    static var folder: URL { Paths.dataDir.appendingPathComponent("attachments/reader", isDirectory: true) }

    static func open(_ msg: [String: Any], model: AppModel) {
        if let path = msg["path"] as? String, !path.isEmpty {
            guard FileManager.default.fileExists(atPath: path) else {
                Log.write("popout: \(path) doesn't exist")
                return
            }
            model.openFile(path, line: nil)
        } else if let data = msg["data"] as? String, let path = write(dataURL: data) {
            model.openFile(path, line: nil)
        }
    }

    /// Saves a data: URL's bytes (once) and returns the file's path.
    static func write(dataURL: String, into dir: URL = folder) -> String? {
        guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ",") else { return nil }
        let header = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma]
        let parts = header.split(separator: ";").map(String.init)
        let mime = parts.first?.lowercased() ?? ""
        let body = String(dataURL[dataURL.index(after: comma)...])
        let bytes: Data?
        if parts.contains("base64") {
            bytes = Data(base64Encoded: body, options: .ignoreUnknownCharacters)
        } else {
            bytes = body.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let bytes, !bytes.isEmpty else { return nil }
        let ext = UTType(mimeType: mime)?.preferredFilenameExtension ?? "bin"
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let url = dir.appendingPathComponent("\(hash.prefix(24)).\(ext)")
        if FileManager.default.fileExists(atPath: url.path) { return url.path }
        Paths.ensure(dir)
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            Log.write("popout: couldn't write \(url.path): \(error)")
            return nil
        }
        return url.path
    }
}
