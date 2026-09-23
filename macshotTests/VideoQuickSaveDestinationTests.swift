import XCTest

/// The video editor's Save button writes into the save folder under the
/// take's name. It must replace only this take's own copy — never an
/// unrelated file that happens to share the name.
final class VideoQuickSaveDestinationTests: XCTestCase {

    private var folder: URL!
    private var source: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickSave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        source = folder.appendingPathComponent("library-original.mp4")
        try Data(repeating: 1, count: 1_000).write(to: source)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, bytes: Int) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 2, count: bytes).write(to: url)
        return url
    }

    func testAFreeNameIsUsedWithoutReplacing() {
        let pick = VideoQuickSaveDestination.choose(in: folder, base: "Take", ext: "mp4",
                                                   previouslySaved: nil, source: source)
        XCTAssertEqual(pick.url.lastPathComponent, "Take.mp4")
        XCTAssertFalse(pick.replacing)
    }

    func testTheUneditedPublishedCopyIsReplaced() throws {
        _ = try write("Take.mp4", bytes: 1_000)
        let pick = VideoQuickSaveDestination.choose(in: folder, base: "Take", ext: "mp4",
                                                   previouslySaved: nil, source: source)
        XCTAssertEqual(pick.url.lastPathComponent, "Take.mp4")
        XCTAssertTrue(pick.replacing)
    }

    func testAnUnrelatedFileWithTheSameNameIsLeftAlone() throws {
        _ = try write("Take.mp4", bytes: 5_000)
        let pick = VideoQuickSaveDestination.choose(in: folder, base: "Take", ext: "mp4",
                                                   previouslySaved: nil, source: source)
        XCTAssertEqual(pick.url.lastPathComponent, "Take (2).mp4")
        XCTAssertFalse(pick.replacing)
    }

    func testATakePublishedUnderANumberedNameIsFoundThere() throws {
        _ = try write("Take.mp4", bytes: 5_000)          // someone else's
        _ = try write("Take (2).mp4", bytes: 1_000)      // this take, published around it
        let pick = VideoQuickSaveDestination.choose(in: folder, base: "Take", ext: "mp4",
                                                   previouslySaved: nil, source: source)
        XCTAssertEqual(pick.url.lastPathComponent, "Take (2).mp4")
        XCTAssertTrue(pick.replacing)
    }

    func testTheFileThisEditorSavedIsReplacedAgain() throws {
        let saved = try write("Take.mp4", bytes: 7_000)  // edited, so no longer the source size
        let pick = VideoQuickSaveDestination.choose(in: folder, base: "Take", ext: "mp4",
                                                   previouslySaved: saved, source: source)
        XCTAssertEqual(pick.url, saved)
        XCTAssertTrue(pick.replacing)
    }
}
