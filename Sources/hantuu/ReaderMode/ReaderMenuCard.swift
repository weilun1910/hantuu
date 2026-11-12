import AppKit

/// Native controls for a freshly observed menu. The controller owns every terminal key.
/// Long command context and option descriptions scroll without hiding the escape hatch.
final class ReaderMenuCard: NSView, NSTextFieldDelegate {
    var onChoose: ((String) -> Void)?
    var onSubmitText: ((String) -> Void)?
    private var inputField = NSTextField()
    var onKey: ((ReaderMenuKey) -> Void)?
    var onTerminal: (() -> Void)?
    private(set) var displayedMenu: ReaderMenu?
    private let scroll = NSScrollView()
    private let rows = NSStackView()
    private let toolbar = NSStackView()
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private var buttons: [NSButton] = []
    private var busy = false
    private var notice: String?
    var preferredHeight: CGFloat { displayedMenu == nil ? 0 : 310 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = rows
        toolbar.orientation = .horizontal
        toolbar.spacing = 12
        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .secondaryLabelColor
        for view in [scroll, toolbar, noticeLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: noticeLabel.topAnchor, constant: -4),
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            noticeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            noticeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            noticeLabel.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -8),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            toolbar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10), toolbar.heightAnchor.constraint(equalToConstant: 24),
        ])
        setAccessibilityIdentifier("reader-menu-card")
        isHidden = true
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(menu: ReaderMenu?, busy: Bool = false, notice: String? = nil) {
        isHidden = menu == nil
        guard displayedMenu != menu || self.busy != busy || self.notice != notice else { return }
        displayedMenu = menu; self.busy = busy; self.notice = notice
        for stack in [rows, toolbar] {
            for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        }
        buttons = []
        guard let menu else { return }
        addText(menu.title, heading: true)
        if !menu.context.isEmpty { addText(menu.context) }
        for (index, option) in menu.options.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(choose(_:)))
            let prefix = option.checked.map { $0 ? "[x] " : "[ ] " } ?? ""
            let number = option.number.map { "\($0). " } ?? ""
            button.title = number + prefix + option.label
            button.tag = index
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 12, weight: menu.selected == option.label ? .semibold : .regular)
            button.setButtonType(.momentaryChange)
            button.isEnabled = menu.actionable && !busy && notice == nil
            button.wantsLayer = true
            button.layer?.cornerRadius = 4
            button.toolTip = option.label + (option.detail.isEmpty ? "" : "\n" + option.detail)
            (button.cell as? NSButtonCell)?.wraps = true
            (button.cell as? NSButtonCell)?.usesSingleLineMode = false
            button.setAccessibilityLabel(button.title + (menu.selected == option.label ? ", highlighted" : ""))
            button.setAccessibilityIdentifier("reader-menu-option-\(index)")
            rows.addArrangedSubview(button)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -24).isActive = true
            let lineCount = max(1, Int(ceil(Double(button.title.count) / 65)))
            button.heightAnchor.constraint(equalToConstant: CGFloat(lineCount * 17 + 12)).isActive = true
            buttons.append(button)
            if !option.detail.isEmpty { addText(option.detail, secondary: true) }
        }
        if let input = menu.input {
            inputField = NSTextField()
            inputField.stringValue = input.value
            inputField.placeholderString = input.placeholder
            inputField.font = .systemFont(ofSize: 12)
            inputField.isEnabled = !busy && notice == nil && menu.actionable
            inputField.delegate = self
            inputField.setAccessibilityLabel(input.placeholder)
            inputField.translatesAutoresizingMaskIntoConstraints = false
            rows.addArrangedSubview(inputField)
            inputField.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -24).isActive = true
            inputField.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        addText(menu.footer.replacingOccurrences(of: " · ", with: " | "), secondary: true)
        addButton("Show Terminal", tag: -1, enabled: true)
        if menu.actionable {
            addButton("Cancel", tag: 0, enabled: !busy && notice == nil)
            if menu.input != nil { addButton("Submit answer", tag: 4, enabled: !busy && notice == nil) }
            if menu.allowsHorizontal {
                addButton("Left", tag: 1, enabled: !busy && notice == nil)
                addButton("Right", tag: 2, enabled: !busy && notice == nil)
            }
            if menu.allowsTab {
                addButton(menu.kind == .question ? "Next question" : "Tab", tag: 3, enabled: !busy && notice == nil)
            }
            if menu.agent == "codex", menu.kind == .question, menu.footer.lowercased().contains("tab to add notes") {
                addButton("Add notes", tag: 5, enabled: !busy && notice == nil)
            }
        }
        noticeLabel.stringValue = notice ?? menu.refusal ?? (busy ? "Waiting for the terminal to confirm the change..." : (menu.input != nil ? "Type your answer, then submit. Escape cancels." : "Choose an option, or use arrows and Return. Escape cancels."))
        updateColors()
    }

    private func addText(_ text: String, heading: Bool = false, secondary: Bool = false) {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: heading ? 13 : 12, weight: heading ? .semibold : .regular)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.isSelectable = true
        rows.addArrangedSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -24).isActive = true
    }
    private func addButton(_ title: String, tag: Int, enabled: Bool) {
        let button = NSButton(title: title, target: self, action: #selector(action(_:)))
        button.tag = tag
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.isEnabled = enabled
        toolbar.addArrangedSubview(button)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === inputField, !textView.hasMarkedText() else { return false }
        if commandSelector == NSSelectorFromString("insertNewline:") {
            if NSApp.currentEvent?.isARepeat != true { onSubmitText?(textView.string) }
            return true
        }
        if commandSelector == NSSelectorFromString("cancelOperation:") {
            if NSApp.currentEvent?.isARepeat != true { onKey?(.escape) }
            return true
        }
        return false
    }

    @objc private func submitText() { onSubmitText?(inputField.stringValue) }
    func focusInput() { if displayedMenu?.input != nil { window?.makeFirstResponder(inputField) } }

    @objc private func choose(_ button: NSButton) {
        guard let menu = displayedMenu, menu.options.indices.contains(button.tag) else { return }
        onChoose?(menu.options[button.tag].label)
    }
    @objc private func action(_ button: NSButton) {
        switch button.tag {
        case -1: onTerminal?()
        case 0: onKey?(.escape)
        case 1: onKey?(.left)
        case 2: onKey?(.right)
        case 3: onKey?(.tab)
        case 4: submitText()
        case 5: onKey?(.notes)
        default: break
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.background.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            for (index, button) in buttons.enumerated() {
                let selected = displayedMenu?.options.indices.contains(index) == true && displayedMenu?.options[index].label == displayedMenu?.selected
                button.layer?.backgroundColor = (selected ? Theme.ink(0.08) : NSColor.clear).cgColor
            }
        }
    }
}
