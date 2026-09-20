import Cocoa

/// Trackpad haptics for alignment snapping, matching the feel of Sketch / Figma / Finder:
/// a single tap the moment a drag latches onto a guide, and another when it latches onto a
/// *different* one. Releasing a snap stays silent — otherwise every drag across open canvas
/// would buzz continuously.
///
/// `NSHapticFeedbackManager` is a no-op on Macs without a Force Touch trackpad and already
/// honours the system-wide "Force Click and haptic feedback" switch, so there is nothing to
/// feature-detect here. The user-facing toggle below is for people who keep system haptics on
/// but don't want them while annotating.
///
/// Each canvas owns its own instance: on a multi-display capture there is one OverlayView per
/// screen, and shared state would let one screen's guides suppress another's first tap.
struct SnapHapticFeedback {

    static let enabledKey = "snapHapticsEnabled"

    /// Guide coordinates are recomputed from mouse positions every drag event, so two frames
    /// that snapped to the same target can differ by a sub-point rounding wobble. Treat
    /// anything within half a point as the same guide, or the wobble machine-guns the tap.
    private static let sameGuideTolerance: CGFloat = 0.5

    /// The guide each axis is currently latched onto. This is an anchor, not "the previous
    /// frame's value": it only moves when a tap fires. Tracking the previous frame instead
    /// lets sub-tolerance wobble accumulate — six frames drifting 0.3pt each stay under the
    /// tolerance pairwise while wandering a full point away, and the drift eventually reads
    /// as a new guide and fires a spurious tap.
    private var latchedX: CGFloat?
    private var latchedY: CGFloat?

    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Report the guide coordinates produced by a snap pass. Call once per pass, after both
    /// axes are final — X and Y latching in the same frame is one event to the hand, so it
    /// must stay one tap.
    mutating func report(guideX: CGFloat?, guideY: CGFloat?) {
        let didLatchX = Self.didLatch(from: latchedX, to: guideX)
        let didLatchY = Self.didLatch(from: latchedY, to: guideY)

        // Move an anchor when that axis latches onto something new, and clear it when the
        // axis loses its guide — so re-acquiring the guide you just left is felt again.
        if didLatchX || guideX == nil { latchedX = guideX }
        if didLatchY || guideY == nil { latchedY = guideY }

        guard didLatchX || didLatchY, Self.isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
    }

    /// Forget the previous guides without firing. Used when a drag ends or snapping is turned
    /// off mid-gesture, so the next gesture's first snap is felt even if it lands on the same
    /// guide this one ended on.
    mutating func reset() {
        latchedX = nil
        latchedY = nil
    }

    /// True when this axis newly acquired a guide, or moved to a different one. Losing a guide
    /// (`to == nil`) is deliberately not a latch.
    private static func didLatch(from old: CGFloat?, to new: CGFloat?) -> Bool {
        guard let new else { return false }
        guard let old else { return true }
        return abs(old - new) > sameGuideTolerance
    }
}
