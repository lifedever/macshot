import AppKit
import Combine
import SwiftUI

/// Backing store for the Recording settings pane.
///
/// Every value here is a `UserDefaults` key the recording engine already reads;
/// this type only owns the round-trip, the same way `GeneralSettingsModel` does.
@MainActor
final class RecordingSettingsModel: ObservableObject {

    // MARK: Output

    static let frameRates = [15, 24, 30, 60, 120]

    @Published var frameRate: Int {
        didSet { store(frameRate, "recordingFPS", oldValue) }
    }

    /// Display path of the recording save folder, or the default location when
    /// the user has not picked one.
    @Published var saveFolderPath: String

    @Published var filenameTemplate: String {
        didSet {
            guard filenameTemplate != oldValue else { return }
            let trimmed = filenameTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed.isEmpty ? FilenameFormatter.defaultRecordingTemplate : filenameTemplate
            UserDefaults.standard.set(value, forKey: FilenameFormatter.recordingUserDefaultsKey)
        }
    }

    /// What the current template produces, so the effect of a token is visible
    /// while typing instead of only after the next recording.
    var filenamePreview: String {
        let template = filenameTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = template.isEmpty ? FilenameFormatter.defaultRecordingTemplate : template
        return FilenameFormatter.format(template: effective, windowTitle: nil) + ".mp4"
    }

    func resetFilenameTemplate() {
        filenameTemplate = FilenameFormatter.defaultRecordingTemplate
    }

    func browseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L("Choose a folder")
        panel.directoryURL = SaveDirectoryAccess.recordingDirectoryHint()
        // Modal rather than the sheet the AppKit pane used: the SwiftUI pane has
        // no window reference to attach one to, and this panel is not tied to
        // anything the user can interact with behind it.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SaveDirectoryAccess.saveRecordingDirectory(url: url)
        saveFolderPath = url.path
    }

    func clearSaveFolder() {
        SaveDirectoryAccess.clearRecordingDirectory()
        saveFolderPath = SaveDirectoryAccess.recordingDisplayPath
    }

    // MARK: Behaviour

    static let onStopValues = ["editor", "finder", "clipboard"]

    @Published var onStop: String {
        didSet { store(onStop, "recordingOnStop", oldValue) }
    }

    @Published var hideHUD: Bool {
        didSet { store(hideHUD, "hideRecordingHUD", oldValue) }
    }

    // MARK: Webcam

    static let webcamPositions = ["bottomRight", "bottomLeft", "topRight", "topLeft"]
    static let webcamShapes = ["circle", "roundedRect"]

    @Published var webcamPosition: String {
        didSet { store(webcamPosition, "webcamPosition", oldValue) }
    }

    @Published var webcamSize: Double {
        didSet {
            guard webcamSize != oldValue else { return }
            WebcamSize.save(points: CGFloat(webcamSize))
        }
    }

    var webcamSizeRange: ClosedRange<Double> {
        Double(WebcamSize.minPoints)...Double(WebcamSize.maxPoints)
    }

    @Published var webcamShape: String {
        didSet { store(webcamShape, "webcamShape", oldValue) }
    }

    // MARK: Scroll capture

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

    // MARK: Lifecycle

    init() {
        let defaults = UserDefaults.standard
        let storedFPS = defaults.object(forKey: "recordingFPS") as? Int ?? 30
        frameRate = Self.frameRates.contains(storedFPS) ? storedFPS : 30
        saveFolderPath = SaveDirectoryAccess.recordingDisplayPath
        filenameTemplate = defaults.string(forKey: FilenameFormatter.recordingUserDefaultsKey)
            ?? FilenameFormatter.defaultRecordingTemplate
        onStop = defaults.string(forKey: "recordingOnStop") ?? "editor"
        hideHUD = defaults.bool(forKey: "hideRecordingHUD")
        webcamPosition = defaults.string(forKey: "webcamPosition") ?? "bottomRight"
        webcamSize = Double(WebcamSize.savedPoints)
        webcamShape = defaults.string(forKey: "webcamShape") ?? "circle"
        autoScroll = defaults.object(forKey: "scrollAutoScrollEnabled") as? Bool ?? true
        scrollSpeed = defaults.object(forKey: "scrollAutoScrollSpeed") as? Int ?? 2
        scrollMaxHeight = defaults.integer(forKey: "scrollMaxHeight")
        detectFrozenHeaders = defaults.object(forKey: "scrollFrozenDetection") as? Bool ?? true
    }

    private func store<T: Equatable>(_ value: T, _ key: String, _ oldValue: T) {
        guard value != oldValue else { return }
        UserDefaults.standard.set(value, forKey: key)
    }
}
