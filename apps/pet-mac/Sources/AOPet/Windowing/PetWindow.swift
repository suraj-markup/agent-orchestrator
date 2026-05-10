import AppKit

/// Borderless, transparent, always-on-top NSWindow for a single project pet.
/// Click-through is OFF so the user can right-click for a context menu and
/// drag the pet around the screen.
final class PetWindow: NSWindow {
    /// Tracks `PetView.totalSize`. Callers normally pass an explicit
    /// size, but this default keeps `PetWindow()` instantiable from
    /// places that don't know the view geometry.
    static let defaultSize = NSSize(width: 240, height: 132)

    init(size: NSSize = PetWindow.defaultSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        ignoresMouseEvents = false
        isMovableByWindowBackground = true
        // Don't deactivate the foreground app when the user drags the pet.
        // Borderless windows can't become key by default, but allow it anyway
        // so the right-click menu works.
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Set true around code paths that move the window programmatically
    /// (the wander controller and the bubble auto-grow resize). The
    /// `windowDidMove` observer skips persistence while this is true,
    /// so wander steps don't overwrite the user's parked position. The
    /// flag's polarity matches the user-facing intent: programmatic
    /// moves should not trigger a "user picked this spot" save.
    var isProgrammaticMove: Bool = false

    /// Run `body` with `isProgrammaticMove == true` so any
    /// `setFrameOrigin` / `setFrame` inside is gated out of the
    /// position-save path. Always restores the previous value, so
    /// nested calls (e.g. wander resizing during bubble resize) work.
    func performProgrammatically(_ body: () -> Void) {
        let previous = isProgrammaticMove
        isProgrammaticMove = true
        body()
        isProgrammaticMove = previous
    }
}
