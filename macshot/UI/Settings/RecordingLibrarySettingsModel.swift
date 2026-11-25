import AppKit
import Combine

/// Where the original recordings are kept, for the Output pane (with the save folder and the
/// filename template, every local path the app writes to is set there). `RecordingLibrary`
/// owns the location; moving it goes through `RecordingLibraryRelocation`.
final class RecordingLibrarySettingsModel: ObservableObject {
    @Published private(set) var path = RecordingLibrary.displayPath
    @Published private(set) var isDefault = RecordingLibrary.usesDefaultLocation
    @Published private(set) var isUnavailable = RecordingLibrary.isConfiguredLocationUnavailable
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: RecordingLibrary.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func chooseLocation() {
        RecordingLibraryRelocation.chooseLocation { [weak self] in self?.refresh() }
    }

    func useDefaultLocation() {
        RecordingLibraryRelocation.useDefaultLocation { [weak self] in self?.refresh() }
    }

    func showInFinder() {
        let folder = RecordingLibrary.currentRoot
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private func refresh() {
        path = RecordingLibrary.displayPath
        isDefault = RecordingLibrary.usesDefaultLocation
        isUnavailable = RecordingLibrary.isConfiguredLocationUnavailable
    }
}
