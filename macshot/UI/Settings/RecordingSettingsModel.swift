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

    // MARK: Behaviour

    static let onStopValues = ["editor", "finder", "clipboard"]

    @Published var onStop: String {
        didSet { store(onStop, "recordingOnStop", oldValue) }
    }

    @Published var hideHUD: Bool {
        didSet { store(hideHUD, "hideRecordingHUD", oldValue) }
    }

    /// Keep the pointer, clicks and keystrokes as data the video editor can restyle.
    @Published var editablePointer: Bool {
        didSet { store(editablePointer, AppDelegate.editablePointerDefaultsKey, oldValue) }
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

    @Published var webcamSnapsToCorners: Bool {
        didSet { store(webcamSnapsToCorners, WebcamPlacement.snapKey, oldValue) }
    }

    // MARK: Lifecycle

    init() {
        let defaults = UserDefaults.standard
        let storedFPS = defaults.object(forKey: "recordingFPS") as? Int ?? 30
        frameRate = Self.frameRates.contains(storedFPS) ? storedFPS : 30
        onStop = defaults.string(forKey: "recordingOnStop") ?? "editor"
        hideHUD = defaults.bool(forKey: "hideRecordingHUD")
        editablePointer = AppDelegate.recordsEditablePointer
        webcamPosition = defaults.string(forKey: "webcamPosition") ?? "bottomRight"
        webcamSize = Double(WebcamSize.savedPoints)
        webcamShape = defaults.string(forKey: "webcamShape") ?? "circle"
        webcamSnapsToCorners = WebcamPlacement.snapsToCorners
    }

    private func store<T: Equatable>(_ value: T, _ key: String, _ oldValue: T) {
        guard value != oldValue else { return }
        UserDefaults.standard.set(value, forKey: key)
    }
}
