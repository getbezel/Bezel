import AppKit
import Foundation

private final class FixtureStops: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// Intercepts all test image requests; no connection to Spotify or other hosts occurs.
final class ArtworkFixture: URLProtocol, @unchecked Sendable {
    private static let stops = FixtureStops()
    static var stoppedCount: Int { stops.value }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        var headers = ["Content-Type": "image/png"]
        var data = Data()
        let status = url.path == "/image/forbidden" ? 403 : 200
        switch url.path {
        case "/image/oversized": headers["Content-Length"] = String(SpotifyArtwork.maximumBytes + 1)
        case "/image/chunked": data = Data(count: SpotifyArtwork.maximumBytes + 1)
        case "/image/html": headers["Content-Type"] = "text/html"; data = Data("not an image".utf8)
        case "/image/valid":
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
            bitmap.bitmapData!.initialize(repeating: 255, count: 16)
            data = bitmap.representation(using: .png, properties: [:])!
            headers["Content-Length"] = String(data.count)
        default: break
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path == "/image/slow" { return }
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.stops.record() }
}
