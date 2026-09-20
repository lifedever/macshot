import Cocoa
import ScreenCaptureKit

/// Grabs the current desktop wallpaper so it can be used as a beautify background.
///
/// Reading the wallpaper *file* is not a workable path here: `desktopImageURL` points into
/// the user's own Pictures folder as often as into the read-only system set, and this app is
/// sandboxed without access to either. It also can't answer what a dynamic (time-of-day) or
/// aggregate wallpaper looks like *right now*, and returns nothing meaningful for a solid
/// colour desktop.
///
/// Screen-capturing the desktop sidesteps all of that: the app already holds Screen Recording
/// permission, and the result is by definition what the user is looking at — including
/// dynamic wallpapers at their current phase.
enum DesktopWallpaper {

    /// Capture the wallpaper currently shown on `screen`.
    /// Returns nil when the display can't be resolved or the capture fails; callers should
    /// leave the existing background in place rather than substituting anything.
    @available(macOS 14.0, *)
    static func capture(for screen: NSScreen) async -> NSImage? {
        guard let displayID = screen.displayID else { return nil }
        // `false` here keeps desktop-level windows in the list — the icon layer has to be
        // visible to us in order to be excluded below.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return nil }
        guard let display = content.displays.first(where: { $0.displayID == displayID })
        else { return nil }

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows(from: content))
        let config = SCStreamConfiguration()
        let scale = Int(screen.backingScaleFactor)
        config.width = display.width * scale
        config.height = display.height * scale
        config.showsCursor = false
        config.captureResolution = .best

        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Everything that is not wallpaper.
    ///
    /// Two groups, and the second is the non-obvious one. Regular windows — apps, the menu
    /// bar, the Dock, macshot's own overlay — all sit at layer 0 or above. The desktop *icon*
    /// layer does not: Finder draws it at a large negative layer, below every app but still
    /// **above** the wallpaper itself (measured: wallpaper -2147483624, icons -2147483603).
    /// So filtering by layer alone leaves the icons in the shot, and asking
    /// `SCShareableContent` to exclude desktop windows removes the wallpaper along with them.
    /// Excluding Finder by bundle id is what removes the icons and nothing else.
    ///
    /// Matching on bundle id rather than on the window's title is deliberate: window titles
    /// are localized user-facing strings (this machine reports Finder's as "应用程序"), while
    /// reverse-DNS bundle ids never are. Third-party wallpaper apps draw at negative layers
    /// too and are intentionally kept — for those users, that *is* the wallpaper.
    @available(macOS 14.0, *)
    private static func excludedWindows(from content: SCShareableContent) -> [SCWindow] {
        content.windows.filter { window in
            if window.owningApplication?.bundleIdentifier == "com.apple.finder" { return true }
            return window.windowLayer >= 0
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
