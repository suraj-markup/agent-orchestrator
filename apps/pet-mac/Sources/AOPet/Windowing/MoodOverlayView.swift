import AppKit

/// Small badge drawn over the corner of the sprite — a coloured disc with
/// a single glyph. Used to disambiguate mood states the oneko sheet does
/// not have a unique pose for (sad → red `!`, happy → green ✓).
final class MoodOverlayView: NSView {
    enum Kind: Equatable {
        case exclaim   // red `!` for sad
        case check     // green ✓ for happy
        case clock     // amber clock for alert (reserved; not used today)

        fileprivate var glyph: String {
            switch self {
            case .exclaim: return "!"
            case .check:   return "✓"
            case .clock:   return "⏱"
            }
        }

        fileprivate var fillColor: NSColor {
            switch self {
            case .exclaim: return NSColor.systemRed
            case .check:   return NSColor.systemGreen
            case .clock:   return NSColor.systemOrange
            }
        }
    }

    var kind: Kind?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let kind = kind, let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        defer { ctx.restoreGraphicsState() }

        let inset: CGFloat = 1
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))
        kind.fillColor.setFill()
        circle.fill()

        NSColor.white.setStroke()
        circle.lineWidth = 1
        circle.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: kind.glyph, attributes: attrs)
        let size = str.size()
        let origin = NSPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        )
        str.draw(at: origin)
    }
}
