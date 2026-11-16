import AppKit
import Combine
import SwiftUI

/// One row or tile in the library window.
struct LibraryItem: Identifiable, Hashable {
    enum Kind: String { case screenshot, recording }

    /// `HistoryPanelItem.id`: unique across captures and takes.
    let id: String
    let kind: Kind
    /// History entry ID or take folder name.
    let sourceID: String
    let name: String
    let createdAt: Date
    let editedAt: Date?
    let isAnnotated: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let fileURL: URL
    let fileSize: Int64
    /// The window or app the capture came from, when known.
    let origin: String?

    var kindTitle: String { kind == .screenshot ? L("Screenshot") : L("Recording") }
    var dimensionsText: String {
        pixelWidth > 0 && pixelHeight > 0 ? "\(pixelWidth) × \(pixelHeight)" : "—"
    }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file) }
}

/// The library window's sidebar.
enum LibrarySection: String, CaseIterable, Identifiable {
    case all, screenshots, recordings, annotated, today, lastWeek, lastMonth

    var id: String { rawValue }
    static let kinds: [LibrarySection] = [.all, .screenshots, .recordings, .annotated]
    static let dates: [LibrarySection] = [.today, .lastWeek, .lastMonth]

    var title: String {
        switch self {
        case .all: return L("All")
        case .screenshots: return L("Screenshots")
        case .recordings: return L("Recordings")
        case .annotated: return L("Annotated")
        case .today: return L("Today")
        case .lastWeek: return L("Last 7 Days")
        case .lastMonth: return L("Last 30 Days")
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .screenshots: return "photo"
        case .recordings: return "video"
        case .annotated: return "pencil.tip.crop.circle"
        case .today: return "calendar"
        case .lastWeek, .lastMonth: return "calendar.badge.clock"
        }
    }

    func contains(_ item: LibraryItem, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .all: return true
        case .screenshots: return item.kind == .screenshot
        case .recordings: return item.kind == .recording
        case .annotated: return item.isAnnotated
        case .today: return calendar.isDate(item.createdAt, inSameDayAs: now)
        case .lastWeek: return item.createdAt >= now.addingTimeInterval(-7 * 86_400)
        case .lastMonth: return item.createdAt >= now.addingTimeInterval(-30 * 86_400)
        }
    }
}

enum LibraryViewMode: String { case grid, list }

/// Backing store for the library window: everything macshot keeps — the
/// screenshots in history and the takes in the recording library — as one
/// browsable list. It reads both stores and never copies from either.
@MainActor
final class LibraryModel: ObservableObject {

