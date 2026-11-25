import Cocoa
import SwiftUI
import XCTest

/// The settings panes must show what the app actually does.
///
/// The SwiftUI rebuild gave several panes their own fallbacks and storage
/// types. A fresh install then saw "Save to file" while Return copied, "keep
/// 20" while history kept 10, and a thumbnail corner the card never read.
/// Worse, picking the option the pane already showed wrote nothing, so the
/// displayed value could not even be chosen.
@MainActor
final class SettingsConsistencyTests: XCTestCase {

    private static let capturePaneKeys = [
        "quickCaptureMode", "rememberLastTool", "thumbnailLetterbox", "imageQuality",
        "historySize", "historyOrderByLastEdit", "scrollAutoScrollEnabled",
        "scrollAutoScrollSpeed", "scrollMaxHeight", "beautifyShadowRadius",
        "thumbnailCorner", "thumbnailStacking", "historyUnlimited",
        OverlayView.boundarySnapStartEnabledKey, PinPlacement.userDefaultsKey,
        "openEditorAfterSelection", ThumbnailClickAction.userDefaultsKey,
        ThumbnailEditBehavior.userDefaultsKey, ImageSaveService.copyPathAfterSaveKey,
        "clipboardIncludesImageFormat",
    ]

    private func withFreshInstall(_ body: () throws -> Void) rethrows {
        try withDefaults(Dictionary(uniqueKeysWithValues: Self.capturePaneKeys.map { ($0, nil as Any?) }), body)
    }

    func testCapturePaneShowsTheBehaviourOfAFreshInstall() {
        withFreshInstall {
            let model = CaptureSettingsModel()
            // Return copies (quickCaptureMode 1) until the user picks otherwise.
            XCTAssertEqual(model.quickCaptureMode, 1)
            XCTAssertTrue(model.rememberLastTool, "the overlay remembers the last tool by default")
            XCTAssertTrue(model.thumbnailLetterbox, "the card letterboxes by default")
            XCTAssertEqual(model.imageQuality, Double(ImageEncoder.quality), accuracy: 0.0001)
            XCTAssertEqual(model.historySize, ScreenshotHistory.shared.maxEntries,
                           "the pane must not promise more history than retention keeps")
            XCTAssertEqual(model.historyOrderByLastEdit, ScreenshotHistory.orderByLastEdit)
            XCTAssertEqual(model.autoScroll, ScrollCaptureController.defaultAutoScrollEnabled)
            XCTAssertEqual(model.scrollSpeed, ScrollCaptureController.defaultAutoScrollSpeed)
            XCTAssertEqual(model.scrollMaxHeight, ScrollCaptureController.defaultMaxScrollHeight)
            XCTAssertEqual(model.beautifyShadowRadius, 20, "OverlayView falls back to a 20pt shadow")
            XCTAssertEqual(model.thumbnailStacking, 0, "cards stack by default")
            XCTAssertEqual(model.thumbnailCorner, 0, "cards start in the bottom-right corner")
            XCTAssertEqual(model.boundarySnapStart, OverlayView().boundarySnapStartEnabled,
                           "the pane shows whether a new selection's start snaps")
            XCTAssertEqual(model.quickCaptureMode, QuickCaptureMode.current.rawValue)
            XCTAssertEqual(model.pinPlacement, PinPlacement.current.rawValue)
            XCTAssertFalse(model.openEditorAfterSelection)
            XCTAssertEqual(model.thumbnailClickAction, ThumbnailClickAction.current.rawValue)
            XCTAssertEqual(model.thumbnailClickAction, ThumbnailClickAction.defaultValue.rawValue,
                           "a click on the card opens the editor until changed")
            XCTAssertEqual(model.thumbnailEditBehavior, ThumbnailEditBehavior.current.rawValue)
            XCTAssertEqual(model.copyPathAfterSave, ImageSaveService.copyPathAfterSave)
            XCTAssertEqual(model.clipboardIncludesImageFormat, ImageEncoder.clipboardIncludesImageFormat)
        }
    }

    func testToolsAndRecordingPanesShowWhatTheFeaturesRead() {
        withDefaults([
            OverlayView.hideBottomToolbarKey: nil, OverlayView.startCapturesInMoveModeKey: nil,
            AppDelegate.editablePointerDefaultsKey: nil, WebcamPlacement.snapKey: nil,
            PresetColorPalette.defaultsKey: nil,
        ]) {
            let tools = ToolsSettingsModel()
            XCTAssertEqual(tools.hideBottomToolbar, UserDefaults.standard.bool(forKey: OverlayView.hideBottomToolbarKey))
            XCTAssertEqual(tools.startCapturesInMoveMode, OverlayView.startCapturesInMoveModeSetting)
            XCTAssertEqual(tools.presetColors.count, PresetColorPalette.defaultColors.count)

            tools.startCapturesInMoveMode = true
            XCTAssertTrue(OverlayView.startCapturesInMoveModeSetting, "the toggle writes what the overlay reads")
            tools.removePresetColor(at: 0)
            XCTAssertEqual(PresetColorPalette.colors.count, PresetColorPalette.defaultColors.count - 1)
            tools.resetPresetColors()
            XCTAssertEqual(PresetColorPalette.colors.count, PresetColorPalette.defaultColors.count)

            let recording = RecordingSettingsModel()
            XCTAssertEqual(recording.editablePointer, AppDelegate.recordsEditablePointer)
            XCTAssertEqual(recording.webcamSnapsToCorners, WebcamPlacement.snapsToCorners)
            recording.webcamSnapsToCorners = false
            XCTAssertFalse(WebcamPlacement.snapsToCorners)
        }
    }

