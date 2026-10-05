import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ClipboardImagePreview: Sendable {
    let width: Int
    let height: Int
    let thumbnail: Data?
}

enum ClipboardImage {
    /// Downsamples at decode time, rather than rendering an unbounded full-resolution NSImage.
    static func preview(data: Data) -> ClipboardImagePreview? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
            kCGImageSourceShouldCacheImmediately: true
        ]
        var thumbnailData: Data?
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            let result = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination) { thumbnailData = result as Data }
            }
        }
        return ClipboardImagePreview(width: width, height: height, thumbnail: thumbnailData)
    }
}
