import AppKit

struct ComposerMentionQuery: Equatable {
    var range: NSRange
    var search: String
    static func parse(_ text: String, selection: NSRange) -> Self? {
        let ns = text as NSString
        guard selection.length == 0, selection.location <= ns.length else { return nil }
        var start = selection.location
        while start > 0 {
            let ch = ns.substring(with: NSRange(location: start - 1, length: 1))
            if ch.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { break }
            start -= 1
        }
        guard start < selection.location, ns.substring(with: NSRange(location: start, length: 1)) == "@" else { return nil }
        let token = ns.substring(with: NSRange(location: start + 1, length: selection.location - start - 1))
        guard !token.contains("@"), !token.contains("'"), !token.contains("\"") else { return nil }
        // Replace the whole active token even when the caret sits in its middle.
        var end = selection.location
        while end < ns.length {
            let ch = ns.substring(with: NSRange(location: end, length: 1))
            if ch.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { break }
            end += 1
        }
        return Self(range: NSRange(location: start, length: end - start), search: token)
    }
}

struct ComposerMentionItem: Equatable {
    var relativePath: String
    var isDirectory: Bool
    /// A local path reference, never file bytes or a claim of native attachment upload.
    var insertion: String { "'" + ("./" + relativePath).replacingOccurrences(of: "'", with: "'\\''") + "' " }
}

/// Git supplies ignore-aware names only. No file contents, shell evaluation or network I/O.
enum ComposerMentionSearch {
    static func items(root: URL, query: String) throws -> [ComposerMentionItem] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return candidates(paths: plainFolderPaths(root: root), root: root, query: query)
        }
        return candidates(paths: data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }, root: root, query: query)
    }
    /// Non-Git projects still get local discovery. Skip hidden metadata, dependencies and
    /// generated folders; never traverse a symlink or read a file's contents.
    static func plainFolderPaths(root: URL) -> [String] {
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: canonical, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let ignored: Set<String> = ["node_modules", "vendor", "build", "dist", "target", "DerivedData", "Pods", "Carthage", "__pycache__", "venv", "coverage"]
        var result: [String] = []
        var visited = 0
        while let url = walk.nextObject() as? URL {
            visited += 1
            if visited > 50000 { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { walk.skipDescendants(); continue }
            if values.isDirectory == true {
                if ignored.contains(url.lastPathComponent) || url.lastPathComponent.hasSuffix(".noindex") { walk.skipDescendants() }
                continue
            }
            if values.isRegularFile == true {
                let prefix = canonical.path + "/"
                guard url.path.hasPrefix(prefix) else { continue }
                result.append(String(url.path.dropFirst(prefix.count)))
            }
        }
        return result
    }

    static func candidates(paths: [String], root: URL, query: String) -> [ComposerMentionItem] {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        var found: [String: ComposerMentionItem] = [:]
        let needle = query.lowercased()
        for path in paths {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                  !path.contains("\n"), !path.contains("\r") else { continue }
            let url = root.appendingPathComponent(path).standardizedFileURL
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(canonicalRoot + "/"), FileManager.default.fileExists(atPath: url.path) else { continue }
            found[path] = ComposerMentionItem(relativePath: path, isDirectory: false)
            var folder = (path as NSString).deletingLastPathComponent
            while !folder.isEmpty && folder != "." {
                found[folder] = ComposerMentionItem(relativePath: folder, isDirectory: true)
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        return Array(found.values.filter { needle.isEmpty || $0.relativePath.lowercased().contains(needle) }.sorted {
            let a = ($0.relativePath as NSString).lastPathComponent.lowercased().hasPrefix(needle)
            let b = ($1.relativePath as NSString).lastPathComponent.lowercased().hasPrefix(needle)
            if a != b { return a }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }.prefix(40))
    }
}

/// Reusable overlay. Controller places it above the composer, just like CommandMenu.
final class ComposerMentionMenu: NSScrollView {
    var onChoose: ((Int) -> Void)?
    private let rows = NSStackView()
    private var rowsHeight: NSLayoutConstraint!
    private var displayed: [ComposerMentionItem] = []
    private var selected = 0
    private var status: String?
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = true
        backgroundColor = Theme.background
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        wantsLayer = true
        layer?.cornerRadius = 8
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        documentView = rows
        rowsHeight = rows.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rows.topAnchor.constraint(equalTo: contentView.topAnchor),
            rows.widthAnchor.constraint(equalTo: contentView.widthAnchor), rowsHeight,
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(items: [ComposerMentionItem], selection: Int, status: String?) {
        displayed = items; selected = selection; self.status = status
        isHidden = items.isEmpty && status == nil
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        rowsHeight.constant = CGFloat(max(items.count, status == nil ? 0 : 1)) * 38
        if items.isEmpty, let status {
            let label = NSTextField(labelWithString: status)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            rows.addArrangedSubview(label)
            label.heightAnchor.constraint(equalToConstant: 38).isActive = true
        }
        for (index, item) in items.enumerated() {
            let button = NSButton(title: item.relativePath + (item.isDirectory ? "/" : ""), target: self, action: #selector(choose(_:)))
            button.tag = index
            button.isBordered = false
            button.alignment = .left
            button.image = NSImage(systemSymbolName: item.isDirectory ? "folder" : "doc", accessibilityDescription: nil)
            button.imagePosition = .imageLeft
            button.font = .systemFont(ofSize: 12)
            button.toolTip = "Insert local path: " + item.relativePath
            button.setAccessibilityLabel((item.isDirectory ? "Folder " : "File ") + item.relativePath)
            button.wantsLayer = true
            button.effectiveAppearance.performAsCurrentDrawingAppearance { button.layer?.backgroundColor = (index == selection ? Theme.ink(0.09) : .clear).cgColor }
            rows.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
        }
        layoutSubtreeIfNeeded()
        if rows.arrangedSubviews.indices.contains(selection) { rows.scrollToVisible(rows.arrangedSubviews[selection].frame) }
    }
    @objc private func choose(_ sender: NSButton) { onChoose?(sender.tag) }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        show(items: displayed, selection: selected, status: status)
    }
}
