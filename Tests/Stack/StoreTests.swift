import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct StoreTests {
    static func payload(_ title: String, byteCount: Int = 1) -> ClipboardPayload {
        let entry = ClipboardEntry(id: UUID(), kind: .text, title: title, preview: title, detail: "", sourceName: "Test", sourceBundleIdentifier: nil, capturedAt: .now, thumbnailData: nil, byteCount: byteCount)
        return ClipboardPayload(entry: entry, items: [[ClipboardRepresentation(type: "public.utf8-plain-text", data: Data(title.utf8))]])
    }
    static func require(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }
    static func main() async {
        let context = CGContext(data: nil, width: 2048, height: 1024, bitsPerComponent: 8, bytesPerRow: 2048 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1024))
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        require(CGImageDestinationFinalize(destination), "PNG fixture encoding failed")
        let image = ClipboardImage.preview(data: encoded as Data)
        require(image?.width == 2048 && image?.height == 1024, "Original pixel metadata must be preserved")
        let thumbnail = CGImageSourceCreateWithData(image!.thumbnail! as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(thumbnail, 0, nil) as! [String: Any]
        require((properties[kCGImagePropertyPixelWidth as String] as! Int) <= 240, "Thumbnail decode must be bounded")
        require(ClipboardImage.preview(data: Data("invalid".utf8)) == nil, "Invalid images must fail gracefully")
        let store = ClipboardStore()
        let first = payload("first")
        let second = payload("second")
        _ = await store.record(first, enqueue: true)
        var snapshot = await store.record(second, enqueue: true)
        require(snapshot.history.map(\.title) == ["second", "first"], "History must be newest first")
        require(snapshot.queue.map(\.title) == ["first", "second"], "Sequence must be FIFO")
        snapshot = await store.consumeFirst(expectedID: second.entry.id)
        require(snapshot.queue.count == 2, "A stale consumer must not pop a newer head")
        snapshot = await store.consumeFirst(expectedID: first.entry.id)
        require(snapshot.queue.first?.id == second.entry.id, "FIFO advancement failed")
        for index in 0..<60 { snapshot = await store.record(payload("item \(index)"), enqueue: false) }
        require(snapshot.history.count == 50, "History count must be bounded")
        let retained = await store.payload(for: second.entry.id)
        require(retained != nil, "Queued payload must survive history eviction")
        snapshot = await store.clearQueue()
        let released = await store.payload(for: second.entry.id)
        require(released == nil, "Unreferenced queued payload must be released")
        for index in 0..<60 { snapshot = await store.enqueue(snapshot.history[index % 50].id) }
        require(snapshot.queue.count == 50, "Queue must be bounded")
        snapshot = await store.clear()
        require(snapshot.byteCount == 0 && snapshot.history.isEmpty && snapshot.queue.isEmpty, "Clear must release all payloads")
        for index in 0..<8 { snapshot = await store.record(payload("large \(index)", byteCount: 24 * 1024 * 1024), enqueue: true) }
        require(snapshot.byteCount <= 64 * 1024 * 1024, "Queued entries must respect memory budget")
        require(snapshot.queue.map(\.title) == ["large 0", "large 1"], "Memory eviction must preserve FIFO head")
        let chosen = ClipboardStore()
        let a = payload("A"), b = payload("B"), c = payload("C")
        _ = await chosen.record(a, enqueue: true)
        _ = await chosen.record(b, enqueue: true)
        _ = await chosen.record(c, enqueue: true)
        let selectedPayload = await chosen.queuedPayload(for: b.entry.id)
        require(selectedPayload?.entry.id == b.entry.id, "Picker must fetch the selected clip, not the FIFO head")
        snapshot = await chosen.consumeQueued(expectedID: b.entry.id)
        require(snapshot.queue.map(\.id) == [a.entry.id, c.entry.id], "Selected paste must preserve unselected queue order")
        require(snapshot.history.count == 3, "Pasting a Quick Clip must preserve history")
        let alreadyPasted = await chosen.queuedPayload(for: b.entry.id)
        require(alreadyPasted == nil, "Consumed selections must no longer be pasteable as Quick Clips")
        snapshot = await chosen.consumeQueued(expectedID: b.entry.id)
        require(snapshot.queue.map(\.id) == [a.entry.id, c.entry.id], "A stale selection must not consume another clip")
        snapshot = await chosen.enqueue(a.entry.id)
        let beforeDelete = snapshot.revision
        snapshot = await chosen.remove(Set([a.entry.id, b.entry.id]))
        require(snapshot.revision == beforeDelete + 1, "Bulk deletion must be one atomic revision")
        require(snapshot.history.map(\.id) == [c.entry.id] && snapshot.queue.map(\.id) == [c.entry.id], "Bulk deletion must remove every selected occurrence from both collections")
        let removed = await chosen.payload(for: a.entry.id)
        require(removed == nil && snapshot.byteCount == c.entry.byteCount, "Bulk deletion must release selected payloads")
        snapshot = await chosen.clear()
        require(snapshot.history.isEmpty && snapshot.queue.isEmpty && snapshot.byteCount == 0, "Delete All must release both collections")
        print("Stack store checks passed: history bounds, FIFO, stale consumers, queued retention, release, memory budget, image downsampling, selected pasting, stale selections, and atomic bulk deletion.")
    }
}
