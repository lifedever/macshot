import AppKit
import Combine
import SwiftUI

/// Backing store for the Capture, Thumbnail and Output panes.
///
/// One store for all three because they came from a single 36-control tab and
/// still share a few values (the capture-time settings and the save settings
/// both read the filename template, for instance).
@MainActor
final class CaptureSettingsModel: ObservableObject {

    // MARK: Capture

    /// 0 = save to file, 1 = copy, 2 = save + copy, 3 = do nothing.
    @Published var quickCaptureMode: Int {
        didSet { store(quickCaptureMode, "quickCaptureMode", oldValue) }
    }
    @Published var quickCaptureOpenEditor: Bool {
        didSet { store(quickCaptureOpenEditor, "quickCaptureOpenEditor", oldValue) }
    }
    @Published var closeEditorAfterCopy: Bool {
        didSet { store(closeEditorAfterCopy, "closeEditorAfterCopy", oldValue) }
    }
    @Published var ocrAction: Int {
        didSet { store(ocrAction, "ocrAction", oldValue) }
    }
    @Published var playSound: Bool {
        didSet { store(playSound, "playCopySound", oldValue) }
    }
    @Published var rememberLastTool: Bool {
        didSet { store(rememberLastTool, "rememberLastTool", oldValue) }
    }
    @Published var captureCursor: Bool {
        didSet { store(captureCursor, "captureCursor", oldValue) }
    }
    @Published var doubleClickToCopy: Bool {
        didSet { store(doubleClickToCopy, "doubleClickToCopy", oldValue) }
    }
    @Published var hideInstructions: Bool {
        didSet { store(hideInstructions, "hideCaptureInstructions", oldValue) }
    }
    @Published var disableOutsideShadow: Bool {
        didSet { store(disableOutsideShadow, "disableSelectionOutsideShadow", oldValue) }
    }

    // MARK: Snapping

    @Published var snapGuides: Bool {
        didSet { store(snapGuides, "snapGuidesEnabled", oldValue) }
    }
    @Published var boundarySnap: Bool {
        didSet { store(boundarySnap, "boundarySnapEnabled", oldValue) }
    }
    @Published var snapHaptics: Bool {
        didSet { store(snapHaptics, SnapHapticFeedback.enabledKey, oldValue) }
    }
    @Published var browserElementSnap: Bool {
        didSet { store(browserElementSnap, OverlayView.browserElementSnapEnabledKey, oldValue) }
    }

    // MARK: Thumbnail

    @Published var showThumbnail: Bool {
        didSet { store(showThumbnail, "showFloatingThumbnail", oldValue) }
    }
    @Published var thumbnailAutoDismiss: Int {
        didSet { store(thumbnailAutoDismiss, "thumbnailAutoDismiss", oldValue) }
    }
    /// 0 = stack, 1 = replace — the picker's tags. Stored as the Bool the
    /// card reads; see `ThumbnailPlacementPreferences`.
    @Published var thumbnailStacking: Int {
        didSet {
            guard thumbnailStacking != oldValue else { return }
            ThumbnailPlacementPreferences.setStacks(thumbnailStacking == 0)
        }
    }
    /// Index into `FloatingThumbnailCorner.allCases`, stored as its raw value.
    @Published var thumbnailCorner: Int {
        didSet {
            guard thumbnailCorner != oldValue,
                  FloatingThumbnailCorner.allCases.indices.contains(thumbnailCorner) else { return }
            ThumbnailPlacementPreferences.setCorner(FloatingThumbnailCorner.allCases[thumbnailCorner])
        }
    }
    @Published var thumbnailScale: Double {
        didSet { store(thumbnailScale, "thumbnailScale", oldValue) }
    }
    @Published var thumbnailLetterbox: Bool {
        didSet { store(thumbnailLetterbox, "thumbnailLetterbox", oldValue) }
    }

    // MARK: Output

    @Published var saveAction: Int {
        didSet {
            guard saveAction != oldValue,
                  let action = SaveActionPreference(rawValue: saveAction) else { return }
            SaveActionPreference.current = action
        }
    }

    @Published var saveFolderPath: String

