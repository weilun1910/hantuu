import AppKit

/// The message box's text view: plain text, Return sends, Shift-Return (or Option-Return)
/// starts a new line, and Esc stops a running agent. Files and pictures, pasted or dropped,
/// become attachments (`onAttach`); text pastes and drops stay plain text.
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
    var commandCatalog: [ReaderCommand] = [] { didSet { updateCommands() } }
    var allowsSkillMentions = false
    var onCommandQuery: (() -> Void)?
    var onCommandMenuChange: (() -> Void)?
    private(set) var commandSuggestions: [ReaderCommand] = []
    private(set) var commandSelection = 0
    private var dismissedCommandText: String?
    private var commandQuery: ReaderCommandLogic.Query?
    var commandMenuVisible: Bool { !commandSuggestions.isEmpty }

    func updateCommands() {
        let query = hasMarkedText() ? nil : ReaderCommandLogic.query(string, selection: selectedRange(), skills: allowsSkillMentions)
        let previous = commandSuggestions.indices.contains(commandSelection) ? commandSuggestions[commandSelection].token : nil
        let changed = query != commandQuery
        commandQuery = query
        commandSuggestions = query.flatMap { dismissedCommandText == string ? nil : ReaderCommandLogic.ranked(commandCatalog, query: $0) } ?? []
        commandSelection = changed ? 0 : (commandSuggestions.firstIndex { $0.token == previous } ?? 0)
        onCommandMenuChange?()
        if query != nil && changed && dismissedCommandText != string { onCommandQuery?() }
    }

    func dismissCommands() {
        dismissedCommandText = string
        commandSuggestions = []
        onCommandMenuChange?()
    }

    func completeCommand(at index: Int) {
        guard let query = commandQuery, commandSuggestions.indices.contains(index) else { return }
        let replacement = commandSuggestions[index].token + " "
        guard shouldChangeText(in: query.range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: query.range, with: NSAttributedString(string: replacement, attributes: typingAttributes))
        setSelectedRange(NSRange(location: query.range.location + (replacement as NSString).length, length: 0))
        didChangeText()
    }

    private func commandKey(_ code: UInt16) -> Bool {
        guard commandMenuVisible else { return false }
        switch code {
        case 53: dismissCommands()
        case 125, 126:
            commandSelection = (commandSelection + (code == 125 ? 1 : commandSuggestions.count - 1)) % commandSuggestions.count
            onCommandMenuChange?()
        case 48: completeCommand(at: commandSelection)
        case 36, 76:
            if let query = commandQuery, ReaderCommandLogic.shouldSend(query: query, selected: commandSuggestions[commandSelection]) {
                dismissCommands()
                onSend?()
            } else { completeCommand(at: commandSelection) }
        default: return false
        }
        return true
    }

    override func setSelectedRange(_ charRange: NSRange) {
        super.setSelectedRange(charRange)
        updateCommands()
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: flag)
        updateCommands()
    }
    /// Files or pictures from a paste or a drop. Returns false if there was nothing to attach.
    var onAttach: ((ComposerPasteboard.Content) -> Bool)?
    /// Backspace in an empty box takes out the last attachment. Returns true if it did.
    var onDeleteBackwardWhenEmpty: (() -> Bool)?

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
        selectedTextAttributes = [.backgroundColor: Theme.ink(0.16, light: 0.11)]
        registerForDraggedTypes(ComposerPasteboard.draggedTypes)
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
        if mods.isDisjoint(with: [.command, .control, .option, .shift]), commandKey(event.keyCode) { return }
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
        case 51 where string.isEmpty && mods.isDisjoint(with: [.command, .control, .option]):   // Backspace
            if onDeleteBackwardWhenEmpty?() != true { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }

    // Esc would otherwise open the completion list. AppKit can deliver it through the
    // responder action instead of keyDown, so both paths must reach the stop callback.
    override func complete(_ sender: Any?) {}
    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { super.cancelOperation(sender) }
        else if commandMenuVisible { dismissCommands() }
        else { _ = onEscape?() }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        if dismissedCommandText != string { dismissedCommandText = nil }
        updateCommands()
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
        // A picture alone on the clipboard isn't text, so NSTextView would grey Paste out.
        if item.action == #selector(paste(_:)) { return isEditable && ComposerPasteboard.hasContent(.general) }
        return super.validateMenuItem(item)
    }

    // MARK: Paste

    override func paste(_ sender: Any?) {
        if !paste(from: .general) { super.paste(sender) }
    }

    /// Files and pictures become attachments, and text goes in as plain text. Returns false
    /// when there was nothing it handled, so a plain paste can carry on.
    @discardableResult
    func paste(from pb: NSPasteboard) -> Bool {
        guard isEditable else { return false }
        let content = ComposerPasteboard.read(pb)
        switch content {
        case .files, .images, .pdf:
            return onAttach?(content) ?? false
        case .text(let s, let images):
            if !images.isEmpty { _ = onAttach?(.images(images)) }
            // Rich text marks each picture with U+FFFC; the pictures came along as attachments.
            let plain = s.replacingOccurrences(of: "\u{FFFC}", with: "")
            if plain == s && pb == .general { return false }   // NSTextView's own plain paste
            insertTyped(plain)
            return true
        case .nothing:
            return false
        }
    }

    // MARK: Dropping files and pictures

    private func dropIsAttachment(_ sender: NSDraggingInfo) -> Bool {
        ComposerPasteboard.dropHasAttachment(sender.draggingPasteboard)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = super.draggingEntered(sender)
        return dropIsAttachment(sender) ? .copy : op
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = super.draggingUpdated(sender)
        return dropIsAttachment(sender) ? .copy : op
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard dropIsAttachment(sender) else { return super.performDragOperation(sender) }
        let ok = ComposerPasteboard.receiveDrop(sender) { [weak self] content in _ = self?.onAttach?(content) }
        window?.makeFirstResponder(self)
        return ok
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
        p.minimumLineHeight = 21
        p.maximumLineHeight = 21
        return p
    }()
    static let lineHeight: CGFloat = 21
    static let text = Theme.pair(dark: NSColor(white: 0.92, alpha: 1), light: NSColor(white: 0.12, alpha: 1))
    static let placeholder = Theme.pair(dark: NSColor(white: 0.44, alpha: 1), light: NSColor(white: 0.6, alpha: 1))
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
        // A light circle on dark, a dark circle on light.
        if enabled {
            fill = Theme.pair(dark: NSColor(white: pressed ? 0.78 : (hovering ? 0.96 : 0.90), alpha: 1),
                              light: NSColor(white: pressed ? 0.32 : (hovering ? 0.10 : 0.16), alpha: 1))
        } else {
            fill = Theme.ink(0.07)
        }
        fill.setFill()
        circle.fill()
        let glyph = enabled ? Theme.pair(dark: NSColor(white: 0.08, alpha: 1), light: NSColor(white: 0.98, alpha: 1))
                            : Theme.pair(dark: NSColor(white: 0.45, alpha: 1), light: NSColor(white: 0.62, alpha: 1))
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

    // A real button to VoiceOver and other accessibility clients.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { kind == .send ? "Send" : "Stop \(agentName)" }
    override func isAccessibilityEnabled() -> Bool { active || kind == .stop }
    override func accessibilityPerformPress() -> Bool {
        guard active || kind == .stop, let action else { return false }
        return sendAction(action, to: target)
    }
}

