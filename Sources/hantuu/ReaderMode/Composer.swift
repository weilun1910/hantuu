import AppKit

/// The message box's text view: plain text, Return sends, Shift-Return (or Option-Return)
/// starts a new line, Esc stops a running agent, and dropped files become shell-escaped paths.
final class ComposerTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }
    var onSend: (() -> Void)?
    /// Esc. Returns true if it did something (stopped the agent).
    var onEscape: (() -> Bool)?
    /// Copy with nothing selected here: copy the reader's selection instead.
    var onCopyWithoutSelection: (() -> Void)?
    /// Page Up and Page Down scroll the reader, so reading never needs the mouse.
    var onPage: ((_ down: Bool) -> Void)?
    var onTextChange: (() -> Void)?

    static func make() -> ComposerTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let tv = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20), textContainer: container)
        tv.setUp()
        return tv
    }

    private func setUp() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFontPanel = false
        usesFindBar = false
        drawsBackground = false
        // Code and commands go through this box: no smart quotes, dashes or autocorrect.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = .zero
        font = ComposerStyle.font
        textColor = ComposerStyle.text
        insertionPointColor = ComposerStyle.text
        typingAttributes = [.font: ComposerStyle.font, .foregroundColor: ComposerStyle.text, .paragraphStyle: ComposerStyle.paragraph]
        defaultParagraphStyle = ComposerStyle.paragraph
        selectedTextAttributes = [.backgroundColor: NSColor(white: 1, alpha: 0.16)]
        registerForDraggedTypes([.fileURL, .string])
    }

    var text: String {
        get { string }
        set {
            string = newValue
            didChangeText()
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        // An input method that's composing (Japanese, Chinese, ...) gets Return and Esc first.
        if hasMarkedText() { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76:   // Return, keypad Enter
            if mods.contains(.shift) || mods.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else if mods.isDisjoint(with: [.command, .control]) {
                onSend?()
            } else {
                super.keyDown(with: event)
            }
        case 53:       // Esc
            if onEscape?() != true { super.keyDown(with: event) }
        case 116, 121: // Page Up, Page Down
            onPage?(event.keyCode == 121)
        default:
            super.keyDown(with: event)
        }
    }

    // Esc would otherwise open the completion list.
    override func complete(_ sender: Any?) {}
    override func cancelOperation(_ sender: Any?) {}

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        onTextChange?()
    }

    // MARK: Copy

    override func copy(_ sender: Any?) {
        if selectedRange().length == 0, let onCopyWithoutSelection {
            onCopyWithoutSelection()
        } else {
            super.copy(sender)
        }
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return true }
        return super.validateMenuItem(item)
    }

    // MARK: Dropping files

    private func dropHasFiles(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = super.draggingEntered(sender)
        return dropHasFiles(sender) ? .copy : op
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = super.draggingUpdated(sender)
        return dropHasFiles(sender) ? .copy : op
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard dropHasFiles(sender),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return super.performDragOperation(sender) }
        let at = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        insertPaths(urls, at: at)
        window?.makeFirstResponder(self)
        return true
    }

    /// Types the files' shell-escaped paths where they were dropped, with a space on either
    /// side unless there's one already.
    func insertPaths(_ urls: [URL], at index: Int? = nil) {
        insertTyped(paddedPaths(ComposerMessage.paths(urls), at: index ?? selectedRange().location), at: index)
    }

    /// Inserts text as if typed: undoable, and the caret ends up after it.
    func insertTyped(_ text: String, at index: Int? = nil) {
        guard !text.isEmpty else { return }
        let ns = string as NSString
        let loc = min(max(0, index ?? selectedRange().location), ns.length)
        let range = index == nil ? selectedRange() : NSRange(location: loc, length: 0)
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: typingAttributes))
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
    }

    private func paddedPaths(_ paths: String, at loc: Int) -> String {
        guard !paths.isEmpty else { return "" }
        let ns = string as NSString
        let before = loc > 0 && loc <= ns.length ? ns.substring(with: NSRange(location: loc - 1, length: 1)) : ""
        let after = loc < ns.length ? ns.substring(with: NSRange(location: loc, length: 1)) : ""
        let lead = before.isEmpty || before == " " || before == "\n" ? "" : " "
        let trail = after == " " || after == "\n" ? "" : " "
        return lead + paths + trail
    }

    // MARK: Placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: ComposerStyle.font, .foregroundColor: ComposerStyle.placeholder,
                                                    .paragraphStyle: ComposerStyle.paragraph]
        let origin = textContainerOrigin
        NSAttributedString(string: placeholder, attributes: attrs)
            .draw(in: NSRect(x: origin.x, y: origin.y, width: bounds.width - origin.x, height: bounds.height - origin.y))
    }

    /// Height of the text as laid out, at least one line.
    var contentHeight: CGFloat {
        guard let lm = layoutManager, let tc = textContainer else { return ComposerStyle.lineHeight }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        return max(ComposerStyle.lineHeight, ceil(used))
    }
}

