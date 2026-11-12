import AppKit
import ImageIO

/// Preparation never changes source identity or silently degrades a failed image into a path.
enum ComposerAttachmentTransport {
    struct Failure: Error, LocalizedError, Equatable {
        var attachmentID: UUID?
        var message: String
        var errorDescription: String? { message }
    }

    static func failure(for files: [ComposerMessage.OutgoingFile]) -> Failure? {
        for file in files {
            if !FileManager.default.isReadableFile(atPath: file.path) {
                return Failure(message: "Attachment is missing or unreadable: \(URL(fileURLWithPath: file.path).lastPathComponent)")
            }
            if file.image, CGImageSourceCreateWithURL(URL(fileURLWithPath: file.path) as CFURL, nil) == nil {
                return Failure(message: "Image could not be decoded: \(URL(fileURLWithPath: file.path).lastPathComponent)")
            }
            if file.image, let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber,
               size.intValue == 0 {
                return Failure(message: "Image is empty or still preparing: \(URL(fileURLWithPath: file.path).lastPathComponent)")
            }
        }
        return nil
    }

    /// Main-thread API. `changed` lets drafts persist preparation transitions before completion.
    static func prepare(_ attachments: [ComposerAttachment], agentID: String,
                        changed: @escaping ([ComposerAttachment]) -> Void = { _ in },
                        completion: @escaping ([ComposerAttachment], Result<[ComposerMessage.OutgoingFile], Failure>) -> Void) {
        var updated = attachments
        var files: [ComposerMessage.OutgoingFile] = []
        func advance(_ index: Int) {
            guard index < updated.count else { return completion(updated, .success(files)) }
            let attachment = updated[index]
            func fail(_ message: String) {
                updated[index].preparation = .failed(message)
                changed(updated)
                completion(updated, .failure(Failure(attachmentID: attachment.id, message: message)))
            }
            if PastedImages.isPending(attachment.url) {
                updated[index].preparation = .preparing
                changed(updated)
                return PastedImages.whenReady(attachment.url) { advance(index) }
            }
            guard FileManager.default.isReadableFile(atPath: attachment.url.path) else {
                if case .failed(let reason) = PastedImages.preparation(for: attachment.url) { return fail(reason) }
                return fail("\(attachment.label) is missing or unreadable. Restore the file, retry, or remove it.")
            }
            let nativeImage = ComposerMessage.imageAgents.contains(agentID) && !attachment.isFolder && attachment.isPicture
            func finish(_ url: URL) {
                let file = ComposerMessage.OutgoingFile(path: url.path, image: nativeImage)
                if let error = failure(for: [file]) { return fail(error.message) }
                updated[index].preparedURL = url
                updated[index].preparation = .ready
                files.append(file)
                changed(updated)
                advance(index + 1)
            }
            if nativeImage && !attachment.isImage {
                updated[index].preparation = .preparing
                changed(updated)
                if let prepared = attachment.preparedURL, FileManager.default.isReadableFile(atPath: prepared.path) {
                    return finish(prepared)
                }
                guard let url = PastedImages.convert(attachment.url) else {
                    return fail("Could not convert \(attachment.label) to an image. Retry or remove it.")
                }
                return PastedImages.whenReady(url) { finish(url) }
            }
            finish(attachment.url)
        }
        advance(0)
    }
}

/// Only splits transport. Availability and native dispatch remain the provider's responsibility.
enum ComposerCommandTransport {
    struct Invocation: Equatable {
        var name: String
        var arguments: String
    }
    static func invocation(_ text: String) -> Invocation? {
        guard text.first == "/" else { return nil }
        let token = text.prefix { !$0.isWhitespace }
        let name = String(token.dropFirst())
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || "-_:.$".contains($0) }) else { return nil }
        return Invocation(name: name, arguments: String(text.dropFirst(token.count)).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
