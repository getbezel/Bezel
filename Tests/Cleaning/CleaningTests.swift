import Foundation
import CoreGraphics

@main struct CleaningTests {
    static func activationChecks() {
        let shield = CleaningInputShield()
        let enabling = DispatchSemaphore(value: 0)
        let releaseEnable = DispatchSemaphore(value: 0)
        let activated = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            precondition(shield.activate(duration: 60) {
                enabling.signal()
                precondition(releaseEnable.wait(timeout: .now() + 5) == .success)
                return true
            })
            activated.signal()
        }
        precondition(enabling.wait(timeout: .now() + 5) == .success)
        let inspecting = DispatchSemaphore(value: 0)
        let inspected = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            inspecting.signal()
            precondition(shield.snapshot().active, "Worker may see active only after filter enabling completes")
            inspected.signal()
        }
        precondition(inspecting.wait(timeout: .now() + 5) == .success)
        precondition(inspected.wait(timeout: .now() + 0.05) == .timedOut,
                     "Worker must not observe a half-armed session while enabling is in progress")
        releaseEnable.signal()
        precondition(activated.wait(timeout: .now() + 5) == .success)
        precondition(inspected.wait(timeout: .now() + 5) == .success)
        shield.stop()
        precondition(!shield.snapshot().active)
        precondition(!shield.activate(duration: 60) { fatalError("Stopped shields must never reenable input filtering") })

        let denied = CleaningInputShield()
        precondition(!denied.activate(duration: 60) { false })
        precondition(!denied.snapshot().active, "Failed filter enabling must not publish an active cleaning session")
        denied.stop()
    }

    static func main() {
        activationChecks()
        var session = CleaningSession(now: 100, duration: 180)
        precondition(session.remaining(now: 100) == 180 && session.exit(now: 100) == nil)
        session.escapeDown(now: 101, repeated: false)
        session.escapeDown(now: 101.3, repeated: true)
        precondition(session.progress(now: 102) == 0.5, "Auto-repeat must not reset the held-key clock")
        precondition(session.exit(now: 102.99) == nil, "A short accidental press must not exit")
        precondition(session.exit(now: 103) == .escape, "A continuous two-second Escape hold exits")
        session.escapeUp()
        precondition(session.progress(now: 104) == 0 && session.exit(now: 104) == nil, "Releasing Escape resets progress")
        session.escapeDown(now: 105, repeated: true)
        precondition(session.progress(now: 110) == 0, "A key held before mode started cannot arm through repeat alone")
        session.escapeDown(now: 111, repeated: false)
        precondition(session.progress(now: 111.5) == 0.25)
        session.escapeUp(); session.escapeDown(now: 112, repeated: false)
        precondition(session.exit(now: 113.5) == nil, "Separate short presses cannot accumulate")
        precondition(session.exit(now: 114) == .escape)
        session.escapeUp()
        precondition(session.exit(now: 280) == .timeout && session.remaining(now: 999) == 0, "The automatic deadline is a hard stop")
        let capped = CleaningSession(now: 10, duration: 100000)
        precondition(capped.exit(now: 310) == .timeout, "A corrupted long duration cannot create an indefinite lock")
        let short = CleaningSession(now: 10, duration: -1)
        precondition(short.remaining(now: 10) == 30)
        precondition(session.progress(now: 50) == 0, "Progress remains bounded")
        if ProcessInfo.processInfo.environment["BEZEL_CLEANING_NATIVE_PROBE"] == "1" {
            // Prepare only: never arm the filter, show a black panel or post a key.
            for _ in 0..<10 {
                let shield = CleaningInputShield()
                do {
                    try shield.prepare()
                    precondition(!shield.snapshot().active, "Preparing the worker must not block user input")
                    var count: UInt32 = 0
                    precondition(CGGetEventTapList(0, nil, &count) == .success)
                    var taps = [CGEventTapInformation](repeating: .init(), count: Int(count))
                    var returned: UInt32 = 0
                    let result = taps.withUnsafeMutableBufferPointer { CGGetEventTapList(count, $0.baseAddress, &returned) }
                    precondition(result == .success)
                    precondition(taps.prefix(Int(min(returned, count))).contains {
                        $0.tappingProcess == ProcessInfo.processInfo.processIdentifier &&
                        $0.options == .defaultTap && !$0.enabled &&
                        $0.eventsOfInterest & (1 << CGEventType.keyDown.rawValue) != 0
                    }, "The prepared input filter must remain disabled")
                    // Simulates a busy UI thread while the private run loop stays alive.
                    Thread.sleep(forTimeInterval: 0.1)
                    precondition(!shield.snapshot().active)
                    shield.stop(); shield.stop()
                } catch {
                    fatalError("Native disabled-filter probe failed: \(error)")
                }
            }
            print("Native cleaning worker checks passed: 10 prepare/stop cycles, verified disabled keyboard filters, busy caller and idempotent shutdown; no input blocked.")
        }
        print("Cleaning checks passed: atomic filter activation, failed activation and stopped-shield rejection, held Escape, autorepeat, early release, repeated taps, pre-held keys, timeout, bounded duration and progress.")
    }
}
