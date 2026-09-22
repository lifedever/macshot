import Cocoa

/// Transparent fullscreen overlay that marks the recorded region: everything
/// outside it is dimmed, and a border traces its edge. Click-through
/// (ignoresMouseEvents), so the user keeps working inside the region.
///
/// This is what marks the region *during* recording — the capture overlay is
/// torn down the moment recording starts, so nothing it draws survives.
class SelectionBorderOverlay: NSPanel {

    private let borderView: SelectionBorderView

    init(screen: NSScreen) {
        borderView = SelectionBorderView()
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar + 1
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        borderView.frame = NSRect(origin: .zero, size: screen.frame.size)
        borderView.autoresizingMask = [.width, .height]
        contentView = borderView
    }

    /// Set the selection rect in screen coordinates.
    func setSelectionRect(_ screenRect: NSRect) {
        // Convert screen coords to window-local coords
        let localRect = convertFromScreen(screenRect)
        borderView.selectionRect = localRect
        borderView.needsDisplay = true
    }
}

private class SelectionBorderView: NSView {

    var selectionRect: NSRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        guard selectionRect.width > 0, selectionRect.height > 0 else { return }

        // Dim everything outside the recorded region, matching the scrim the
        // selection had before recording began. A thin outline on its own is
        // easy to lose track of while working inside the region.
        //
        // Even-odd leaves the region itself untouched, so a full-screen
        // recording dims nothing. The scrim can never reach the recording:
        // SCStream crops to the region, and this only paints outside it.
        if !UserDefaults.standard.bool(forKey: "disableSelectionOutsideShadow") {
            let outside = NSBezierPath(rect: bounds)
            outside.append(NSBezierPath(rect: selectionRect))
            outside.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(OverlayView.selectionScrimAlpha).setFill()
            outside.fill()
        }

        // Match the pre-recording selection chrome: use the user's configured
        // accent color at the same alpha the hardcoded purple used.
        ToolbarLayout.accentColor.withAlphaComponent(0.8).setStroke()
        // Inset by -lineWidth so the stroke is entirely OUTSIDE the selection rect.
        // This prevents the border from appearing in the recording even if the
        // overlay window is captured (SCStream crops to the selection rect).
        let lineW: CGFloat = 1.5
        let path = NSBezierPath(rect: selectionRect.insetBy(dx: -lineW, dy: -lineW))
        path.lineWidth = lineW
        path.stroke()
    }
}
