import AppKit

/// Rounded-rect speech bubble drawn above the pet. Hidden when `text`
/// is nil. Wraps long text on word boundaries; callers measure
/// preferredHeight(forWidth:) to grow the containing window.
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

        let textRect = bounds.insetBy(
            dx: inset + Self.textInset,
            dy: inset + Self.textInsetY
        )
        (text as NSString).draw(
            with: textRect,
            options: Self.drawOptions,
            attributes: Self.textAttributes
        )
    }

    /// Rendered text height for `width`. Includes the same insets
    /// `draw(_:)` uses so the measurement and the rendered output agree
    /// — callers can plug the result straight into the bubble frame
    /// height. Returns 0 for empty / nil text.
    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        guard let text = text, !text.isEmpty else { return 0 }
        let inset: CGFloat = 4
        let usableWidth = max(0, width - (inset + Self.textInset) * 2)
        let bounding = (text as NSString).boundingRect(
            with: NSSize(width: usableWidth, height: .greatestFiniteMagnitude),
            options: Self.drawOptions,
            attributes: Self.textAttributes
        )
        return ceil(bounding.height) + (inset + Self.textInsetY) * 2
    }

    // MARK: - Shared text style

    /// 13pt matches macOS body text. Wrap on word boundaries; the
    /// caller's max-height clamp is the only safety net for runaway
    /// strings (`.truncatesLastVisibleLine` is intentionally absent —
    /// we want long messages to read in full when they fit).
    private static let textAttributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left
        return [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]
    }()

    private static let drawOptions: NSString.DrawingOptions = [
        .usesLineFragmentOrigin,
    ]

    private static let textInset: CGFloat = 6
    private static let textInsetY: CGFloat = 4
}