    func testQualitySliderShowsForEveryFormatThatUsesIt() {
        withDefaults(["imageFormat": nil]) {
            let model = CaptureSettingsModel()
            for format in ImageEncoder.Format.allCases {
                model.imageFormat = format.rawValue
                XCTAssertEqual(model.formatHasQuality, format.hasQuality, format.rawValue)
            }
        }
    }

    // MARK: - Card placement

    func testCornerAndStackingRoundTripThroughThePane() {
        withFreshInstall {
            let model = CaptureSettingsModel()
            model.thumbnailCorner = 3          // Top Left
            model.thumbnailStacking = 1        // Replace
            XCTAssertEqual(ThumbnailPlacementPreferences.corner(), .topLeft)
            XCTAssertFalse(ThumbnailPlacementPreferences.stacks())
            XCTAssertEqual(UserDefaults.standard.string(forKey: "thumbnailCorner"), "topLeft")
            XCTAssertEqual(UserDefaults.standard.object(forKey: "thumbnailStacking") as? Bool, false)

            let reopened = CaptureSettingsModel()
            XCTAssertEqual(reopened.thumbnailCorner, 3)
            XCTAssertEqual(reopened.thumbnailStacking, 1)
        }
    }

    func testPickerTagsWrittenByTheRebuiltPaneStillMeanWhatTheUserChose() {
        // 0 = stack and 1 = replace were stored as Ints; read as a Bool, 0
        // came out as "replace" — the opposite.
        withDefaults(["thumbnailStacking": 0, "thumbnailCorner": 2]) {
            XCTAssertTrue(ThumbnailPlacementPreferences.stacks())
            XCTAssertEqual(ThumbnailPlacementPreferences.corner(), .topRight)
        }
        withDefaults(["thumbnailStacking": 1, "thumbnailCorner": 99]) {
            XCTAssertFalse(ThumbnailPlacementPreferences.stacks())
            XCTAssertEqual(ThumbnailPlacementPreferences.corner(), .bottomRight)
        }
    }

    func testValuesWrittenByTheOriginalSettingsWindowStillRead() {
        withDefaults(["thumbnailStacking": true, "thumbnailCorner": "bottomLeft"]) {
            XCTAssertTrue(ThumbnailPlacementPreferences.stacks())
            XCTAssertEqual(ThumbnailPlacementPreferences.corner(), .bottomLeft)
        }
        withDefaults(["thumbnailStacking": false]) {
            XCTAssertFalse(ThumbnailPlacementPreferences.stacks())
        }
    }

    // MARK: - Pane height

    /// `sizeWindowToPane` caps the window at the screen's visible height minus
    /// 120, so a pane taller than a 13-inch display allows is cut off, not
    /// scrolled. 680pt is the budget the project settled on.
    func testNoSettingsPaneOutgrowsTheWindowBudget() {
        let capture = CaptureSettingsModel()
        let general = GeneralSettingsModel()
        var panes: [(String, AnyView)] = [
            ("general", AnyView(GeneralSettingsView(model: general, capture: capture))),
            ("appearance", AnyView(AppearanceSettingsView(model: general))),
            ("capture", AnyView(CaptureSettingsView(model: capture))),
            ("thumbnail", AnyView(ThumbnailSettingsView(model: capture))),
            ("output", AnyView(OutputSettingsView(model: capture))),
            ("beautify", AnyView(BeautifySettingsView(model: capture))),
            ("shortcuts", AnyView(ShortcutSettingsView(onHotkeyChanged: {}, onEditorCommandChanged: {}))),
            ("tools", AnyView(ToolsSettingsView(captureModel: capture))),
            ("recording", AnyView(RecordingSettingsView())),
        ]
        #if !OFFLINE
        panes.append(("uploads", AnyView(UploadSettingsView())))
        #endif
        for (name, pane) in panes {
            let host = NSHostingView(rootView: pane.frame(width: 700))
            host.sizingOptions = [.intrinsicContentSize]
            host.layoutSubtreeIfNeeded()
            let height = host.intrinsicContentSize.height
            XCTAssertGreaterThan(height, 1, "\(name) pane reported no height")
            XCTAssertLessThanOrEqual(height, 680, "\(name) pane is \(Int(height))pt — it would be cut off")
        }
    }
}
