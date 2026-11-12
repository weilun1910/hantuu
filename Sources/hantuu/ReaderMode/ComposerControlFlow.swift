import AppKit

/// Secondary actions share one footer row and shed their labels when space is tight.
final class ComposerControlFlow: NSView {
    private struct Item {
        let button: NSButton
        let symbol: String
        let title: String
        let help: String?
        var width: CGFloat {
            let font = button.font ?? NSFont.systemFont(ofSize: 11)
            return ceil((title as NSString).size(withAttributes: [.font: font]).width) + (button is NSPopUpButton ? 24 : 6)
        }
    }
    private var items: [Item] = []
    var preferredWidth: CGFloat {
        let visible = items.filter { !$0.button.isHidden }
        return visible.reduce(0) { $0 + $1.width } + CGFloat(max(0, visible.count - 1)) * 6
    }

    func addArrangedSubview(_ button: NSButton, symbol: String) {
        items.append(Item(button: button, symbol: symbol, title: button.title, help: button.toolTip))
        button.setAccessibilityLabel(button.title)
        if button.toolTip == nil { button.toolTip = button.title }
        button.isBordered = false
        addSubview(button)
    }

    override func layout() {
        super.layout()
        let visible = items.filter { !$0.button.isHidden }
        guard !visible.isEmpty else { return }
        let compact = preferredWidth > bounds.width
        let gap: CGFloat = compact ? 2 : 6
        let iconWidth = min(22, max(0, (bounds.width - CGFloat(visible.count - 1) * gap) / CGFloat(visible.count)))
        var x: CGFloat = 0
        for item in visible {
            let button = item.button
            button.imagePosition = compact ? .imageOnly : .noImage
            let icon = compact ? NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title) : nil
            button.image = icon
            if let popup = button as? NSPopUpButton {
                popup.itemArray.forEach { $0.image = icon }
                popup.setAccessibilityLabel(popup.title)
                popup.toolTip = (item.help ?? item.title) + " Selected: " + popup.title + "."
            }
            let width = compact ? iconWidth : item.width
            button.frame = NSRect(x: x, y: (bounds.height - 22) / 2, width: width, height: 22)
            x += width + gap
        }
    }
}

/// AppKit owns the viewport size; the reader adjusts only its internal margins.
final class ReaderLayoutRoot: FillView {
    var onWidthChange: ((CGFloat) -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { onWidthChange?(newSize.width) }
    }
}