    func browseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L("Choose a folder")
        panel.directoryURL = SaveDirectoryAccess.directoryHint()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SaveDirectoryAccess.save(url: url)
        saveFolderPath = SaveDirectoryAccess.displayPath
    }

    @Published var filenameTemplate: String {
        didSet {
            guard filenameTemplate != oldValue else { return }
            let trimmed = filenameTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? FilenameFormatter.defaultTemplate : filenameTemplate,
                                      forKey: FilenameFormatter.userDefaultsKey)
        }
    }

    var filenamePreview: String {
        let trimmed = filenameTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmed.isEmpty ? FilenameFormatter.defaultTemplate : trimmed
        return FilenameFormatter.format(template: effective, windowTitle: nil) + ".\(ImageEncoder.fileExtension)"
    }

    func resetFilenameTemplate() { filenameTemplate = FilenameFormatter.defaultTemplate }

    @Published var imageFormat: String {
        didSet {
            guard imageFormat != oldValue else { return }
            UserDefaults.standard.set(imageFormat, forKey: "imageFormat")
        }
    }

    var availableFormats: [ImageEncoder.Format] {
        ImageEncoder.Format.allCases.filter { ImageEncoder.isFormatAvailable($0) }
    }

    /// Whether the encoder applies the quality value to this format — JPEG,
    /// HEIC, WebP and AVIF do; PNG is lossless.
    var formatHasQuality: Bool {
        ImageEncoder.Format(rawValue: imageFormat)?.hasQuality ?? false
    }

    @Published var imageQuality: Double {
        didSet { store(imageQuality, "imageQuality", oldValue) }
    }

    @Published var downscaleRetina: Bool {
        didSet { store(downscaleRetina, "downscaleRetina", oldValue) }
    }

    @Published var historyUnlimited: Bool {
        didSet { store(historyUnlimited, "historyUnlimited", oldValue) }
    }
    @Published var historySize: Int {
        didSet { store(historySize, "historySize", oldValue) }
    }
    @Published var historyOrderByLastEdit: Bool {
        didSet { store(historyOrderByLastEdit, "historyOrderByLastEdit", oldValue) }
    }

    // MARK: Beautify

    /// Gradient background, padding, rounded corners and drop shadow around the
    /// capture. Promoted from a toolbar-only toggle to a real setting: it was a
    /// persisted global that only the overlay toolbar could reach, so a quick
    /// capture (which shows no toolbar) inherited whatever the last interactive
    /// capture happened to leave it on.
    @Published var beautifyEnabled: Bool {
        didSet { store(beautifyEnabled, "beautifyEnabled", oldValue) }
    }

    /// 0 = window chrome with traffic lights, 1 = plain rounded corners.
    @Published var beautifyMode: Int {
        didSet { store(beautifyMode, "beautifyMode", oldValue) }
    }
    @Published var beautifyPadding: Double {
        didSet { store(beautifyPadding, "beautifyPadding", oldValue) }
    }
    @Published var beautifyCornerRadius: Double {
        didSet { store(beautifyCornerRadius, "beautifyCornerRadius", oldValue) }
    }
    @Published var beautifyShadowRadius: Double {
        didSet { store(beautifyShadowRadius, "beautifyShadowRadius", oldValue) }
    }
    /// Only applies to image backgrounds (style index -1); gradients ignore it.
    @Published var beautifyBackgroundBlur: Double {
        didSet { store(beautifyBackgroundBlur, "beautifyBgBlur", oldValue) }
    }
    /// -1 means a custom image background rather than one of the gradients.
    @Published var beautifyStyleIndex: Int {
        didSet { store(beautifyStyleIndex, "beautifyStyleIndex", oldValue) }
    }

    var beautifyUsesImageBackground: Bool { beautifyStyleIndex == -1 }

    var beautifyPaddingRange: ClosedRange<Double> {
        Double(BeautifyConfig.minPadding)...Double(BeautifyConfig.maxPadding)
    }

    // MARK: Translation

    // MARK: Scroll capture

    // Scroll capture stitches a long page into one image, so it belongs with
    // the other capture settings. It used to sit under Recording, next to the
    // frame rate and the webcam, purely because both run for a while.

    @Published var autoScroll: Bool {
        didSet { store(autoScroll, "scrollAutoScrollEnabled", oldValue) }
    }

    /// Stored 1-based to match the engine's existing speed values.
    @Published var scrollSpeed: Int {
        didSet { store(scrollSpeed, "scrollAutoScrollSpeed", oldValue) }
    }

    @Published var scrollMaxHeight: Int {
        didSet { store(scrollMaxHeight, "scrollMaxHeight", oldValue) }
    }

    @Published var detectFrozenHeaders: Bool {
        didSet { store(detectFrozenHeaders, "scrollFrozenDetection", oldValue) }
    }

    /// Lives on the Tools pane with the annotation tools: translation is what
    /// the Translate tool runs on, not a property of the file a capture writes.
    @Published var useAppleTranslation: Bool {
        didSet {
            guard useAppleTranslation != oldValue else { return }
            TranslationService.provider = useAppleTranslation ? .apple : .google
        }
    }

    // MARK: Lifecycle

    init() {
        let ud = UserDefaults.standard
        quickCaptureMode = ud.object(forKey: "quickCaptureMode") as? Int ?? 1
        quickCaptureOpenEditor = ud.bool(forKey: "quickCaptureOpenEditor")
        closeEditorAfterCopy = DetachedEditorWindowController.closesAfterCopy
        ocrAction = ud.integer(forKey: "ocrAction")
        playSound = ud.object(forKey: "playCopySound") as? Bool ?? true
        rememberLastTool = ud.object(forKey: "rememberLastTool") as? Bool ?? true
        captureCursor = ud.bool(forKey: "captureCursor")
        doubleClickToCopy = ud.object(forKey: "doubleClickToCopy") as? Bool ?? true
        hideInstructions = ud.bool(forKey: "hideCaptureInstructions")
        disableOutsideShadow = ud.bool(forKey: "disableSelectionOutsideShadow")
        snapGuides = ud.object(forKey: "snapGuidesEnabled") as? Bool ?? true
        boundarySnap = ud.object(forKey: "boundarySnapEnabled") as? Bool ?? true
        snapHaptics = ud.object(forKey: SnapHapticFeedback.enabledKey) as? Bool ?? true
        browserElementSnap = ud.object(forKey: OverlayView.browserElementSnapEnabledKey) as? Bool ?? true
        showThumbnail = ud.object(forKey: "showFloatingThumbnail") as? Bool ?? true
        thumbnailAutoDismiss = ud.object(forKey: "thumbnailAutoDismiss") as? Int ?? 5
        thumbnailStacking = ThumbnailPlacementPreferences.stacks() ? 0 : 1
        thumbnailCorner = FloatingThumbnailCorner.allCases.firstIndex(of: ThumbnailPlacementPreferences.corner()) ?? 0
        thumbnailScale = ud.object(forKey: "thumbnailScale") as? Double ?? 1.0
        thumbnailLetterbox = ud.object(forKey: "thumbnailLetterbox") as? Bool ?? true
        saveAction = SaveActionPreference.current.rawValue
        saveFolderPath = SaveDirectoryAccess.displayPath
        filenameTemplate = ud.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
        imageFormat = ud.string(forKey: "imageFormat") ?? "png"
        imageQuality = Double(ImageEncoder.quality)
        downscaleRetina = ud.bool(forKey: "downscaleRetina")
        historyUnlimited = ud.bool(forKey: "historyUnlimited")
        historySize = ud.object(forKey: "historySize") as? Int ?? ScreenshotHistory.defaultMaxEntries
        historyOrderByLastEdit = ScreenshotHistory.orderByLastEdit
        autoScroll = ud.object(forKey: "scrollAutoScrollEnabled") as? Bool ?? ScrollCaptureController.defaultAutoScrollEnabled
        scrollSpeed = ud.object(forKey: "scrollAutoScrollSpeed") as? Int ?? ScrollCaptureController.defaultAutoScrollSpeed
        scrollMaxHeight = ud.object(forKey: "scrollMaxHeight") as? Int ?? ScrollCaptureController.defaultMaxScrollHeight
        detectFrozenHeaders = ud.object(forKey: "scrollFrozenDetection") as? Bool ?? true
        useAppleTranslation = TranslationService.provider == .apple
        beautifyEnabled = ud.object(forKey: "beautifyEnabled") as? Bool ?? true
        beautifyMode = ud.integer(forKey: "beautifyMode")
        beautifyPadding = ud.object(forKey: "beautifyPadding") as? Double ?? 48
        beautifyCornerRadius = ud.object(forKey: "beautifyCornerRadius") as? Double ?? 10
        beautifyShadowRadius = ud.object(forKey: "beautifyShadowRadius") as? Double ?? 20
        beautifyBackgroundBlur = ud.object(forKey: "beautifyBgBlur") as? Double ?? 0
        beautifyStyleIndex = ud.integer(forKey: "beautifyStyleIndex")
    }

    private func store<T: Equatable>(_ value: T, _ key: String, _ oldValue: T) {
        guard value != oldValue else { return }
        UserDefaults.standard.set(value, forKey: key)
    }
}
