import AppKit

/// Monospaced system fonts, each made once and kept.
///
/// On macOS 27 `NSFont.monospacedSystemFont` and `monospacedDigitSystemFont`
/// now and then return nil, although they are declared non-null. Swift does
/// not check, the nil lands in a text-attributes dictionary, and CoreText
/// aborts the app when it copies it ("attempt to insert nil object",
/// `TAttributes::ApplyFont`). Asked for on every redraw — the pre-selection
/// colour picker asks dozens of times a second while it follows the pointer —
/// it was only a matter of time. Here each font is created once, checked by
/// its actual pointer (a plain nil check on a non-null type can be compiled
/// away), and a nil is never cached: the system font stands in and the next
/// call tries again.
nonisolated enum UIFonts {

    private struct Key: Hashable {
        let size: CGFloat
        let weight: CGFloat
        let digitsOnly: Bool
    }

    nonisolated(unsafe) private static var cache: [Key: NSFont] = [:]
    private static let lock = NSLock()

    static func monospaced(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        font(Key(size: size, weight: weight.rawValue, digitsOnly: false)) {
            NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        } fallback: { NSFont.systemFont(ofSize: size, weight: weight) }
    }

    static func monospacedDigit(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        font(Key(size: size, weight: weight.rawValue, digitsOnly: true)) {
            NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        } fallback: { NSFont.systemFont(ofSize: size, weight: weight) }
    }

    private static func font(_ key: Key, make: () -> NSFont, fallback: () -> NSFont) -> NSFont {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let made = make()
        if !isNil(made) {
            cache[key] = made
            return made
        }
        let standIn = fallback()
        return isNil(standIn) ? NSFont.systemFont(ofSize: key.size) : standIn
    }

    /// Whether a reference typed as non-null actually holds null.
    static func isNil(_ font: NSFont) -> Bool {
        unsafeBitCast(font, to: UnsafeRawPointer?.self) == nil
    }
}
