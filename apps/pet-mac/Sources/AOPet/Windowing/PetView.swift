import AppKit

/// The visible pet: sprite at the bottom, thought bubble at the top.
/// Forwards right-clicks to a delegate-provided NSMenu.
final class PetView: NSView {
    /// Default view size (matches `minBubbleHeight`). The view grows
    /// taller when a long bubble needs more room — see
    /// `preferredSize(forText:)`.
    static let totalSize = NSSize(width: 240, height: 132)
    /// The width of the view never changes; only the height varies.
    static let fixedWidth: CGFloat = 240
    private static let spriteSize = NSSize(width: 64, height: 64)
    /// Default bubble height — fits two lines of 13pt text comfortably.
    /// Bubble can grow up to `maxBubbleHeight` to fit wrapped text.
    static let minBubbleHeight: CGFloat = 52
    /// Hard ceiling so a runaway message can't push the window off
    /// screen. ~8 lines at 13pt body is plenty.
    static let maxBubbleHeight: CGFloat = 120
    static let edgeMargin: CGFloat = 8

    private let imageView = DraggableImageView(frame: .zero)
    let bubble = ThoughtBubbleView(frame: .zero)
    private let overlayView = MoodOverlayView(frame: .zero)

    /// `isMovableByWindowBackground` only kicks in for clicks AppKit can
    /// route to the window background. Subviews that don't opt in
    /// consume the mouseDown first, so the drag never starts. Returning
    /// true here lets the user grab the window anywhere on PetView.
    override var mouseDownCanMoveWindow: Bool { true }

    /// Lazily provided by the controller — we ask for it on each right-click
    /// so menu items can reflect current state (project name, sprite name).
    var menuProvider: (() -> NSMenu?)?

    /// Notifies the controller that the view wants a new total size
    /// (driven by bubble auto-grow). The controller resizes the
    /// `PetWindow` so the bottom edge stays planted (sprite doesn't
    /// jump) and the bubble grows upward.
    var onPreferredSizeChange: ((NSSize) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.autoresizingMask = [.minXMargin, .maxYMargin]
        addSubview(imageView)

        bubble.autoresizingMask = [.maxXMargin, .minYMargin]
        bubble.isHidden = true
        addSubview(bubble)

        overlayView.autoresizingMask = [.minXMargin, .minYMargin]
        overlayView.isHidden = true
        addSubview(overlayView)

        relayout(bubbleHeight: PetView.minBubbleHeight)
    }

    /// Place subviews against the current `bounds` for a given bubble
    /// height. Sprite stays flush bottom-right; bubble takes the full
    /// top row; overlay sits on the upper-right corner of the sprite.
    private func relayout(bubbleHeight: CGFloat) {
        bubble.frame = NSRect(
            x: PetView.edgeMargin,
            y: bounds.height - bubbleHeight - PetView.edgeMargin,
            width: bounds.width - PetView.edgeMargin * 2,
            height: bubbleHeight
        )
        imageView.frame = NSRect(
            x: bounds.width - PetView.spriteSize.width - PetView.edgeMargin,
            y: PetView.edgeMargin,
            width: PetView.spriteSize.width,
            height: PetView.spriteSize.height
        )
        let overlaySide: CGFloat = 18
        overlayView.frame = NSRect(
            x: imageView.frame.maxX - overlaySide + 2,
            y: imageView.frame.maxY - overlaySide + 2,
            width: overlaySide,
            height: overlaySide
        )
    }

    /// Compute a (bubbleHeight, totalSize) pair that fits `text`,
    /// clamped to the [`minBubbleHeight`, `maxBubbleHeight`] range.
    /// Pure (no side effects) so tests can call it directly.
    static func preferredSize(forText text: String?, bubble: ThoughtBubbleView) -> (bubbleHeight: CGFloat, total: NSSize) {
        let bubbleWidth = fixedWidth - edgeMargin * 2
        let measured: CGFloat
        if let text = text, !text.isEmpty {
            bubble.text = text
            measured = bubble.preferredHeight(forWidth: bubbleWidth)
        } else {
            measured = minBubbleHeight
        }
        let bubbleHeight = min(max(ceil(measured), minBubbleHeight), maxBubbleHeight)
        let total = NSSize(
            width: fixedWidth,
            height: bubbleHeight + spriteSize.height + edgeMargin * 2
        )
        return (bubbleHeight, total)
    }

