import AppKit

extension AppModel {
    /// Acceptance only queues validation. Identity and cwd are checked again from disk
    /// before importing, and the native provider is never asked to start a replacement chat.
    @discardableResult
    func importHistory(_ record: ChatHistoryRecord, resume: Bool) -> Bool {
        guard ["claude", "codex"].contains(record.agentID),
              let sessionID = record.sessionID, UUID(uuidString: sessionID) != nil,
              record.identityVerified, !record.providerArchived, record.issue == nil else { return false }
        if let existing = chats.first(where: { $0.agentID == record.agentID && $0.sessionID?.lowercased() == sessionID.lowercased() }) {
            if existing.archivedAt != nil { restoreChat(existing) }
            select(existing.id)
            if resume, existing.status == .ended { self.resume(existing) }
            return true
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let verified = ChatHistoryIndex.verify(record)
            var isDirectory: ObjCBool = false
            let available = FileManager.default.fileExists(atPath: record.cwd, isDirectory: &isDirectory) && isDirectory.boolValue
            DispatchQueue.main.async {
                guard let self else { return }
                guard verified, available else {
                    let alert = NSAlert()
                    alert.messageText = "This saved session could not be resumed"
                    alert.informativeText = verified ? "Its working folder is unavailable. Locate the folder, then search again." : "The transcript changed or its identity could not be verified. Refresh history before resuming."
                    alert.runModal()
                    return
                }
                // A second request may have imported it while validation was on the worker.
                if let existing = self.chats.first(where: { $0.agentID == record.agentID && $0.sessionID?.lowercased() == sessionID.lowercased() }) {
                    if existing.archivedAt != nil { self.restoreChat(existing) }
                    self.select(existing.id)
                    if resume, existing.status == .ended { self.resume(existing) }
                    return
                }
                let project = self.addProject(path: record.cwd)
                let chat = Chat(projectID: project.id, agentID: record.agentID, createdAt: record.modifiedAt)
                chat.sessionID = sessionID
                chat.transcriptPath = record.transcriptPath
                chat.terminalTitle = record.title
                chat.status = .ended
                chat.resumeOnRetry = true
                self.chats.append(chat)
                self.beginTranscriptDiscovery(chat, cwd: record.cwd)
                self.select(chat.id)
                if resume { self.resume(chat) }
                self.scheduleSave()
            }
        }
        return true
    }
}
