import AppKit

/// Rounded-rect speech bubble drawn above the pet. Hidden when `text` is nil.
final class ThoughtBubbleView: NSView {
    var text: String? {
        didSet { needsDisplay = true }
    }

    /// Tint of the bubble border — set per priority so urgent events read red.
    var tint: NSColor = NSColor(white: 0.1, alpha: 1) {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let text = text, !text.isEmpty else { return }

        let inset: CGFloat = 4
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            xRadius: 6,
            yRadius: 6
        )

        NSColor(white: 1, alpha: 0.92).setFill()
        path.fill()
        tint.setStroke()
        path.lineWidth = 1
        path.stroke()

        // 13pt matches macOS body text. The bubble is sized to fit two
        // lines, and `truncatesLastVisibleLine` clips anything beyond
        // that with the system ellipsis.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]
        let textRect = bounds.insetBy(dx: inset + 6, dy: inset + 4)
        (text as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attrs
        )
    }
}
