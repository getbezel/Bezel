import Foundation

enum ClipboardKind: String, Sendable, CaseIterable {
    case text = "Text"
    case richText = "Rich text"
    case image = "Image"
    case files = "Files"
    case binary = "Data"

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .image: "photo"
        case .files: "doc.on.doc"
        case .binary: "number.square"
        }
    }
}

struct ClipboardEntry: Identifiable, Sendable {
    let id: UUID
    let kind: ClipboardKind
    let title: String
    let preview: String
    let detail: String
    let sourceName: String
    let sourceBundleIdentifier: String?
    let capturedAt: Date
    let thumbnailData: Data?
    let byteCount: Int
}

struct ClipboardRepresentation: Sendable {
    let type: String
    let data: Data
}

struct ClipboardPayload: Sendable {
    let entry: ClipboardEntry
    /// Each inner array represents one original NSPasteboardItem.
    let items: [[ClipboardRepresentation]]
}

struct ClipboardSnapshot: Sendable {
    let revision: Int
    let history: [ClipboardEntry]
    let queue: [ClipboardEntry]
    let byteCount: Int
}

/// Clipboard contents never leave memory. A queued item survives history eviction.
actor ClipboardStore {
    static let maximumItemBytes = 24 * 1_024 * 1_024
    private let maximumBytes = 64 * 1_024 * 1_024
    private let maximumItems = 50
    private var payloads: [UUID: ClipboardPayload] = [:]
    private var history: [UUID] = []
    private var queue: [UUID] = []
    private var revision = 0

    func record(_ payload: ClipboardPayload, enqueue: Bool) -> ClipboardSnapshot {
        let id = payload.entry.id
        payloads[id] = payload
        history.insert(id, at: 0)
        if enqueue, queue.count < maximumItems { queue.append(id) }
        trim()
        revision += 1
        return snapshot()
    }

    func enqueue(_ id: UUID) -> ClipboardSnapshot {
        if payloads[id] != nil, queue.count < maximumItems { queue.append(id) }
        trim()
        revision += 1
        return snapshot()
    }

    func payload(for id: UUID) -> ClipboardPayload? { payloads[id] }

    func firstQueued() -> ClipboardPayload? {
        queue.first.flatMap { payloads[$0] }
    }

    func consumeFirst(expectedID: UUID) -> ClipboardSnapshot {
        if queue.first == expectedID { queue.removeFirst() }
        removeUnreferenced()
        revision += 1
        return snapshot()
    }

    func remove(_ id: UUID) -> ClipboardSnapshot {
        history.removeAll { $0 == id }
        queue.removeAll { $0 == id }
        payloads[id] = nil
        revision += 1
        return snapshot()
    }

    func clearQueue() -> ClipboardSnapshot {
        queue.removeAll()
        removeUnreferenced()
        revision += 1
        return snapshot()
    }

    func clear() -> ClipboardSnapshot {
        history.removeAll()
        queue.removeAll()
        payloads.removeAll()
        revision += 1
        return snapshot()
    }

    private func trim() {
        if history.count > maximumItems { history.removeLast(history.count - maximumItems) }
        removeUnreferenced()
        while storedBytes > maximumBytes, !history.isEmpty {
            history.removeLast()
            removeUnreferenced()
        }
        // Queued data is also bounded; drop the newest queued addition first.
        while storedBytes > maximumBytes, !queue.isEmpty {
            queue.removeLast()
            removeUnreferenced()
        }
    }

    private var storedBytes: Int { payloads.values.reduce(0) { $0 + $1.entry.byteCount } }

    private func removeUnreferenced() {
        let retained = Set(history).union(queue)
        payloads = payloads.filter { retained.contains($0.key) }
    }

    private func snapshot() -> ClipboardSnapshot {
        ClipboardSnapshot(
            revision: revision,
            history: history.compactMap { payloads[$0]?.entry },
            queue: queue.compactMap { payloads[$0]?.entry },
            byteCount: storedBytes
        )
    }
}
