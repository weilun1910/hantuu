import Foundation
import Darwin
import CryptoKit

/// Native recovery owns text before the web process can disappear. Journal files never
/// contain transcript data and are scoped by project plus stable document ID.
struct EditorRecoveryRecord: Codable, Equatable {
    var projectID: UUID
    var documentID: UUID
    var path: String
    var realPath: String
    var text: String
    var baseline: String
    var baselineFingerprint: String
    var updated: Date

    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func matchesDisk(_ text: String) -> Bool { Self.fingerprint(text) == baselineFingerprint }
}

final class EditorRecoveryStore {
    let directory: URL
    private var pending: [UUID: DispatchWorkItem] = [:]
    private var records: [UUID: EditorRecoveryRecord] = [:]
    var onError: ((UUID, Error) -> Void)?

    init(directory: URL = Paths.dataDir.appendingPathComponent("editor-recovery", isDirectory: true)) {
        self.directory = directory
    }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    func read(_ id: UUID) -> EditorRecoveryRecord? {
        records[id] ?? (try? Data(contentsOf: url(id))).flatMap { try? JSONDecoder().decode(EditorRecoveryRecord.self, from: $0) }
    }
    func put(_ record: EditorRecoveryRecord) {
        records[record.documentID] = record
        pending[record.documentID]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush(record.documentID) }
        pending[record.documentID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    func flush(_ id: UUID) {
        pending[id]?.cancel()
        pending[id] = nil
        guard let record = records[id] else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            // Atomic replacement, with mode set before any text is written.
            let destination = url(id)
            let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: JSONEncoder().encode(record))
            try handle.synchronize()
            if rename(temporary.path, destination.path) != 0 { throw CocoaError(.fileWriteUnknown) }
        } catch { onError?(id, error) }
    }
    func remove(_ id: UUID) {
        pending[id]?.cancel()
        pending[id] = nil
        records[id] = nil
        do {
            if FileManager.default.fileExists(atPath: url(id).path) { try FileManager.default.removeItem(at: url(id)) }
        } catch { onError?(id, error) }
    }
}
