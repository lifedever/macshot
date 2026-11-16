import Foundation
import os

/// Where recording takes live: one folder per take, holding the MP4 original
/// with its session record, pointer data, camera file and Studio project.
///
/// The default is the container's Application Support. The user can move it
/// (Settings › Recording), usually to a bigger or external disk. The choice is
/// a security-scoped bookmark whose scope stays open while the app runs, since
/// takes are written, read and edited at any time.
///
/// Takes left in an earlier location stay part of the library until they are
/// moved: `allRoots` lists every folder that may still hold one, so they are
/// listed, opened as durable originals and never swept as temporary files.
/// A configured location that can't be reached (an unplugged disk) is left
/// out, and new takes go to the default location so a recording is never lost.
enum RecordingLibrary {

    static let bookmarkKey = "recordingLibraryBookmark"
    static let pastBookmarksKey = "recordingLibraryPastBookmarks"

    /// Posted on the main thread when the location or the set of roots changes.
    static let didChangeNotification = Notification.Name("RecordingLibraryDidChange")

    private struct State {
        /// The configured location, when it was reachable.
        var custom: URL?
        /// Earlier configured locations that were reachable.
        var past: [URL] = []
        /// A location is configured but could not be reached.
        var customUnavailable = false
        var customPath: String?
    }

    nonisolated private static let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: Roots

