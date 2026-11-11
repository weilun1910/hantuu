import AppKit
import UniformTypeIdentifiers

/// What the Code tab shows a file in. Text kinds open in the editor and can be saved; the rest
/// get a native viewer that fits the panel.
enum ViewerKind: String, Equatable {
    /// Code and plain text: the CodeMirror editor in the Code tab's web page.
    case text
    /// The editor, plus a rendered preview (the default).
    case markdown
    /// The editor, plus the drawing rendered in an img, which never runs its scripts.
    case svg
    /// The editor, plus a table.
    case csv
    /// PDFKit's PDFView: native scrolling, zoom, text selection and page shadows.
    case pdf
    /// NSImageView in a magnifying scroll view: HEIC, GIF (animated), PNG, JPEG, TIFF, WebP, RAW
    /// and everything else ImageIO reads.
    case image
    /// AVKit's AVPlayerView, sized to the video so there are no black bars.
    case video
    /// AVPlayerView's controls on their own.
    case audio
    /// QLPreviewView for the long tail: Office and iWork documents, RTF, 3D models, fonts.
    case quickLook
    /// Nothing can preview it: a quiet note with Reveal in Finder and Open With.
    case unsupported
    case directory
    case missing

    var isEditable: Bool { self == .text || self == .markdown || self == .svg || self == .csv }
    var hasPreview: Bool { self == .markdown || self == .svg || self == .csv }
    /// The page shows these. The others are native views.
    var usesPage: Bool { isEditable }
    /// Opening a link or a Files row sends these to the Code tab. Folders and files nothing can
    /// preview go to Finder instead.
    var opensInPanel: Bool { self != .directory && self != .missing && self != .unsupported }
}

enum FileKinds {
    /// Types Quick Look previews on a stock Mac that don't conform to one of the broad types
    /// below: Office, iWork and OpenDocument files.
    static let quickLookIdentifiers: Set<String> = [
        "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
        "org.openxmlformats.spreadsheetml.sheet", "com.microsoft.excel.xls",
        "org.openxmlformats.presentationml.presentation", "com.microsoft.powerpoint.ppt",
        "com.apple.iwork.pages.sffpages", "com.apple.iwork.pages.pages",
        "com.apple.iwork.keynote.sffkey", "com.apple.iwork.keynote.key",
        "com.apple.iwork.numbers.sffnumbers", "com.apple.iwork.numbers.numbers",
        "org.oasis-open.opendocument.text", "org.oasis-open.opendocument.spreadsheet",
        "org.oasis-open.opendocument.presentation", "com.apple.rtfd", "com.apple.flat-rtfd",
        "public.geometry-definition-format", "public.standard-tesselated-geometry-format",
        "public.polygon-file-format", "org.khronos.collada.digital-asset-exchange",
    ]
    static let quickLookTypes: [UTType] = [
        .rtf, .rtfd, .flatRTFD, .presentation, .spreadsheet, .threeDContent, .usdz, .realityFile,
        .sceneKitScene, .font, .epub, .webArchive,
    ]

    static func kind(of path: String) -> ViewerKind {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return .missing }
        let ext = (path as NSString).pathExtension.lowercased()
        let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        if isDir.boolValue {
            // Keynote, Pages and RTFD documents can be packages, which are folders on disk.
            if let type, type.conforms(to: .package), quickLooks(type) { return .quickLook }
            return .directory
        }
        switch ext {
        case "md", "markdown", "mdx": return .markdown
        case "svg": return .svg
        case "csv", "tsv": return .csv
        default: break
        }
        // Before the system's types: .ts is TypeScript here, not an MPEG stream.
        if PathDetector.textExtensions.contains(ext) { return .text }
        if let type {
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .audiovisualContent) { return .video }
            if quickLooks(type) { return .quickLook }
        }
        if PathDetector.kind(of: path) == .text { return .text }
        return .unsupported
    }

    static func quickLooks(_ type: UTType) -> Bool {
        if quickLookIdentifiers.contains(type.identifier) { return true }
        if quickLookTypes.contains(where: { type.conforms(to: $0) }) { return true }
        return quickLookIdentifiers.contains { id in UTType(id).map { type.conforms(to: $0) } ?? false }
    }

    /// "ZIP archive, 2 KB"
    static func describe(_ path: String) -> String {
        let ext = (path as NSString).pathExtension
        let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        var kind = type?.localizedDescription ?? "File"
        if kind.isEmpty { kind = "File" }
        kind = kind.prefix(1).uppercased() + kind.dropFirst()
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
        guard let size else { return kind }
        return "\(kind), \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }

    /// The app that opens this file by default, if there is one.
    static func defaultApp(for path: String) -> (name: String, url: URL)? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path)) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return (name, url)
    }
}
