import AppKit

/// Settings › Recording › "Change…": choose where new takes go, then offer to
/// bring the existing ones along.
@MainActor
enum RecordingLibraryRelocation {

    /// Ask for a folder and make it the library. Returns after the choice is
    /// applied; moving existing takes, if accepted, continues as an export job.
    static func chooseLocation(onChange: @escaping () -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose")
        panel.directoryURL = RecordingLibrary.usesDefaultLocation ? nil : URL(fileURLWithPath: RecordingLibrary.displayPath)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        apply(url, onChange: onChange)
    }

    static func useDefaultLocation(onChange: @escaping () -> Void) {
        apply(nil, onChange: onChange)
    }

    private static func apply(_ url: URL?, onChange: @escaping () -> Void) {
        do {
            try RecordingLibrary.setLocation(url)
        } catch {
            (NSApp.delegate as? AppDelegate)?.showFailureToast(error.localizedDescription)
            return
        }
        onChange()
        offerToMoveExistingTakes(onChange: onChange)
    }

    private static func offerToMoveExistingTakes(onChange: @escaping () -> Void) {
        let takes = RecordingLibrary.takesOutsideCurrentLocation()
        guard !takes.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L("Move existing recordings?")
        alert.informativeText = String(format: L("%d recordings are in the previous location."), takes.count)
        alert.addButton(withTitle: L("Move Recordings"))
        alert.addButton(withTitle: L("Leave Them"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let appDelegate = NSApp.delegate as? AppDelegate
        if appDelegate?.isRecordingInProgress == true || VideoEditorWindowController.hasOpenEditors {
            let busy = NSAlert()
            busy.messageText = L("Stop the recording and close the video editor before moving recordings.")
            busy.runModal()
            return
        }
        let destination = RecordingLibrary.currentRoot
        let outcome = MigrationOutcome()
        let job = MediaExportCoordinator.shared.start(
            title: L("Moving recordings…"), status: L("Moving recordings…"),
            operation: { cancellation, progress in
                outcome.result = try await MediaExportIO.perform {
                    try RecordingLibrary.move(takes, into: destination, cancellation: cancellation, progress: progress)
                }
            },
            completion: { result in
                RecordingLibrary.forgetEmptyPastRoots()
                onChange()
                switch result {
                case .success:
                    let moved = outcome.result ?? RecordingLibrary.MigrationResult()
                    if moved.failed > 0 {
                        appDelegate?.showFailureToast(String(format: L("%d recordings couldn't be moved and stay in the previous location."), moved.failed))
                    } else {
                        ToastCenter.shared.show(String(format: L("Moved %d recordings"), moved.moved))
                    }
                case .failure(let error):
                    guard !(error is CancellationError) else { return }
                    appDelegate?.showFailureToast(error.localizedDescription)
                }
            })
        MediaExportProgressController.show(for: job)
    }

    /// Carries the move's counts out of the export operation, which the
    /// coordinator types as returning `Void`.
    private final class MigrationOutcome: @unchecked Sendable {
        var result: RecordingLibrary.MigrationResult?
    }
}