    /// The container library. Always available.
    nonisolated static var defaultRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("com.sw33tlie.macshot/Recordings", isDirectory: true)
    }

    /// Where new takes are written.
    nonisolated static var currentRoot: URL {
        state.withLock { $0.custom } ?? defaultRoot
    }

    /// Every folder whose takes belong to the library: the current one first,
    /// then the default and any earlier location that still exists.
    nonisolated static var allRoots: [URL] {
        let snapshot = state.withLock { $0 }
        var roots: [URL] = []
        for root in [snapshot.custom ?? defaultRoot, defaultRoot] + snapshot.past
        where !roots.contains(where: { sameFolder($0, root) }) {
            roots.append(root)
        }
        return roots
    }

    nonisolated static var usesDefaultLocation: Bool {
        state.withLock { $0.custom == nil && $0.customPath == nil }
    }

    /// A location is configured but could not be reached at launch.
    nonisolated static var isConfiguredLocationUnavailable: Bool {
        state.withLock { $0.customUnavailable }
    }

    /// The configured location for display, reachable or not.
    nonisolated static var displayPath: String {
        let path = state.withLock { $0.custom?.path ?? $0.customPath } ?? defaultRoot.path
        return (path as NSString).abbreviatingWithTildeInPath
    }

    nonisolated static func sameFolder(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: Lifecycle

    /// Resolve the stored locations and open their scopes for the life of the
    /// app. Call once at launch, before anything records or opens a take.
    static func activate(defaults: UserDefaults = .standard) {
        var next = State()
        if let data = defaults.data(forKey: bookmarkKey) {
            switch resolve(data) {
            case .reachable(let url, let fresh):
                next.custom = url
                next.customPath = url.path
                if let fresh { defaults.set(fresh, forKey: bookmarkKey) }
            case .unreachable(let path):
                next.customUnavailable = true
                next.customPath = path
            }
        }
        var keptPast: [Data] = []
        for data in defaults.array(forKey: pastBookmarksKey) as? [Data] ?? [] {
            switch resolve(data) {
            case .reachable(let url, let fresh):
                // A past location holds takes until they are moved out.
                guard !sessionDirectories(in: url).isEmpty else { continue }
                next.past.append(url)
                keptPast.append(fresh ?? data)
            case .unreachable:
                // An unplugged disk may come back; keep the record.
                keptPast.append(data)
            }
        }
        defaults.set(keptPast, forKey: pastBookmarksKey)
        let resolved = next
        state.withLock { $0 = resolved }
    }

    /// Point new takes at `url`, or at the default location for `nil`. The
    /// previous custom location joins the past roots, so its takes stay listed
    /// until they are moved. `url` must come from an open panel, so it carries
    /// the sandbox grant needed to create the bookmark.
    static func setLocation(_ url: URL?, defaults: UserDefaults = .standard) throws {
        let previous = state.withLock { $0 }
        if let url, sameFolder(url, previous.custom ?? defaultRoot) { return }
        var past = defaults.array(forKey: pastBookmarksKey) as? [Data] ?? []
        if let old = previous.custom,
           let data = try? old.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            past.append(data)
        }
        if let url {
            guard url.startAccessingSecurityScopedResource() || FileManager.default.isWritableFile(atPath: url.path) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(data, forKey: bookmarkKey)
        } else {
            defaults.removeObject(forKey: bookmarkKey)
        }
        defaults.set(past, forKey: pastBookmarksKey)
        activate(defaults: defaults)
        postChange()
    }

    // MARK: Takes

    /// The take folders in `root`: UUID-named folders with a session record.
    nonisolated static func sessionDirectories(in root: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name in
            guard UUID(uuidString: name) != nil else { return nil }
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("session.plist").path) else {
                return nil
            }
            return folder
        }
    }

    /// Takes outside the current location, which "Move recordings" would bring over.
    nonisolated static func takesOutsideCurrentLocation() -> [URL] {
        let current = currentRoot
        return allRoots.filter { !sameFolder($0, current) }.flatMap(sessionDirectories(in:))
    }

    nonisolated struct MigrationResult: Equatable, Sendable {
        var moved = 0
        var failed = 0
    }

    /// Move `sessions` into `destination`, one folder at a time. On the same
    /// volume that is a rename. Across volumes the folder is copied and the
    /// original removed only once the copy is complete: a failed copy leaves
    /// the original where it was (and still part of the library through its
    /// old root), and a complete copy is never removed. Call from a worker.
    nonisolated static func move(_ sessions: [URL], into destination: URL,
                                 cancellation: MediaExportCancellation = MediaExportCancellation(),
                                 copyingAcrossVolumes forceCopy: Bool = false,
                                 progress: @Sendable (Double) -> Void = { _ in }) throws -> MigrationResult {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let destinationVolume = volume(of: destination)
        var result = MigrationResult()
        for (index, source) in sessions.enumerated() {
            try cancellation.check()
            defer { progress(Double(index + 1) / Double(max(sessions.count, 1))) }
            let target = destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else {
                result.failed += 1
                continue
            }
            if !forceCopy, let destinationVolume, volume(of: source) == destinationVolume {
                do {
                    try fm.moveItem(at: source, to: target)
                    result.moved += 1
                } catch {
                    result.failed += 1
                }
                continue
            }
            do {
                try fm.copyItem(at: source, to: target)
            } catch {
                try? fm.removeItem(at: target)
                result.failed += 1
                continue
            }
            // The copy is whole; only now does the original go. If that
            // fails, both stay — the copy in the current location is the take.
            try? fm.removeItem(at: source)
            result.moved += 1
        }
        return result
    }

    nonisolated private static func volume(of url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    /// Drop past locations that no longer hold any take.
    static func forgetEmptyPastRoots(defaults: UserDefaults = .standard) {
        activate(defaults: defaults)
        postChange()
    }

    // MARK: Private

    private enum Resolution {
        case reachable(URL, freshBookmark: Data?)
        case unreachable(path: String?)
    }

    private static func resolve(_ data: Data) -> Resolution {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return .unreachable(path: nil)
        }
        let started = url.startAccessingSecurityScopedResource()
        var isDirectory: ObjCBool = false
        guard started, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            if started { url.stopAccessingSecurityScopedResource() }
            return .unreachable(path: url.path)
        }
        // Refreshing a stale bookmark needs the scope open, so it comes after.
        let fresh = stale
            ? try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            : nil
        return .reachable(url, freshBookmark: fresh)
    }

    private static func postChange() {
        let post = { NotificationCenter.default.post(name: didChangeNotification, object: nil) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }
}