/// A small borderless icon button for the message box's footer, with a faint hover square.
final class ComposerIconButton: NSControl {
    private let symbol: String
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    init(symbol: String, help: String) {
        self.symbol = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        toolTip = help
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)), let action { sendAction(action, to: target) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || pressed {
            Theme.ink(pressed ? 0.1 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?.withSymbolConfiguration(config) else { return }
        // Resolved now, while this view's appearance is the current one.
        let tint = Theme.pair(dark: NSColor(white: 1, alpha: hovering ? 0.75 : 0.45),
                              light: NSColor(white: 0, alpha: hovering ? 0.7 : 0.42)).usingColorSpace(.sRGB) ?? .gray
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            tint.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let s = img.size
        tinted.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { toolTip }
    override func accessibilityPerformPress() -> Bool {
        guard let action else { return false }
        return sendAction(action, to: target)
    }
}

/// The message box: attachments as a row of chips at the top, the text in a scroll view, and a
/// footer row with Add Files on the left and Send (or Stop) on the right. At least two lines
/// tall, it grows with the text up to `ComposerStyle.maxLines`. The frame and footer follow T3
/// Code's composer, in hantuu's greys.
final class ComposerBox: NSView {
    let textView = ComposerTextView.make()
    let scroll = NSScrollView()
    let action = ComposerActionButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    let attach = ComposerIconButton(symbol: "paperclip", help: "Add files (or drop or paste them on the box)")
    let strip = AttachmentStrip()
    let stripScroll = NSScrollView()
    var onHeightChange: (() -> Void)?
    /// The attachments changed: added, removed, or swapped for another chat's.
    var onAttachmentsChange: (() -> Void)?
    /// What goes out with the next message, in the order it was added.
    private(set) var attachments: [ComposerAttachment] = []
    static let padTop: CGFloat = 12
    static let padH: CGFloat = 16
    static let footer: CGFloat = 38
    static let minLines: CGFloat = 2
    /// The chips sit a little further out than the text, so their pictures line up with it.
    static let stripInset: CGFloat = 12
    static let stripTop: CGFloat = 10
    static let stripGap: CGFloat = 8
    private var scrollTop: NSLayoutConstraint!
    private var stripHeight: NSLayoutConstraint!

    var enabled = true {
        didSet { alphaValue = enabled ? 1 : 0.7 }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.documentView = textView
        stripScroll.drawsBackground = false
        stripScroll.borderType = .noBorder
        stripScroll.hasVerticalScroller = true
        stripScroll.autohidesScrollers = true
        stripScroll.scrollerStyle = .overlay
        stripScroll.verticalScrollElasticity = .none
        stripScroll.documentView = strip
        stripScroll.isHidden = true
        for v in [stripScroll, scroll, action, attach] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        scrollTop = scroll.topAnchor.constraint(equalTo: topAnchor, constant: Self.padTop)
        stripHeight = stripScroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stripScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.stripInset),
            stripScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.stripInset),
            stripScroll.topAnchor.constraint(equalTo: topAnchor, constant: Self.stripTop),
            stripHeight,
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padH),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padH),
            scrollTop,
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.footer),
            attach.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            attach.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            attach.widthAnchor.constraint(equalToConstant: 28),
            attach.heightAnchor.constraint(equalToConstant: 28),
            action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            action.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            action.widthAnchor.constraint(equalToConstant: 28),
            action.heightAnchor.constraint(equalToConstant: 28),
        ])
        textView.onTextChange = { [weak self] in self?.onHeightChange?() }
        textView.onAttach = { [weak self] content in self?.attach(content) ?? false }
        textView.onDeleteBackwardWhenEmpty = { [weak self] in
            guard let self, let last = self.attachments.last else { return false }
            self.remove(last.id)
            return true
        }
        strip.onRemove = { [weak self] id in
            guard let self else { return }
            self.remove(id)
            self.window?.makeFirstResponder(self.textView)
        }
        attach.target = self
        attach.action = #selector(addFiles)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The width the chips wrap in.
    private var stripWidth: CGFloat {
        let w = (bounds.width > 0 ? bounds.width : ReaderModeController.columnWidth) - Self.stripInset * 2
        return max(w, 120)
    }

    /// The chips' height, up to `AttachmentStrip.maxRows` rows; 0 with no attachments.
    var stripVisibleHeight: CGFloat {
        guard !attachments.isEmpty else { return 0 }
        let cap = ChipStyle.height * CGFloat(AttachmentStrip.maxRows) + ChipStyle.gap * CGFloat(AttachmentStrip.maxRows - 1)
        return min(strip.contentHeight(width: stripWidth), cap)
    }

    /// The box's height for the current text and attachments.
    var preferredHeight: CGFloat {
        let lines = min(max(textView.contentHeight, ComposerStyle.lineHeight * Self.minLines), ComposerStyle.lineHeight * ComposerStyle.maxLines)
        let chips = stripVisibleHeight
        let top = chips > 0 ? Self.stripTop + chips + Self.stripGap : Self.padTop
        return top + lines + Self.footer
    }

    // MARK: Attachments

    /// Replaces the attachments, for switching chats.
    func setAttachments(_ list: [ComposerAttachment]) {
        attachments = list
        attachmentsChanged()
    }

    func add(_ list: [ComposerAttachment]) {
        guard !list.isEmpty else { return }
        // The same file twice is one attachment.
        let have = Set(attachments.map { $0.url.standardizedFileURL.path })
        attachments += list.filter { !have.contains($0.url.standardizedFileURL.path) }
        attachmentsChanged()
    }

    func remove(_ id: ComposerAttachment.ID) {
        attachments.removeAll { $0.id == id }
        attachmentsChanged()
    }

    /// Files become attachments as they are; pictures without a file are saved first.
    @discardableResult
    func attach(_ content: ComposerPasteboard.Content) -> Bool {
        let list = ComposerAttachment.make(from: content, existing: attachments)
        guard !list.isEmpty else {
            NSSound.beep()
            return false
        }
        add(list)
        return true
    }

    private func attachmentsChanged() {
        strip.show(attachments)
        let h = stripVisibleHeight
        stripScroll.isHidden = attachments.isEmpty
        stripHeight.constant = h
        scrollTop.constant = h > 0 ? Self.stripTop + h + Self.stripGap : Self.padTop
        strip.frame = NSRect(x: 0, y: 0, width: stripWidth, height: strip.contentHeight(width: stripWidth))
        strip.needsLayout = true
        onAttachmentsChange?()
        onHeightChange?()
    }

    override func layout() {
        super.layout()
        // The chips rewrap when the box changes width.
        let w = stripWidth, h = strip.contentHeight(width: w)
        if strip.frame.width != w || strip.frame.height != h {
            strip.frame = NSRect(x: 0, y: 0, width: w, height: h)
            if stripHeight.constant != stripVisibleHeight { attachmentsChanged() }
        }
    }

    func updateColors() {
        let focused = window?.firstResponder === textView && window?.isKeyWindow == true
        // Layer colours don't follow the appearance by themselves, so resolve them in it.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.pair(dark: NSColor(white: 1, alpha: 0.045), light: NSColor.white).cgColor
            layer?.borderColor = Theme.ink(focused ? 0.14 : 0.085, light: focused ? 0.16 : 0.1).cgColor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    // Clicking anywhere in the frame puts the caret in the text.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }

    @objc private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "The files go with your next message."
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self, r == .OK else { return }
            self.attach(.files(panel.urls))
            self.window?.makeFirstResponder(self.textView)
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
    }
}
