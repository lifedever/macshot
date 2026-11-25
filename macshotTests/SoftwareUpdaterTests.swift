import XCTest

/// Each release has one feed per architecture beside the `SUFeedURL` one
/// (`scripts/release.sh`). The names must match what the script uploads, or
/// installed copies look for a feed that doesn't exist and never update.
@MainActor
final class SoftwareUpdaterTests: XCTestCase {
    private let base = "https://github.com/lifedever/macshot/releases/latest/download/appcast.xml"

    func testEachArchitectureReadsItsOwnFeed() {
        XCTAssertEqual(
            SoftwareUpdater.architectureFeedURL(base: base, architecture: "arm64"),
            "https://github.com/lifedever/macshot/releases/latest/download/appcast-arm64.xml")
        XCTAssertEqual(
            SoftwareUpdater.architectureFeedURL(base: base, architecture: "x86_64"),
            "https://github.com/lifedever/macshot/releases/latest/download/appcast-x86_64.xml")
    }

    func testAFeedNotNamedXMLIsLeftToSparkle() {
        XCTAssertNil(SoftwareUpdater.architectureFeedURL(base: "https://example.com/feed", architecture: "arm64"))
    }

    func testTheMacsArchitectureIsOneTheScriptPublishes() {
        XCTAssertTrue(["arm64", "x86_64"].contains(SoftwareUpdater.hardwareArchitecture))
    }

    /// The script derives these same names; keep the two in step.
    func testTheReleaseScriptPublishesTheseFeeds() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/release.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains("appcast-$arch.xml"), "release.sh no longer writes appcast-<arch>.xml")
        XCTAssertTrue(text.contains("ARCHES=(arm64 x86_64)"), "release.sh no longer builds arm64 and x86_64")
    }
}
