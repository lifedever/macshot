import AVFoundation
import AppKit
import os

/// One take in the recording library, as the history panel and the library
/// window list it.
struct RecordingTake: Identifiable, Equatable, Sendable {
    /// The take folder's name (a UUID).
    let id: String
    let folder: URL
    let mediaURL: URL
    let createdAt: Date
    let fileSize: Int64
    /// The take ended with an error; what was written is kept and playable.
    let wasInterrupted: Bool

    var title: String { mediaURL.deletingPathExtension().lastPathComponent }
}

extension RecordingLibrary {

    private static let writing = OSAllocatedUnfairLock(initialState: Set<String>())

    /// The engine is writing into `folder`; it is not listed until it finishes.
    nonisolated static func beginWriting(_ folder: URL) {
        writing.withLock { _ = $0.insert(folder.standardizedFileURL.path) }
    }

    nonisolated static func endWriting(_ folder: URL) {
        writing.withLock { _ = $0.remove(folder.standardizedFileURL.path) }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// Every finished take in every library location, newest first. A take a
    /// crash left marked "recording" is listed too — its bytes are recoverable;
    /// only the one being written right now is not. Call from a worker for a
    /// large library: it reads one small property list per take.
    nonisolated static func takes() -> [RecordingTake] {
        let active = writing.withLock { $0 }
        return allRoots.flatMap(sessionDirectories(in:)).compactMap { folder -> RecordingTake? in
            guard !active.contains(folder.standardizedFileURL.path) else { return nil }
            return take(in: folder)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    nonisolated static func take(in folder: URL) -> RecordingTake? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let filename = plist["filename"] as? String,
              !filename.isEmpty, !filename.contains("/") else { return nil }
        let media = folder.appendingPathComponent(filename)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: media.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else { return nil }
        let created = plist["createdAt"] as? Date ?? (attributes[.creationDate] as? Date) ?? .distantPast
        return RecordingTake(id: folder.lastPathComponent, folder: folder, mediaURL: media,
                             createdAt: created, fileSize: size,
                             wasInterrupted: (plist["status"] as? String) == "interrupted")
    }

    /// Move a take's whole folder — media, pointer data, Studio project — to
    /// the Trash, where it can be put back.
    @MainActor
    static func moveToTrash(_ take: RecordingTake) throws {
        guard !VideoEditorWindowController.isEditing(take.mediaURL) else {
            throw TakeInUse()
        }
        try FileManager.default.trashItem(at: take.folder, resultingItemURL: nil)
        RecordingThumbnails.shared.forget(take.id)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    struct TakeInUse: LocalizedError {
        var errorDescription: String? { L("Close this recording in the video editor first.") }
    }
}

/// Poster frames and durations for takes, cached beside each take
/// (`thumbnail.jpg`, `thumbnail.plist`) so a library of hundreds opens
/// without decoding hundreds of movies.
@MainActor
final class RecordingThumbnails {
    static let shared = RecordingThumbnails()

    struct Info: Sendable {
        let image: CGImage?
        let duration: Double
        let pixelSize: CGSize
    }

    private var cache: [String: Info] = [:]
    private var order: [String] = []
    private var inFlight: [String: [(Info?) -> Void]] = [:]
    private static let cacheLimit = 200

    func cached(_ take: RecordingTake) -> Info? { cache[take.id] }

    func forget(_ id: String) {
        cache.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    /// The take's poster frame and duration; `completion` runs on the main
    /// thread, with nil when the movie has no readable video.
    func load(_ take: RecordingTake, completion: @escaping (Info?) -> Void) {
        if let hit = cache[take.id] { completion(hit); return }
        if inFlight[take.id] != nil { inFlight[take.id]?.append(completion); return }
        inFlight[take.id] = [completion]
        let id = take.id
        Task.detached(priority: .utility) {
            let info = await Self.info(for: take)
            await MainActor.run {
                let waiting = self.inFlight.removeValue(forKey: id) ?? []
                if let info { self.store(info, for: id) }
                waiting.forEach { $0(info) }
            }
        }
    }

    private func store(_ info: Info, for id: String) {
        cache[id] = info
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > Self.cacheLimit { cache.removeValue(forKey: order.removeFirst()) }
    }

    nonisolated private static func info(for take: RecordingTake) async -> Info? {
        let imageURL = take.folder.appendingPathComponent("thumbnail.jpg")
        let infoURL = take.folder.appendingPathComponent("thumbnail.plist")
        if let data = try? Data(contentsOf: infoURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let duration = plist["duration"] as? Double,
           let width = plist["width"] as? Double, let height = plist["height"] as? Double,
           let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return Info(image: image, duration: duration, pixelSize: CGSize(width: width, height: height))
        }
        let asset = AVURLAsset(url: take.mediaURL)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        var pixelSize = CGSize.zero
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let size = natural.applying(transform)
            pixelSize = CGSize(width: abs(size.width), height: abs(size.height))
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        // Not frame zero: a take often starts on a frame the capture pipeline
        // had not filled in yet, which reads as a black card.
        let image = try? await generator.image(at: CMTime(seconds: min(0.15, max(duration / 2, 0)), preferredTimescale: 600)).image
        guard image != nil || duration > 0 else { return nil }
        if let image, let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            if CGImageDestinationFinalize(destination),
               let data = try? PropertyListSerialization.data(
                   fromPropertyList: ["version": 1, "duration": duration,
                                      "width": Double(pixelSize.width), "height": Double(pixelSize.height)],
                   format: .xml, options: 0) {
                try? data.write(to: infoURL, options: .atomic)
            }
        }
        return Info(image: image, duration: duration, pixelSize: pixelSize)
    }

    /// "1:05", or "1:02:05" past an hour.
    nonisolated static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