    @Published private(set) var items: [LibraryItem] = []
    @Published var section: LibrarySection? = .all
    @Published var search = ""
    @Published var selection = Set<String>()
    @Published var sortOrder = [KeyPathComparator(\LibraryItem.createdAt, order: .reverse)]
    @Published var viewMode: LibraryViewMode {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: Self.viewModeKey) }
    }
    /// The inspector is wanted (toggled with Info, remembered); it shows only
    /// while something is selected.
    @Published var wantsInspector: Bool {
        didSet { UserDefaults.standard.set(wantsInspector, forKey: Self.inspectorKey) }
    }

    /// Drives `.inspector(isPresented:)`: open while wanted and something is
    /// selected. Closing it by hand turns the wish off.
    var inspectorPresented: Bool {
        get { wantsInspector && !selection.isEmpty }
        set { if !newValue, !selection.isEmpty { wantsInspector = false } }
    }
    @Published var quickLookURL: URL?
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    /// Lengths of takes, filled in as their poster frames load.
    @Published private(set) var durations: [String: Double] = [:]

    private static let viewModeKey = "libraryViewMode"
    private static let inspectorKey = "libraryShowsInspector"
    private var observers: [NSObjectProtocol] = []
    private var thumbnailsInFlight = Set<String>()
    private var reloadToken = UUID()

    init() {
        viewMode = LibraryViewMode(rawValue: UserDefaults.standard.string(forKey: Self.viewModeKey) ?? "") ?? .grid
        wantsInspector = UserDefaults.standard.object(forKey: Self.inspectorKey) as? Bool ?? true
        // Load before observing: the first touch of ScreenshotHistory.shared
        // initialises it, and the change it posts while doing so would call
        // reload() back into that initialiser.
        reload()
        for name in [ScreenshotHistory.didChange, RecordingLibrary.didChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Contents

    /// The items for the current section and search, in the current order.
    var visibleItems: [LibraryItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        return items
            .filter { (section ?? .all).contains($0, now: now) }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || ($0.origin?.localizedCaseInsensitiveContains(query) ?? false) }
            .sorted(using: sortOrder)
    }

    var selectedItems: [LibraryItem] { items.filter { selection.contains($0.id) } }

    func count(in section: LibrarySection) -> Int {
        let now = Date()
        return items.filter { section.contains($0, now: now) }.count
    }

    /// Rebuild from both stores. Files are measured off the main thread.
    func reload() {
        // Only Sendable values cross into the worker; HistoryEntry carries an image.
        struct CaptureSeed: Sendable {
            let panelID, id, name: String
            let created: Date, edited: Date?, annotated: Bool
            let width, height: Int
            let title: String?
            let url: URL
        }
        let template = UserDefaults.standard.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
        let seeds = ScreenshotHistory.shared.entries.map { entry in
            CaptureSeed(panelID: HistoryPanelItem.captureID(entry.id), id: entry.id,
                        name: FilenameFormatter.format(template: template, windowTitle: entry.windowTitle, date: entry.timestamp),
                        created: entry.timestamp, edited: entry.lastEditedAt, annotated: entry.hasAnnotations,
                        width: entry.pixelWidth, height: entry.pixelHeight, title: entry.windowTitle,
                        url: ScreenshotHistory.shared.fileURL(for: entry))
        }
        let token = UUID()
        reloadToken = token
        Task.detached(priority: .userInitiated) {
            let takes = RecordingLibrary.takes()
            var built: [LibraryItem] = []
            built.reserveCapacity(seeds.count + takes.count)
            for seed in seeds {
                let size = (try? seed.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                built.append(LibraryItem(
                    id: seed.panelID, kind: .screenshot, sourceID: seed.id,
                    name: seed.name,
                    createdAt: seed.created, editedAt: seed.edited, isAnnotated: seed.annotated,
                    pixelWidth: seed.width, pixelHeight: seed.height,
                    fileURL: seed.url, fileSize: size, origin: seed.title))
            }
            for take in takes {
                built.append(LibraryItem(
                    id: HistoryPanelItem.recordingID(take.id), kind: .recording, sourceID: take.id,
                    name: take.title, createdAt: take.createdAt, editedAt: nil, isAnnotated: false,
                    pixelWidth: 0, pixelHeight: 0, fileURL: take.mediaURL, fileSize: take.fileSize, origin: nil))
            }
            let result = built
            await MainActor.run {
                guard self.reloadToken == token else { return }
                self.items = result
                let ids = Set(result.map(\.id))
                self.selection.formIntersection(ids)
                self.thumbnails = self.thumbnails.filter { ids.contains($0.key) }
            }
        }
    }

    // MARK: Thumbnails

    func loadThumbnail(for item: LibraryItem) {
        guard thumbnails[item.id] == nil, !thumbnailsInFlight.contains(item.id) else { return }
        thumbnailsInFlight.insert(item.id)
        let id = item.id
        switch item.kind {
        case .recording:
            guard let take = RecordingLibrary.take(in: item.fileURL.deletingLastPathComponent()) else {
                thumbnailsInFlight.remove(id)
                return
            }
            RecordingThumbnails.shared.load(take) { [weak self] info in
                guard let self else { return }
                self.thumbnailsInFlight.remove(id)
                if let info { self.durations[id] = info.duration }
                if let image = info?.image { self.thumbnails[id] = NSImage(cgImage: image, size: .zero) }
            }
        case .screenshot:
            guard let entry = ScreenshotHistory.shared.entries.first(where: { $0.id == item.sourceID }) else {
                thumbnailsInFlight.remove(id)
                return
            }
            let urls = ScreenshotHistory.shared.previewURLs(for: entry)
            Task.detached(priority: .utility) {
                let pixels = HistoryImageSnapshot.preview(at: urls)
                await MainActor.run {
                    self.thumbnailsInFlight.remove(id)
                    if let pixels { self.thumbnails[id] = NSImage(cgImage: pixels, size: .zero) }
                }
            }
        }
    }

    /// "1920 × 1080" for a screenshot, the length for a take.
    func detailText(for item: LibraryItem) -> String {
        if item.kind == .recording {
            return durations[item.id].map(RecordingThumbnails.durationText) ?? "—"
        }
        return item.dimensionsText
    }

    // MARK: Actions

    private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    func open(_ item: LibraryItem) {
        switch item.kind {
        case .screenshot: appDelegate?.openHistoryEntryInEditor(id: item.sourceID)
        case .recording: VideoEditorWindowController.open(url: item.fileURL)
        }
    }

    func copy(_ item: LibraryItem) {
        switch item.kind {
        case .screenshot:
            guard let index = ScreenshotHistory.shared.entries.firstIndex(where: { $0.id == item.sourceID }) else { return }
            ScreenshotHistory.shared.copyEntry(at: index)
            if UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true { CaptureSound.shared.play() }
        case .recording:
            appDelegate?.copyRecordingToClipboard(url: item.fileURL)
        }
    }

    func showInFinder(_ items: [LibraryItem]) {
        let urls = items.map(\.fileURL).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func saveCopy(_ item: LibraryItem) {
        switch item.kind {
        case .screenshot:
            guard let entry = ScreenshotHistory.shared.entries.first(where: { $0.id == item.sourceID }),
                  let image = ScreenshotHistory.shared.loadImage(for: entry) else { return }
            ImageSaveService.showSavePanel(for: image, suggestedFilename: "\(item.name).\(ImageEncoder.fileExtension)")
        case .recording:
            appDelegate?.promptToSaveRecording(tmpURL: item.fileURL)
        }
    }

    func quickLook(_ item: LibraryItem) {
        quickLookURL = item.fileURL
    }

    /// Takes go to the Trash, folder and all. Screenshots leave history for
    /// good, so they are confirmed first.
    func delete(_ items: [LibraryItem]) {
        let screenshots = items.filter { $0.kind == .screenshot }
        if !screenshots.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(format: L("Delete %d screenshots?"), screenshots.count)
            alert.informativeText = L("They are removed from history permanently.")
            alert.addButton(withTitle: L("Delete"))
            alert.addButton(withTitle: L("Cancel"))
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            screenshots.forEach { ScreenshotHistory.shared.removeEntry(id: $0.sourceID) }
        }
        for item in items where item.kind == .recording {
            guard let take = RecordingLibrary.take(in: item.fileURL.deletingLastPathComponent()) else { continue }
            do { try RecordingLibrary.moveToTrash(take) }
            catch { appDelegate?.showFailureToast(error.localizedDescription) }
        }
        selection.subtract(items.map(\.id))
        reload()
    }
}
