import ImageIO
import SwiftUI

struct StudioHoverAccent: PreferenceKey {
    static let defaultValue: BezelModule? = nil
    static func reduce(value: inout BezelModule?, nextValue: () -> BezelModule?) {
        if let next = nextValue() { value = next }
    }
}

struct StudioDeskHover: ViewModifier {
    let module: BezelModule
    @State private var hovered = false

    func body(content: Content) -> some View {
        content.onHover { hovered = $0 }
            .preference(key: StudioHoverAccent.self, value: hovered ? module : nil)
    }
}

struct StudioHeaderBackdrop: View {
    let module: BezelModule
    let hovered: BezelModule?
    let metadata: NowPlayingMetadata
    @State private var coverColor: Color?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var usesArtwork: Bool { module == .overview || module == .aperture || module == .airBridge }

    var body: some View {
        let subdued = reduceTransparency || contrast == .increased
        let artwork = usesArtwork && !subdued ? metadata.selected?.artwork : nil
        let fallback = module == .overview ? Color.gray : module.tint
        let tint = (module == .overview ? hovered?.tint : nil) ?? (artwork == nil ? nil : coverColor) ?? fallback
        GeometryReader { viewport in
            ZStack(alignment: .top) {
                StudioColor.canvas
                if !subdued {
                    LinearGradient(stops: [
                        .init(color: tint.opacity(0.19), location: 0),
                        .init(color: tint.opacity(0.075), location: 0.45),
                        .init(color: tint.opacity(0), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(height: min(265, viewport.size.height * 0.38))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: tint)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: artwork) {
            guard let artwork else { coverColor = nil; return }
            let sampled = await Task.detached(priority: .utility) { StudioArtworkColor.sample(artwork) }.value
            guard !Task.isCancelled else { return }
            coverColor = sampled
        }
    }
}

enum StudioArtworkColor {
    /// Choose a representative hue from a thumbnail. Near-black borders and white lettering
    /// otherwise tend to overwhelm the cover. Neutral covers still get a graphite highlight.
    static func sample(_ data: Data) -> Color? {
        let side = 24
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return nil }
        var buckets = Array(repeating: (count: 0, r: 0, g: 0, b: 0), count: 64)
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] >= 240 {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            guard max(r, g, b) - min(r, g, b) >= 28 else { continue }
            let index = (r / 64) * 16 + (g / 64) * 4 + b / 64
            buckets[index].count += 1
            buckets[index].r += r
            buckets[index].g += g
            buckets[index].b += b
        }
        guard let best = buckets.max(by: { $0.count < $1.count }), best.count >= 6 else { return .gray }
        let scale = Double(best.count * 255)
        return Color(.sRGB, red: Double(best.r) / scale, green: Double(best.g) / scale, blue: Double(best.b) / scale)
    }
}
