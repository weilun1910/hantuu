import AppKit

/// An overlay above the composer. Buttons leave the keyboard in the message box, while
/// VoiceOver can still discover and activate each completion.
final class CommandMenu: NSScrollView {
    private let rows = NSStackView()
    var choose: ((Int) -> Void)?
    private var displayed: [ReaderCommand] = []
    private var selected = -1
    private var buttons: [NSButton] = []
    private var rowsHeight: NSLayoutConstraint!

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
            rows.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            rowsHeight,
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ commands: [ReaderCommand], selection: Int) {
        isHidden = commands.isEmpty
        guard displayed != commands || selected != selection else { return }
        displayed = commands
        selected = selection
        rowsHeight.constant = CGFloat(commands.count) * 42
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        buttons = []
        for (index, command) in commands.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(pick(_:)))
            button.tag = index
            button.isBordered = false
            button.alignment = .left
            button.focusRingType = .none
            button.setButtonType(.momentaryChange)
            button.wantsLayer = true
            let title = NSMutableAttributedString(string: command.token, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: ComposerStyle.text])
            if !command.argumentHint.isEmpty { title.append(NSAttributedString(string: " " + command.argumentHint, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])) }
            let source = command.source.isEmpty ? "" : "  |  " + command.source
            title.append(NSAttributedString(string: "\n" + command.description + source, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            button.attributedTitle = title
            (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
            (button.cell as? NSButtonCell)?.usesSingleLineMode = false
            button.toolTip = command.description + source
            button.setAccessibilityLabel(command.token + ", " + command.description + source)
            button.translatesAutoresizingMaskIntoConstraints = false
            rows.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 42).isActive = true
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                button.layer?.backgroundColor = (index == selection ? Theme.ink(0.09) : .clear).cgColor
            }
            buttons.append(button)
        }
        layoutSubtreeIfNeeded()
        if buttons.indices.contains(selection) { rows.scrollToVisible(buttons[selection].frame) }
    }

    @objc private func pick(_ sender: NSButton) { choose?(sender.tag) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for (index, button) in buttons.enumerated() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                button.layer?.backgroundColor = (index == selected ? Theme.ink(0.09) : NSColor.clear).cgColor
            }
        }
    }
}
