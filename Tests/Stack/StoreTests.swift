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
        print("Stack store checks passed: history bounds, FIFO, stale consumers, queued retention, release, memory budget, and image downsampling.")
    }
}
