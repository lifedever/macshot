import XCTest

@MainActor
final class LibraryModelTests: XCTestCase {

    private func item(_ kind: LibraryItem.Kind, daysAgo: Double, annotated: Bool = false,
                      now: Date) -> LibraryItem {
        LibraryItem(id: UUID().uuidString, kind: kind, sourceID: "x", name: "Item",
                    createdAt: now.addingTimeInterval(-daysAgo * 86_400), editedAt: nil,
                    isAnnotated: annotated, pixelWidth: 10, pixelHeight: 10,
                    fileURL: URL(fileURLWithPath: "/tmp/item"), fileSize: 1, origin: nil)
    }

    func testKindSectionsSplitScreenshotsFromRecordings() {
        let now = Date()
        let shot = item(.screenshot, daysAgo: 0, annotated: true, now: now)
        let take = item(.recording, daysAgo: 0, now: now)
        XCTAssertTrue(LibrarySection.all.contains(shot, now: now) && LibrarySection.all.contains(take, now: now))
        XCTAssertTrue(LibrarySection.screenshots.contains(shot, now: now))
        XCTAssertFalse(LibrarySection.screenshots.contains(take, now: now))
        XCTAssertTrue(LibrarySection.recordings.contains(take, now: now))
        XCTAssertTrue(LibrarySection.annotated.contains(shot, now: now))
        XCTAssertFalse(LibrarySection.annotated.contains(take, now: now))
    }

    func testDateSectionsCountBackFromNow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // mid-day UTC
        let fresh = item(.screenshot, daysAgo: 0.1, now: now)
        let fewDays = item(.screenshot, daysAgo: 3, now: now)
        let weeks = item(.recording, daysAgo: 20, now: now)
        let old = item(.recording, daysAgo: 60, now: now)
        XCTAssertTrue(LibrarySection.today.contains(fresh, now: now, calendar: calendar))
        XCTAssertFalse(LibrarySection.today.contains(fewDays, now: now, calendar: calendar))
        XCTAssertTrue(LibrarySection.lastWeek.contains(fewDays, now: now))
        XCTAssertFalse(LibrarySection.lastWeek.contains(weeks, now: now))
        XCTAssertTrue(LibrarySection.lastMonth.contains(weeks, now: now))
        XCTAssertFalse(LibrarySection.lastMonth.contains(old, now: now))
    }

    func testEverySectionIsInTheSidebar() {
        XCTAssertEqual(Set(LibrarySection.kinds + LibrarySection.dates), Set(LibrarySection.allCases))
    }

    func testTheInspectorOpensOnlyForASelection() {
        withDefaults(["libraryShowsInspector": nil]) {
            let model = LibraryModel()
            XCTAssertTrue(model.wantsInspector)
            XCTAssertFalse(model.inspectorPresented, "nothing selected: closed")
            model.selection = ["capture:x"]
            XCTAssertTrue(model.inspectorPresented)

            // The selection going away closes it without forgetting the wish.
            model.selection = []
            model.inspectorPresented = false
            XCTAssertTrue(model.wantsInspector)

            // Closing it by hand is remembered.
            model.selection = ["capture:x"]
            model.inspectorPresented = false
            XCTAssertFalse(model.wantsInspector)
            XCTAssertFalse(model.inspectorPresented)
        }
    }
}
