import XCTest

final class HistoryPanelItemTests: XCTestCase {

    private func capture(_ id: String, created: TimeInterval, edited: TimeInterval? = nil) -> HistoryEntry {
        HistoryEntry(id: id, fileExtension: "png", timestamp: Date(timeIntervalSince1970: created),
                     lastEditedAt: edited.map(Date.init(timeIntervalSince1970:)),
                     pixelWidth: 1, pixelHeight: 1, hasAnnotations: false, thumbnail: nil)
    }

    private func take(_ id: String, created: TimeInterval) -> RecordingTake {
        let folder = URL(fileURLWithPath: "/tmp/\(id)")
        return RecordingTake(id: id, folder: folder, mediaURL: folder.appendingPathComponent("Take.mp4"),
                             createdAt: Date(timeIntervalSince1970: created), fileSize: 1, wasInterrupted: false)
    }

    func testCapturesAndTakesInterleaveNewestFirst() {
        let items = HistoryPanelItem.merged(
            captures: [capture("c3", created: 300), capture("c1", created: 100)],
            takes: [take("t4", created: 400), take("t2", created: 200)],
            orderByLastEdit: false)
        XCTAssertEqual(items.map(\.id), ["recording:t4", "capture:c3", "recording:t2", "capture:c1"])
    }

    func testOrderingByEditsPlacesAnEditedCaptureByItsEdit() {
        // History keeps this order when it is ordered by last edit.
        let captures = [capture("old-but-edited", created: 100, edited: 500), capture("new", created: 300)]
        let takes = [take("t", created: 400)]
        XCTAssertEqual(HistoryPanelItem.merged(captures: captures, takes: takes, orderByLastEdit: true).map(\.id),
                       ["capture:old-but-edited", "recording:t", "capture:new"])
    }

    func testIDsNeverCollideAcrossKinds() {
        let items = HistoryPanelItem.merged(captures: [capture("same", created: 1)],
                                            takes: [take("same", created: 2)], orderByLastEdit: false)
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
    }

    func testDurationsReadLikeAPlayer() {
        XCTAssertEqual(RecordingThumbnails.durationText(0), "0:00")
        XCTAssertEqual(RecordingThumbnails.durationText(65.4), "1:05")
        XCTAssertEqual(RecordingThumbnails.durationText(3725), "1:02:05")
        XCTAssertEqual(RecordingThumbnails.durationText(.nan), "0:00")
    }

    func testATakeIsReadWhenItHasBytesWhateverItsStatus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macshot-takes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = try RecordingSessionStore(filename: "Finished", root: root)
        try Data(repeating: 1, count: 8).write(to: finished.mediaURL)
        try finished.update(status: "complete", error: nil)
        // A crash leaves "recording" behind with playable bytes.
        let crashed = try RecordingSessionStore(filename: "Crashed", root: root)
        try Data(repeating: 1, count: 8).write(to: crashed.mediaURL)
        let interrupted = try RecordingSessionStore(filename: "Interrupted", root: root)
        try Data(repeating: 1, count: 8).write(to: interrupted.mediaURL)
        try interrupted.update(status: "interrupted", error: CocoaError(.fileWriteOutOfSpace))
        _ = try RecordingSessionStore(filename: "Empty", root: root)

        let listed = RecordingLibrary.sessionDirectories(in: root).compactMap(RecordingLibrary.take(in:))
        XCTAssertEqual(Set(listed.map(\.title)), ["Finished", "Crashed", "Interrupted"])
        XCTAssertEqual(listed.first { $0.title == "Interrupted" }?.wasInterrupted, true)
        XCTAssertTrue(listed.allSatisfy { $0.fileSize == 8 })
    }

    func testTheTakeBeingWrittenIsNotListedUntilItEnds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macshot-takes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "macshot-takes-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            RecordingLibrary.activate(defaults: UserDefaults(suiteName: suite + "-empty")!)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        do { try RecordingLibrary.setLocation(root, defaults: defaults) }
        catch { throw XCTSkip("security-scoped bookmarks are unavailable to this test runner: \(error)") }

        let take = try RecordingSessionStore(filename: "Live", root: root)
        try Data(repeating: 1, count: 8).write(to: take.mediaURL)
        RecordingLibrary.beginWriting(take.directoryURL)
        XCTAssertFalse(RecordingLibrary.takes().contains { $0.id == take.directoryURL.lastPathComponent })
        RecordingLibrary.endWriting(take.directoryURL)
        XCTAssertTrue(RecordingLibrary.takes().contains { $0.id == take.directoryURL.lastPathComponent })
    }
}