    func setOverlay(_ kind: MoodOverlayView.Kind?) {
        overlayView.kind = kind
        overlayView.isHidden = (kind == nil)
        overlayView.needsDisplay = true
    }

    func setImage(_ image: NSImage?) {
        imageView.image = image
    }

    func showBubble(text: String, tint: NSColor, durationSeconds: TimeInterval) {
        bubble.text = text
        bubble.tint = tint

        // Measure → resize the window → relayout against the new
        // bounds. Order matters: the controller must change the window
        // frame *before* we redraw subviews, otherwise the bubble's
        // computed Y is based on stale bounds.
        let (bubbleHeight, total) = PetView.preferredSize(forText: text, bubble: bubble)
        onPreferredSizeChange?(total)
        relayout(bubbleHeight: bubbleHeight)

        bubble.isHidden = false
        bubble.layer?.removeAllAnimations()

        let token = UUID()
        bubbleToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + durationSeconds) { [weak self] in
            guard let self = self, self.bubbleToken == token else { return }
            self.bubble.isHidden = true
            self.bubble.text = nil
            // Shrink back to the default size when the bubble fades.
            let minTotal = NSSize(
                width: PetView.fixedWidth,
                height: PetView.minBubbleHeight
                    + PetView.spriteSize.height
                    + PetView.edgeMargin * 2
            )
            self.onPreferredSizeChange?(minTotal)
            self.relayout(bubbleHeight: PetView.minBubbleHeight)
        }
    }
    private var bubbleToken: UUID?

    /// One-shot reaction overlay — vertical jump + brief tint flash.
    func playReaction(_ kind: ReactionKind) {
        let layer = imageView.layer ?? imageView.makeBackingLayer()
        imageView.wantsLayer = true
        imageView.layer = layer

        switch kind {
        case .flash:
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 1.0
            anim.toValue = 0.4
            anim.duration = 0.12
            anim.autoreverses = true
            anim.repeatCount = 2
            layer.add(anim, forKey: "flash")
        case .jump:
            let anim = CABasicAnimation(keyPath: "transform.translation.y")
            // Quartz layer Y is inverted relative to NSView Y, but for a brief
            // bounce either direction reads as a "jump".
            anim.fromValue = 0
            anim.toValue = -8
            anim.duration = 0.18
            anim.autoreverses = true
            anim.repeatCount = 1
            layer.add(anim, forKey: "jump")
        case .shake:
            let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
            anim.values = [0, -4, 4, -3, 3, 0]
            anim.duration = 0.32
            layer.add(anim, forKey: "shake")
        case .bounce:
            let anim = CABasicAnimation(keyPath: "transform.scale")
            anim.fromValue = 1.0
            anim.toValue = 1.08
            anim.duration = 0.12
            anim.autoreverses = true
            anim.repeatCount = 1
            layer.add(anim, forKey: "bounce")
        }
    }

    enum ReactionKind {
        case flash, jump, shake, bounce

        static func forPriority(_ priority: EventPriority) -> ReactionKind {
            switch priority {
            case .urgent:  return .flash
            case .action:  return .jump
            case .warning: return .shake
            case .info, .unknown: return .bounce
            }
        }
    }

    // MARK: - Right-click menu

    override func menu(for event: NSEvent) -> NSMenu? {
        return menuProvider?() ?? nil
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() ?? nil {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

/// NSImageView subclass that lets clicks fall through to the window's
/// drag handling. Without this override the sprite swallows the mouseDown
/// before AppKit can begin the window drag, so dragging anywhere over the
/// cat would do nothing.
final class DraggableImageView: NSImageView {
    override var mouseDownCanMoveWindow: Bool { true }
}
