import XCTest

final class RecordingLibraryTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "macshot-library-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        // Leave the process on the default location, whatever a test set.
        RecordingLibrary.activate(defaults: UserDefaults(suiteName: suiteName + "-empty")!)
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func take(in root: URL, bytes: Int = 16) throws -> URL {
        let session = try RecordingSessionStore(filename: "Take", root: root)
        try Data(repeating: 1, count: bytes).write(to: session.mediaURL)
        return session.directoryURL
    }

    func testOnlySessionFoldersCountAsTakes() throws {
        let root = directory.appendingPathComponent("Library")
        let real = try take(in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Not a take"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)
        XCTAssertEqual(RecordingLibrary.sessionDirectories(in: root).map(\.lastPathComponent), [real.lastPathComponent])
        XCTAssertTrue(RecordingLibrary.sessionDirectories(in: directory.appendingPathComponent("Missing")).isEmpty)
    }

    func testMovingKeepsEveryFileOfATake() throws {
        let old = directory.appendingPathComponent("Old")
        let new = directory.appendingPathComponent("New")
        let first = try take(in: old)
        try Data("pointer".utf8).write(to: first.appendingPathComponent("cursor.mstl"))
        let second = try take(in: old)

        let result = try RecordingLibrary.move([first, second], into: new)
        XCTAssertEqual(result, RecordingLibrary.MigrationResult(moved: 2, failed: 0))
        XCTAssertTrue(RecordingLibrary.sessionDirectories(in: old).isEmpty)
        let moved = new.appendingPathComponent(first.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("Take.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("cursor.mstl").path))
        XCTAssertEqual(RecordingLibrary.sessionDirectories(in: new).count, 2)
    }

    func testATakeThatCantMoveStaysWhereItWas() throws {
        let old = directory.appendingPathComponent("Old")
        let new = directory.appendingPathComponent("New")
        let blocked = try take(in: old)
        // Something already sits at the destination under the same name.
        try FileManager.default.createDirectory(at: new.appendingPathComponent(blocked.lastPathComponent),
                                                withIntermediateDirectories: true)
        let vanished = old.appendingPathComponent(UUID().uuidString)

        let result = try RecordingLibrary.move([blocked, vanished], into: new)
        XCTAssertEqual(result, RecordingLibrary.MigrationResult(moved: 0, failed: 2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.appendingPathComponent("Take.mp4").path))
    }

    func testACopyAcrossVolumesRemovesTheOriginalOnlyOnceComplete() throws {
        let old = directory.appendingPathComponent("Old")
        let new = directory.appendingPathComponent("New")
        let source = try take(in: old, bytes: 64)
        let result = try RecordingLibrary.move([source], into: new, copyingAcrossVolumes: true)
        XCTAssertEqual(result, RecordingLibrary.MigrationResult(moved: 1, failed: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let copied = new.appendingPathComponent(source.lastPathComponent).appendingPathComponent("Take.mp4")
        XCTAssertEqual(try Data(contentsOf: copied).count, 64)
    }

    func testACompleteCopyIsKeptWhenTheOriginalCantBeRemoved() throws {
        let old = directory.appendingPathComponent("Old")
        let new = directory.appendingPathComponent("New")
        let source = try take(in: old, bytes: 64)
        // The old location can't be written, so the original can't be removed.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: source.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old.path)
        }
        let result = try RecordingLibrary.move([source], into: new, copyingAcrossVolumes: true)
        XCTAssertEqual(result.moved, 1)
        let copied = new.appendingPathComponent(source.lastPathComponent).appendingPathComponent("Take.mp4")
        XCTAssertEqual(try Data(contentsOf: copied).count, 64, "the complete copy must survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("Take.mp4").path),
                      "and so does the original it couldn't remove")
    }

    func testTheDefaultLocationIsTheContainerLibrary() {
        RecordingLibrary.activate(defaults: defaults)
        XCTAssertTrue(RecordingLibrary.usesDefaultLocation)
        XCTAssertFalse(RecordingLibrary.isConfiguredLocationUnavailable)
        XCTAssertEqual(RecordingLibrary.currentRoot, RecordingLibrary.defaultRoot)
        XCTAssertEqual(RecordingLibrary.allRoots, [RecordingLibrary.defaultRoot])
        XCTAssertTrue(RecordingSessionStore.owns(RecordingLibrary.defaultRoot.appendingPathComponent("x/take.mp4")))
    }

    func testAnUnreachableLocationFallsBackToTheDefault() {
        defaults.set(Data("not a bookmark".utf8), forKey: RecordingLibrary.bookmarkKey)
        RecordingLibrary.activate(defaults: defaults)
        XCTAssertTrue(RecordingLibrary.isConfiguredLocationUnavailable)
        XCTAssertEqual(RecordingLibrary.currentRoot, RecordingLibrary.defaultRoot,
                       "new takes must still have somewhere to go")
    }

    func testTakesInThePreviousLocationStayPartOfTheLibrary() throws {
        let first = directory.appendingPathComponent("First")
        let second = directory.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        do {
            try RecordingLibrary.setLocation(first, defaults: defaults)
        } catch {
            throw XCTSkip("security-scoped bookmarks are unavailable to this test runner: \(error)")
        }
        XCTAssertTrue(RecordingLibrary.sameFolder(RecordingLibrary.currentRoot, first))
        let left = try take(in: first)

        try RecordingLibrary.setLocation(second, defaults: defaults)
        XCTAssertTrue(RecordingLibrary.sameFolder(RecordingLibrary.currentRoot, second))
        XCTAssertTrue(RecordingSessionStore.owns(left.appendingPathComponent("Take.mp4")),
                      "a take left behind is still a durable original")
        XCTAssertEqual(RecordingLibrary.takesOutsideCurrentLocation().map(\.lastPathComponent), [left.lastPathComponent])

        _ = try RecordingLibrary.move(RecordingLibrary.takesOutsideCurrentLocation(), into: second)
        RecordingLibrary.forgetEmptyPastRoots(defaults: defaults)
        XCTAssertFalse(RecordingLibrary.allRoots.contains { RecordingLibrary.sameFolder($0, first) },
                       "an emptied location drops out of the library")

        try RecordingLibrary.setLocation(nil, defaults: defaults)
        XCTAssertTrue(RecordingLibrary.usesDefaultLocation)
        XCTAssertTrue(RecordingLibrary.allRoots.contains { RecordingLibrary.sameFolder($0, second) },
                      "returning to the default keeps the takes in the custom location listed")
    }
}