enum ComposerStyle {
    static let font = NSFont.systemFont(ofSize: 14)
    static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = 20
        p.maximumLineHeight = 20
        return p
    }()
    static let lineHeight: CGFloat = 20
    static let text = NSColor(white: 0.92, alpha: 1)
    static let placeholder = NSColor(white: 0.42, alpha: 1)
    static let maxLines: CGFloat = 9
}

/// The send / stop button at the end of the message box: a small circle, light when there's
/// something to send, a square while the agent is working and the box is empty.
final class ComposerActionButton: NSControl {
    enum Kind { case send, stop }
    var kind: Kind = .send { didSet { needsDisplay = true; updateHelp() } }
    var active = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    var agentName = "the agent" { didSet { updateHelp() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        updateHelp()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    private func updateHelp() {
        toolTip = kind == .send ? "Send  ⏎" : "Stop \(agentName)  esc"
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        guard active || kind == .stop else { return }
        pressed = true
    }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)), let action { sendAction(action, to: target) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let enabled = active || kind == .stop
        let circle = NSBezierPath(ovalIn: r)
        let fill: NSColor
        if enabled {
            fill = NSColor(white: pressed ? 0.78 : (hovering ? 0.96 : 0.90), alpha: 1)
        } else {
            fill = NSColor(white: 1, alpha: 0.07)
        }
        fill.setFill()
        circle.fill()
        let glyph = enabled ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.45, alpha: 1)
        glyph.setStroke()
        glyph.setFill()
        let c = NSPoint(x: r.midX, y: r.midY)
        switch kind {
        case .send:
            // A thin up arrow.
            let p = NSBezierPath()
            p.lineWidth = 1.7
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.move(to: NSPoint(x: c.x, y: c.y - 5.5))
            p.line(to: NSPoint(x: c.x, y: c.y + 5.5))
            p.move(to: NSPoint(x: c.x - 4.5, y: c.y + 1))
            p.line(to: NSPoint(x: c.x, y: c.y + 5.5))
            p.line(to: NSPoint(x: c.x + 4.5, y: c.y + 1))
            p.stroke()
        case .stop:
            NSBezierPath(roundedRect: NSRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9), xRadius: 1.8, yRadius: 1.8).fill()
        }
    }

    override var isFlipped: Bool { false }
}

/// The message box: the text view in a scroll view, in a thin rounded frame, with the action
/// button at its trailing edge. It grows with the text up to `ComposerStyle.maxLines`.
final class ComposerBox: NSView {
    let textView = ComposerTextView.make()
    let scroll = NSScrollView()
    let action = ComposerActionButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    var onHeightChange: (() -> Void)?
    static let padV: CGFloat = 13
    static let padH: CGFloat = 14

    var enabled = true {
        didSet {
            alphaValue = enabled ? 1 : 0.55
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.cornerCurve = .continuous
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        action.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(action)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padH),
            scroll.trailingAnchor.constraint(equalTo: action.leadingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: Self.padV),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padV),
            action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            action.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            action.widthAnchor.constraint(equalToConstant: 28),
            action.heightAnchor.constraint(equalToConstant: 28),
        ])
        textView.onTextChange = { [weak self] in self?.onHeightChange?() }
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The box's height for the current text.
    var preferredHeight: CGFloat {
        let lines = min(textView.contentHeight, ComposerStyle.lineHeight * ComposerStyle.maxLines)
        return lines + Self.padV * 2
    }

    func updateColors() {
        let focused = window?.firstResponder === textView
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.035).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: focused ? 0.15 : 0.09).cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColors()
    }

    // Clicking anywhere in the frame puts the caret in the text.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }
}
