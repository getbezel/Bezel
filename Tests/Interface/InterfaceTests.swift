import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Synchronization

@main struct InterfaceTests {
    static func require(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }
    static func png() -> Data {
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        require(CGImageDestinationFinalize(destination), "Image fixture must encode")
        return data as Data
    }
    @MainActor final class CommandState {
        var trusted = true
        var modifiers: CGEventFlags = [.maskShift, .maskCommand]
        var active = false
        var restored = false
        var delivered: [CGEvent] = []
        var environment: ClipboardCommandExecutor.Environment {
            .init(isTrusted: { self.trusted }, heldModifiers: { self.modifiers },
                  restoreFocus: { self.restored = true }, isTargetActive: { self.active },
                  deliver: { self.delivered = $0; return true })
        }
    }

    @MainActor static func commandChecks() async throws {
        let state = CommandState()
        let release = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(25))
            require(!state.restored && state.delivered.isEmpty, "Copy must wait for the physical shortcut modifiers to be released")
            state.modifiers = []
            try await Task.sleep(for: .milliseconds(25))
            state.active = true
        }
        try await ClipboardCommandExecutor.execute(key: 8, environment: state.environment)
        try await release.value
        require(state.restored && state.delivered.count == 2, "Copy must restore the target before delivering key down/up")
        require(state.delivered.allSatisfy { $0.flags == .maskCommand && $0.getIntegerValueField(.keyboardEventKeycode) == 8 }, "Copy must remove Shift and preserve only Command-C")
        require(state.delivered.map(\.type) == [.keyDown, .keyUp], "Clipboard commands need a complete key pair")

        let blocked = CommandState(); blocked.trusted = false
        do { try await ClipboardCommandExecutor.execute(key: 9, environment: blocked.environment); fatalError("Untrusted paste accepted") }
        catch ClipboardCommandExecutor.Failure.permission {}
        require(blocked.delivered.isEmpty && !blocked.restored, "Denied permission must never post or change focus")
        let held = CommandState()
        do { try await ClipboardCommandExecutor.execute(key: 9, environment: held.environment, timeout: .milliseconds(25)); fatalError("Held modifiers accepted") }
        catch ClipboardCommandExecutor.Failure.modifiersHeld {}
        require(held.delivered.isEmpty && !held.restored, "Modifier timeout must preserve input")
        let canceled = CommandState()
        let pending = Task { try await ClipboardCommandExecutor.execute(key: 9, environment: canceled.environment) }
        try await Task.sleep(for: .milliseconds(20)); pending.cancel()
        do { try await pending.value; fatalError("Canceled clipboard command delivered") } catch is CancellationError {}
        require(canceled.delivered.isEmpty && !canceled.restored, "Cancel must stop a pending command before activating the target")
        let lost = CommandState(); lost.modifiers = []; lost.active = true
        let focusChange = Task { @MainActor in try await Task.sleep(for: .milliseconds(20)); lost.active = false }
        do { try await ClipboardCommandExecutor.execute(key: 9, environment: lost.environment); fatalError("Paste delivered after target lost focus") }
        catch ClipboardCommandExecutor.Failure.focus {}
        try await focusChange.value
        require(lost.delivered.isEmpty, "A late focus change must prevent paste into another app")
        let paste = CommandState(); paste.modifiers = []; paste.active = true
        try await ClipboardCommandExecutor.execute(key: 9, environment: paste.environment)
        require(paste.delivered.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 9 && $0.flags == .maskCommand }, "Paste must deliver only Command-V")
    }

    static func callbackChecks() async throws {
        let success: Int = try await CallbackDeadline.perform(timeout: .seconds(1)) { reply in
            reply(.success(7)); reply(.success(9))
        }
        require(success == 7, "Only the first capture callback may win")
        let late = Mutex<(@Sendable (Result<Int, any Error>) -> Void)?>(nil)
        do {
            let _: Int = try await CallbackDeadline.perform(timeout: .milliseconds(25)) { reply in late.withLock { $0 = reply } }
            fatalError("Hung capture did not time out")
        } catch is CallbackDeadline.Timeout {}
        late.withLock { $0 }?(.success(99))
        let started = Mutex(false)
        let neverStarted = Task {
            let _: Int = try await CallbackDeadline.perform(timeout: .seconds(1)) { reply in
                started.withLock { $0 = true }; reply(.success(1))
            }
        }
        neverStarted.cancel()
        do { try await neverStarted.value; fatalError("Pre-canceled capture succeeded") } catch is CancellationError {}
        require(!started.withLock { $0 }, "A pre-canceled capture must not invoke the framework")
        let replyBox = Mutex<(@Sendable (Result<Int, any Error>) -> Void)?>(nil)
        let inFlight = Task {
            let _: Int = try await CallbackDeadline.perform(timeout: .seconds(1)) { reply in replyBox.withLock { $0 = reply } }
        }
        try await Task.sleep(for: .milliseconds(25)); inFlight.cancel()
        do { try await inFlight.value; fatalError("Canceled capture succeeded") } catch is CancellationError {}
        replyBox.withLock { $0 }?(.success(10))
    }

    @MainActor static func main() async throws {
        let stale = AccessibilityAccess.Snapshot(reportedTrusted: false, verifiedWindowAccess: true, probeError: .success, keyboardEvents: false)
        require(stale.windowAccess && !stale.keyboardEvents, "A successful real window read must overcome a stale trust flag without authorizing keyboard events")
        let denied = AccessibilityAccess.Snapshot(reportedTrusted: true, verifiedWindowAccess: false, probeError: .apiDisabled, keyboardEvents: true)
        require(!denied.windowAccess && denied.keyboardEvents, "A denied real read must override an outdated grant without disabling separately authorized keyboard commands")
        let unknown = AccessibilityAccess.Snapshot(reportedTrusted: false, verifiedWindowAccess: false, probeError: .cannotComplete, keyboardEvents: false)
        require(!unknown.windowAccess && unknown.diagnostic.contains("response"), "Unresponsive apps must not be mislabeled as permission denial or allowed")
        let displayBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let activeWindow = CGRect(x: 200, y: 180, width: 800, height: 500)
        let shades = FocusDimmingGeometry.paths(bounds: displayBounds, window: activeWindow)
        require(shades.count == 11, "Backdrop must use one exterior and ten contiguous feather rings")
        require(shades.allSatisfy { !$0.contains(CGPoint(x: 600, y: 400), using: .evenOdd) }, "The active window must stay completely clear")
        require(shades[0].contains(CGPoint(x: 30, y: 30), using: .evenOdd), "The exterior must dim the rest of the display")
        let featherPoint = CGPoint(x: activeWindow.maxX + 7.3, y: activeWindow.midY)
        require(shades.dropFirst().filter { $0.contains(featherPoint, using: .evenOdd) }.count == 1, "Feather rings must not overlap and create dark seams")
        let secondary = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        require(FocusDimmingGeometry.localWindow(CGRect(x: -1200, y: -80, width: 400, height: 300), in: secondary) == CGRect(x: 240, y: 120, width: 400, height: 300), "Backdrop coordinates must support negative display origins")
        let spanning = FocusDimmingGeometry.paths(bounds: displayBounds, window: CGRect(x: -300, y: 100, width: 900, height: 500))
        require(spanning.allSatisfy { !$0.contains(CGPoint(x: 100, y: 300), using: .evenOdd) }, "A partially offscreen active window must not be dimmed")
        require(FocusDimmingGeometry.ringAlpha(0) < 0.01 && FocusDimmingGeometry.ringAlpha(9) > 0.99, "Feather edges must blend smoothly into the exterior")
        let backdrop = FocusBackdropView(frame: displayBounds)
        backdrop.update(window: activeWindow, animated: false, reduceMotion: true)
        backdrop.layoutSubtreeIfNeeded()
        backdrop.layer?.opacity = 0.55
        let bitmap = CGContext(data: nil, width: 1440, height: 900, bitsPerComponent: 8, bytesPerRow: 1440 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        backdrop.layer!.render(in: bitmap)
        let bytes = bitmap.data!.assumingMemoryBound(to: UInt8.self)
        func alpha(_ x: Int, _ y: Int) -> Int { Int(bytes[(y * 1440 + x) * 4 + 3]) }
        require(alpha(600, 400) == 0, "Rendered active window must remain completely transparent")
        require((130...150).contains(alpha(30, 30)), "Rendered exterior must use the selected 55 percent dimming")
        let near = alpha(1002, 400), middle = alpha(1007, 400), far = alpha(1012, 400)
        require(near < middle && middle < far && far < alpha(1030, 400), "Rendered feather must brighten continuously toward the active window without dark seams")
        try await commandChecks()
        try await callbackChecks()
        var focus = FocusChangeTracker()
        require(focus.observe(nil) == nil, "Unknown Focus must not announce off")
        require(focus.observe(false) == nil, "Initial status must establish a baseline")
        require(focus.observe(false) == nil, "Unchanged Focus must not repeat notifications")
        require(focus.observe(true) == true, "Focus activation must announce")
        require(focus.observe(true) == nil, "Active Focus must not repeat")
        require(focus.observe(false) == false, "Focus deactivation must announce")
        require(focus.observe(nil) == nil, "Revoked sharing must never fabricate a Focus change")
        require(focus.observe(true) == nil, "Restored sharing must establish a fresh baseline")
        focus.reset()
        require(focus.observe(false) == nil, "Disabling and enabling monitoring must reset the baseline")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bezel-Shelf-Test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.png")
        let fixture = png()
        try fixture.write(to: original)
        let images = ShelfImageStore(directory: root.appendingPathComponent("owned", isDirectory: true))
        let a = try await images.createImage(fixture)
        let b = try await images.createImage(fixture)
        require(a != b && FileManager.default.fileExists(atPath: a.path), "Each capture needs its own exportable file")
        let decoded = CGImageSourceCreateWithURL(a as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as! [CFString: Any]
        require(properties[kCGImagePropertyPixelWidth] as? Int == 200, "Captures must keep their full resolution")
        require(properties[kCGImagePropertyPixelHeight] as? Int == 100, "Captures must keep aspect ratio")
        await images.remove(original)
        require(FileManager.default.fileExists(atPath: original.path), "Shelf must never delete an original file")
        await images.remove(a)
        require(!FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path), "Removing one capture must preserve the others")
        do { _ = try await images.createImage(Data("not an image".utf8)); fatalError("Invalid image accepted") } catch {}
        let constrained = ShelfImageStore(directory: root.appendingPathComponent("limited"), budget: 1)
        do { _ = try await constrained.createImage(fixture); fatalError("Image storage budget ignored") } catch {}
        require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("limited").path), "Rejected images must not create files")
        let canceled = Task { () throws -> URL in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await images.createImage(fixture)
        }
        canceled.cancel()
        do { _ = try await canceled.value; fatalError("Canceled capture accepted") } catch is CancellationError {}
        await images.clear()
        require(!FileManager.default.fileExists(atPath: b.path) && FileManager.default.fileExists(atPath: original.path), "Clear must release owned captures and preserve originals")
        _ = try await images.createImage(fixture)
        await images.clear()
        require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("owned").path), "Session cleanup must remove its private directory")

        let display = CGRect(x: -1440, y: -200, width: 1440, height: 860)
        let placed = ShelfPlacement.constrained(CGRect(x: 1500, y: -400, width: 380, height: 400), to: display)
        require(display.contains(placed), "A remembered drawer must stay on a secondary display with a negative origin")
        let oversized = ShelfPlacement.constrained(CGRect(x: -5000, y: 4000, width: 2000, height: 1000), to: display)
        require(display.contains(oversized), "Drawer dimensions must fit a disconnected or smaller display")
        print("Interface checks passed: Focus transitions and privacy baselines, full-resolution Shelf captures, owned-file cleanup, image storage limits, cancellation, multi-display placement, clipboard modifier/focus/permission/cancellation handling, capture callback timeouts/late replies, and rendered Monolith feathering, clear active windows, and display coordinates.")
    }
}
