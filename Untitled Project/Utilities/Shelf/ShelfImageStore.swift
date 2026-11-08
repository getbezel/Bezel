import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Only files created inside this session's private directory can be removed by Shelf.
actor ShelfImageStore {
    private let directory: URL
    private var files: [URL: Int] = [:]
    private var bytes = 0
    private let budget: Int

    init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Bezel-Shelf-\(UUID().uuidString)", isDirectory: true), budget: Int = 128 * 1_024 * 1_024) {
        self.directory = directory
        self.budget = budget
    }

    func createImage(_ data: Data) throws -> URL {
        try Task.checkCancellation()
        guard data.count <= 32 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 32_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ShelfImageError.invalidImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw ShelfImageError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ShelfImageError.encodingFailed }
        try Task.checkCancellation()
        guard output.length <= budget - bytes else { throw ShelfImageError.storageFull }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = directory.appendingPathComponent("Capture \(formatter.string(from: .now))-\(UUID().uuidString.prefix(6)).png")
        try (output as Data).write(to: url, options: .atomic)
        files[url] = output.length
        bytes += output.length
        return url
    }

    func remove(_ url: URL) {
        guard let count = files.removeValue(forKey: url) else { return }
        bytes -= count
        try? FileManager.default.removeItem(at: url)
    }

    func clear() {
        // The directory is private to this store. Original user files are never registered here.
        try? FileManager.default.removeItem(at: directory)
        files.removeAll()
        bytes = 0
    }
}

private enum ShelfImageError: LocalizedError {
    case invalidImage, encodingFailed, storageFull
    var errorDescription: String? {
        switch self {
        case .invalidImage: "Choose an image under 32 MB and 32 megapixels."
        case .encodingFailed: "This image could not be prepared for Shelf."
        case .storageFull: "Shelf's temporary images use 128 MB. Remove some images to make room."
        }
    }
}

/// Keeps a moved or resized drawer inside the usable area of its display.
enum ShelfPlacement {
    static func constrained(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let width = min(max(frame.width, 280), visible.width)
        let height = min(max(frame.height, 240), visible.height)
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - height),
                      width: width, height: height)
    }
}
