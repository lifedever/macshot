import Cocoa
import XCTest

/// The default toolbar theme follows the system's light or dark appearance;
/// a theme the user chose stays as chosen.
@MainActor
final class ToolbarThemeTests: XCTestCase {

    private static let colourKeys = ["toolbarAccentColor", "toolbarIconColor", "toolbarBgColor"]

    private func withDefaultTheme(_ body: () throws -> Void) rethrows {
        try withDefaults(Dictionary(uniqueKeysWithValues: Self.colourKeys.map { ($0, nil as Any?) }), body)
    }

    private func withSystemAppearance(_ name: NSAppearance.Name, _ body: () -> Void) {
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = NSAppearance(named: name)
        defer { app.appearance = previous }
        body()
    }

    private func archived(_ color: NSColor) -> Data {
        try! NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false)
    }

    // MARK: - Marks drawn on the capture

    private func luma(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB)!
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    func testSnapGuidesAreALightTintOfTheThemesAccent() {
        // The guides mostly cross the dimmed scrim, where the accent itself
        // hardly shows; a lighter tint of it does, and keeps the theme's hue.
        let green = NSColor(srgbRed: 0.2, green: 0.6, blue: 0.3, alpha: 1)
        for accent in [ToolbarLayout.defaultAccentColor, green] {
            withDefaults(["toolbarAccentColor": archived(accent)]) {
                let guide = ToolbarLayout.snapGuideColor.usingColorSpace(.sRGB)!
                let base = accent.usingColorSpace(.sRGB)!
                XCTAssertGreaterThan(luma(guide), luma(base) + 0.15, "lighter than the accent")
                XCTAssertEqual(guide.hueComponent, base.hueComponent, accuracy: 0.02, "same hue")
            }
        }
        withDefaultTheme {
            XCTAssertEqual(ToolbarLayout.snapGuideColor.usingColorSpace(.sRGB)?.hueComponent ?? -1,
                           ToolbarLayout.defaultAccentColor.usingColorSpace(.sRGB)!.hueComponent,
                           accuracy: 0.02, "the default theme's guides are its purple, lightened")
        }
    }

    func testAPaleAccentIsDarkenedForHandleOutlines() {
        // A nearly white outline would vanish on light content.
        let pale = NSColor(srgbRed: 1.0, green: 0.97, blue: 0.8, alpha: 1)
        withDefaults(["toolbarAccentColor": archived(pale)]) {
            XCTAssertLessThan(luma(ToolbarLayout.accentMarkColor), luma(pale) - 0.1)
        }
    }

    func testTheDefaultThemeFollowsTheSystemAppearance() {
        withDefaultTheme {
            XCTAssertTrue(ToolbarLayout.usesDefaultTheme)
            withSystemAppearance(.aqua) {
                XCTAssertFalse(ToolbarLayout.isDarkSurface, "Light mode gets a light toolbar")
                XCTAssertEqual(ToolbarLayout.appearance?.name, .aqua)
            }
            withSystemAppearance(.darkAqua) {
                XCTAssertTrue(ToolbarLayout.isDarkSurface, "Dark mode gets a dark toolbar")
                XCTAssertEqual(ToolbarLayout.appearance?.name, .darkAqua)
            }
        }
    }

    func testAChosenThemeIgnoresTheSystemAppearance() {
        withDefaults(["toolbarBgColor": archived(NSColor(white: 0.1, alpha: 1))]) {
            withSystemAppearance(.aqua) {
                XCTAssertFalse(ToolbarLayout.usesDefaultTheme)
                XCTAssertTrue(ToolbarLayout.isDarkSurface, "a dark background the user picked stays dark")
            }
        }
    }

    func testHavingPickedTheOldDefaultMeansFollowingTheSystemNow() {
        withDefaults([
            "toolbarDefaultThemeFollowsSystem": nil,
            "toolbarAccentColor": archived(ToolbarLayout.defaultAccentColor),
            "toolbarIconColor": archived(ToolbarLayout.legacyDefaultIconColor),
            "toolbarBgColor": archived(ToolbarLayout.legacyDefaultBgColor),
        ]) {
            ToolbarLayout.migrateStoredDefaultTheme()
            XCTAssertTrue(ToolbarLayout.usesDefaultTheme)
        }
    }

    func testAnotherPresetSurvivesTheMigration() {
        withDefaults([
            "toolbarDefaultThemeFollowsSystem": nil,
            "toolbarAccentColor": archived(NSColor(calibratedRed: 0.00, green: 0.48, blue: 1.00, alpha: 1)),
            "toolbarIconColor": archived(.white),
            "toolbarBgColor": archived(NSColor(white: 0.12, alpha: 1)),
        ]) {
            ToolbarLayout.migrateStoredDefaultTheme()
            XCTAssertFalse(ToolbarLayout.usesDefaultTheme, "Classic is a choice, not the old default")
        }
    }
}
