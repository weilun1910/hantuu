import Foundation

/// Reuses the existing child tracker while keeping completed work at its launch location.
enum ReaderDelegation {
    static func applying(_ work: AgentWork?, to entries: [ReaderEntry]) -> [ReaderEntry] {
        guard let work else { return entries }
        return entries.map { entry in
            guard var operation = entry.operation else { return entry }
            var result = entry
            if let id = operation.childID, let child = work.subagents.first(where: { $0.id == id }) {
                operation.state = ReaderEvidence.workState(child.state)
                operation.report = child.result ?? operation.report
                operation.duration = child.duration ?? operation.duration
                operation.childTranscript = child.transcript ?? operation.childTranscript
                operation.finishedAt = child.endedAt.map { ISO8601DateFormatter().string(from: $0) } ?? operation.finishedAt
                operation.activity = child.step
                result.operation = operation
            }
            return result
        }
    }
}

extension AppModel {
    /// Called on main after the background tracker has read only this session's files.
    func updateReaderWork(_ work: AgentWork, chatID: UUID, transcript: URL) {
        guard let chat = chats.first(where: { $0.id == chatID }), chat.transcriptPath == transcript.path,
              chat.readerWork != work else { return }
        let before = chat.allEntries
        var retained = work
        for index in retained.subagents.indices {
            if let prior = chat.readerWork?.subagents.first(where: { $0.id == retained.subagents[index].id }) {
                retained.subagents[index].result = retained.subagents[index].result ?? prior.result
                retained.subagents[index].transcript = retained.subagents[index].transcript ?? prior.transcript
            }
        }
        chat.readerWork = retained
        let after = chat.allEntries
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let changed = after.filter { old[$0.id] != $0 }
        if !changed.isEmpty { readerAppend.send((chatID, changed)) }
    }
}
