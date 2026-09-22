import Cocoa
import XCTest

/// A capture that can't be written used to vanish without a word: the overlay
/// dismissed, the thumbnail animated, and the only trace was a DEBUG-only log.
/// These pin the reporting path that replaced it.
final class ImageSaveServiceTests: XCTestCase {

    private var directory: URL!
    private var reported: [String] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-save-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reported = []
        ImageSaveService.onFailure = { [weak self] message in
            self?.reported.append(message)
        }
    }

    override func tearDownWithError() throws {
        ImageSaveService.onFailure = nil
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    /// The write happens on a background queue and the completion hops back to
    /// main, so tests wait for it explicitly.
    @discardableResult
    private func save(_ image: NSImage, as filename: String,
                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        savedURL(image, as: filename) != nil
    }

    /// The write happens on a background queue and the completion hops back to
    /// main, so tests wait for it explicitly. Returns where the file landed,
    /// which is not always `directory/filename` — a name clash appends a counter.
    private func savedURL(_ image: NSImage, as filename: String) -> URL? {
        let finished = expectation(description: "save finished")
        var result: URL?
        ImageSaveService.writeImageForTesting(image, toDirectory: directory, filename: filename) { url in
            result = url
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        return result
    }

    private var savedFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    // MARK: - Writing

    func testASavedScreenshotLandsOnDisk() throws {
        withDefaults(["imageFormat": "png", "downscaleRetina": false]) {
            XCTAssertTrue(save(ImageProbe.quadrantImage(width: 40, height: 30), as: "shot.png"))
        }
        XCTAssertEqual(savedFiles, ["shot.png"])
        XCTAssertTrue(reported.isEmpty, "a successful save must not report a failure")

        let reloaded = try XCTUnwrap(NSImage(contentsOf: directory.appendingPathComponent("shot.png")))
        let bitmap = try XCTUnwrap(ImageProbe.bitmap(from: reloaded))
        XCTAssertEqual(bitmap.pixelsWide, 40)
    }

    func testASecondSaveDoesNotOverwriteTheFirst() {
        withDefaults(["imageFormat": "png", "downscaleRetina": false]) {
            save(ImageProbe.solidImage(width: 10, height: 10), as: "shot.png")
            save(ImageProbe.solidImage(width: 20, height: 20), as: "shot.png")
        }
        XCTAssertEqual(savedFiles.count, 2, "the second capture must not replace the first")
        XCTAssertTrue(savedFiles.contains("shot.png"))
    }

    func testManySavesWithTheSameNameAllSurvive() {
        withDefaults(["imageFormat": "png", "downscaleRetina": false]) {
            for _ in 0..<5 {
                save(ImageProbe.solidImage(width: 8, height: 8), as: "same.png")
            }
        }
        XCTAssertEqual(savedFiles.count, 5, "five captures in the same second must produce five files")
        XCTAssertEqual(Set(savedFiles).count, 5, "and five distinct names")
    }

    /// The saved-confirmation toast names the file and offers to reveal it, so
    /// the completion has to report the path that was actually written — not
    /// the one that was asked for, which a name clash renames out from under it.
    func testTheReportedURLIsTheFileThatWasWritten() throws {
        var first: URL?
        var second: URL?
        withDefaults(["imageFormat": "png", "downscaleRetina": false]) {
            first = savedURL(ImageProbe.solidImage(width: 10, height: 10), as: "shot.png")
            second = savedURL(ImageProbe.solidImage(width: 20, height: 20), as: "shot.png")
        }
        let firstURL = try XCTUnwrap(first)
        let secondURL = try XCTUnwrap(second)
        XCTAssertEqual(firstURL.lastPathComponent, "shot.png")
        XCTAssertNotEqual(secondURL, firstURL, "the renamed save must not report the original path")
        for url in [firstURL, secondURL] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) is not on disk")
        }
    }

    // MARK: - Failure reporting

    func testConcurrentSavesAreCoordinatedAndKeepEveryDistinctImage() throws {
        let finished = expectation(description: "all concurrent saves complete")
        finished.expectedFulfillmentCount = 12
        withDefaults(["imageFormat": "png", "downscaleRetina": false]) {
            for width in 10..<22 {
                ImageSaveService.writeImageForTesting(ImageProbe.solidImage(width: width, height: 8),
                    toDirectory: directory, filename: "concurrent.png") { url in
                        XCTAssertNotNil(url)
                        finished.fulfill()
                    }
            }
        }
        XCTAssertTrue(MediaExportCoordinator.shared.hasActiveJobs, "Quit must see pending screenshot saves")
        wait(for: [finished], timeout: 10)
        XCTAssertFalse(MediaExportCoordinator.shared.hasActiveJobs)
        let widths = try savedFiles.map { name in
            let image = try XCTUnwrap(NSImage(contentsOf: directory.appendingPathComponent(name)))
            return try XCTUnwrap(ImageProbe.bitmap(from: image)).pixelsWide
        }
        XCTAssertEqual(widths.sorted(), Array(10..<22))
    }

    func testFailedSaveAsPreservesExistingFile() throws {
        let destination = directory.appendingPathComponent("existing.png")
        let original = Data("original destination remains intact".utf8)
        try original.write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let prepared = try ImageEncoder.PreparedImage(ImageProbe.solidImage())
        let finished = expectation(description: "failed replacement")
        ImageSaveService.writePreparedImage(prepared, to: destination, chooseAvailableName: false) { url in
            XCTAssertNil(url)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testAFailedWriteIsReportedToTheUser() {
        // Make the directory read-only so the write fails the way a full disk
        // or an unmounted volume would.
        try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        var succeeded = true
        withDefaults(["imageFormat": "png", "downscaleRetina": false]) {
            succeeded = save(ImageProbe.solidImage(), as: "denied.png")
        }

        XCTAssertFalse(succeeded)
        // The report is dispatched to main; let it land.
        let reportArrived = expectation(description: "failure reported")
        DispatchQueue.main.async { reportArrived.fulfill() }
        wait(for: [reportArrived], timeout: 5)

        XCTAssertFalse(reported.isEmpty, "a save that failed must tell the user, not just return false")
        XCTAssertTrue(reported.first?.lowercased().contains("save") == true,
                      "the message should say what failed, got: \(reported)")
    }

    func testAMissingDirectoryIsReported() {
        let missing = directory.appendingPathComponent("not-created")
        let finished = expectation(description: "save finished")
        var saved: URL?
        withDefaults(["imageFormat": "png"]) {
            ImageSaveService.writeImageForTesting(ImageProbe.solidImage(), toDirectory: missing,
                                                  filename: "x.png") { url in
                saved = url
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 5)
        XCTAssertNil(saved)

        let reportArrived = expectation(description: "failure reported")
        DispatchQueue.main.async { reportArrived.fulfill() }
        wait(for: [reportArrived], timeout: 5)
        XCTAssertFalse(reported.isEmpty)
    }

    func testTheDefaultSaveActionIsToUseTheConfiguredFolder() {
        withDefaults([SaveActionPreference.userDefaultsKey: nil]) {
            XCTAssertEqual(SaveActionPreference.current, .saveToFolder)
        }
        withDefaults([SaveActionPreference.userDefaultsKey: 99]) {
            XCTAssertEqual(SaveActionPreference.current, .saveToFolder, "an unknown stored value must fall back")
        }
    }

    func testEverySaveActionHasATitle() {
        for action in SaveActionPreference.allCases {
            XCTAssertFalse(action.title.isEmpty)
        }
    }
}
