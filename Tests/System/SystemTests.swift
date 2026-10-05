import Foundation
import IOKit.pwr_mgt

@main struct SystemTests {
    static func require(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }
    @MainActor static func main() async throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let destination = fixture.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let listing = try SafeArchive.inspect(fixture.appendingPathComponent("normal.tar.gz"))
        require(listing.entries.map(\.path) == ["folder/hello world.txt", "folder/.hidden"] && !listing.isTruncated, "Archive inspection must enumerate headers in order")
        require(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty, "Archive inspection must not extract files")
        let unsafeListing = try SafeArchive.inspect(fixture.appendingPathComponent("traversal.tar"))
        require(unsafeListing.entries.first?.warning != nil, "Inspection must flag unsafe paths")
        let oversizedListing = try SafeArchive.inspect(fixture.appendingPathComponent("oversized.tar"))
        require(oversizedListing.isTruncated, "Inspection must stop before reading oversized entry bodies")
        let extracted = try SafeArchive.extract(fixture.appendingPathComponent("normal.tar.gz"), into: destination)
        let content = try String(contentsOf: extracted.appendingPathComponent("folder/hello world.txt"), encoding: .utf8)
        require(content == "Bezel archive verification\n", "Archive payload was corrupted")
        let rar = try SafeArchive.extract(fixture.appendingPathComponent("normal.rar"), into: destination)
        require(try String(contentsOf: rar.appendingPathComponent("helloworld.txt"), encoding: .utf8) == "hello libarchive test suite!\n", "Native RAR5 extraction failed")
        let sevenzip = try SafeArchive.extract(fixture.appendingPathComponent("normal.7z"), into: destination)
        require(try String(contentsOf: sevenzip.appendingPathComponent("hello.txt"), encoding: .utf8) == "Bezel 7z verification\n", "Native 7z extraction failed")
        let hidden = extracted.appendingPathComponent("folder/.hidden")
        require(FileManager.default.fileExists(atPath: hidden.path), "Hidden archive entries must be retained")
        let second = try SafeArchive.extract(fixture.appendingPathComponent("normal.tar.gz"), into: destination)
        require(second != extracted, "Extraction must never overwrite an existing result")
        for name in ["traversal", "absolute", "symlink", "hardlink", "duplicate", "device", "oversized"] {
            var rejected = false
            do { _ = try SafeArchive.extract(fixture.appendingPathComponent(name + ".tar"), into: destination) }
            catch { rejected = true }
            require(rejected, "Unsafe archive must be rejected: \(name)")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        require(!leftovers.contains(where: { $0.hasPrefix(".bezel-extract-") }), "Failed extraction staging must be removed")
        let compressed = fixture.appendingPathComponent("roundtrip.zip")
        try SafeArchive.compress(extracted, to: compressed)
        let roundtrip = try SafeArchive.extract(compressed, into: destination)
        let recovered = roundtrip.appendingPathComponent(extracted.lastPathComponent).appendingPathComponent("folder/hello world.txt")
        require(try String(contentsOf: recovered, encoding: .utf8) == content, "ZIP compression must round-trip")
        var overwriteRejected = false
        do { try SafeArchive.compress(extracted, to: compressed) } catch { overwriteRejected = true }
        require(overwriteRejected, "Compression must refuse existing archives")
        let valid = URL(string: "bezel://scope?action=analyze&path=%2Ftmp%2Fhello%20world")!
        require(ScopeRequest(url: valid)?.file.path == "/tmp/hello world", "Finder request percent decoding failed")
        require(ScopeRequest(url: URL(string: "bezel://scope?action=inspect&path=%2Ftmp%2Farchive.7z")!)?.action == .inspect, "Finder must support the inspection action")
        for raw in ["https://scope?action=analyze&path=%2Ftmp", "bezel://scope?action=delete&path=%2Ftmp", "bezel://scope?action=analyze&path=relative", "bezel://scope?action=analyze&path=%2Ftmp&path=%2Fetc", "bezel://scope?action=analyze&path=%2Ftmp%00bad"] {
            require(ScopeRequest(url: URL(string: raw)!) == nil, "Invalid Finder request accepted")
        }
        let scope = ScopeService()
        scope.scan(url: extracted)
        while scope.isScanning { try await Task.sleep(for: .milliseconds(20)) }
        require(scope.lastError == nil, "Scope fixture scan failed")
        require(scope.root?.fileCount == 2, "Scope must count visible and hidden regular files")
        require((scope.root?.allocatedBytes ?? 0) > 0, "Scope must report allocated file blocks")
        scope.scan(url: extracted)
        scope.cancel()
        try await Task.sleep(for: .milliseconds(50))
        require(!scope.isScanning, "Cancelled scans must not resurrect progress")
        scope.inspectArchive(fixture.appendingPathComponent("normal.7z"))
        while scope.isInspecting { try await Task.sleep(for: .milliseconds(10)) }
        require(scope.inspection?.entries.first?.path == "hello.txt" && scope.inspectionError == nil, "Scope must publish real archive entries")
        scope.inspectArchive(fixture.appendingPathComponent("normal.rar"))
        scope.dismissInspection()
        try await Task.sleep(for: .milliseconds(30))
        require(scope.inspectedArchive == nil && scope.inspection == nil && !scope.isInspecting, "Closing inspection must not resurrect its sheet")
        let origin = ContinuousClock.now
        let countdown = SessionCountdown(seconds: 60, now: origin)
        require(countdown.remainingSeconds(at: origin.advanced(by: .milliseconds(59_999))) == 1, "A countdown must retain its final fraction of a second")
        require(countdown.remainingSeconds(at: origin.advanced(by: .seconds(60))) == 0 && countdown.remainingSeconds(at: origin.advanced(by: .seconds(86_400))) == 0, "Expired countdowns must remain zero after elapsed sleep time")
        var instant = origin
        let pulse = PulseService(now: { instant })
        pulse.start(minutes: 1)
        require(pulse.isActive, "Pulse must create a power assertion")
        require(ownPulseAssertions() > 0, "Pulse must register assertions with macOS, not just update its state")
        instant = origin.advanced(by: .seconds(61))
        let expiryDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while pulse.isActive && ContinuousClock.now < expiryDeadline { try await Task.sleep(for: .milliseconds(20)) }
        require(!pulse.isActive && pulse.remainingSeconds == nil && pulse.status.hasPrefix("Countdown complete."), "Pulse countdown expiry must stop the session")
        require(ownPulseAssertions() == 0, "Countdown expiry must release the actual macOS assertions")
        pulse.start()
        require(pulse.isActive && ownPulseAssertions() > 0, "Pulse must be restartable after expiry")
        pulse.stop()
        require(!pulse.isActive && pulse.remainingSeconds == nil && ownPulseAssertions() == 0, "Pulse must release its assertions")
        print("System checks passed: bounded read-only archive inspection, tar.gz/RAR5/7z extraction, ZIP round trip, 7 unsafe archive cases, cleanup, Finder request validation, storage allocation, scan/inspection cancellation, monotonic countdown expiry, and actual macOS power assertion creation/release/restart.")
    }

    static func ownPulseAssertions() -> Int {
        var assertions: Unmanaged<CFDictionary>?
        require(IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess, "macOS power assertion inspection failed")
        guard let assertions else { return 0 }
        let dictionary = assertions.takeRetainedValue() as NSDictionary
        let entries = dictionary[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] as? [[String: Any]] ?? []
        return entries.filter { $0[kIOPMAssertionNameKey as String] as? String == "Bezel Pulse active session" }.count
    }
}
