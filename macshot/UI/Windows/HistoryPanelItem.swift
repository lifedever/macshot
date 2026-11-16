import Foundation

/// Something the history panel (and the library window) lists: a capture
/// from screenshot history, or a take from the recording library.
///
/// The two keep their own stores — history is a transactional index with its
/// own retention; the recording library is its folders on disk — and are only
/// merged for display. Recordings never count toward the history limit.
enum HistoryPanelItem {
    case capture(HistoryEntry)
    case recording(RecordingTake)

    /// Unique across both kinds.
    var id: String {
        switch self {
        case .capture(let entry): return "capture:" + entry.id
        case .recording(let take): return "recording:" + take.id
        }
    }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var capture: HistoryEntry? {
        if case .capture(let entry) = self { return entry }
        return nil
    }

    var recording: RecordingTake? {
        if case .recording(let take) = self { return take }
        return nil
    }

    var createdAt: Date {
        switch self {
        case .capture(let entry): return entry.timestamp
        case .recording(let take): return take.createdAt
        }
    }

    /// Captures in the order history keeps them, takes newest first, merged
    /// by the date that order is based on — the last edit when history is
    /// ordered by edits, otherwise when each was made.
    static func merged(captures: [HistoryEntry], takes: [RecordingTake],
                       orderByLastEdit: Bool) -> [HistoryPanelItem] {
        func date(_ entry: HistoryEntry) -> Date { orderByLastEdit ? entry.effectiveSortDate : entry.timestamp }
        var result: [HistoryPanelItem] = []
        result.reserveCapacity(captures.count + takes.count)
        var c = 0, t = 0
        while c < captures.count || t < takes.count {
            if t >= takes.count || (c < captures.count && date(captures[c]) >= takes[t].createdAt) {
                result.append(.capture(captures[c])); c += 1
            } else {
                result.append(.recording(takes[t])); t += 1
            }
        }
        return result
    }
}
