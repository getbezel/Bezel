# Cleaning mode

Open **Cleaning** in the System sidebar, or use Tools → Start Cleaning Mode. All connected displays receive opaque black panels. A temporary CoreGraphics session event filter suppresses ordinary keyboard input, mouse buttons, motion, dragging and scrolling. Power, Touch ID and hardware/system controls remain managed by macOS.

Hold **Escape continuously for two seconds** to exit; a progress ring shows the hold. Releasing Escape resets the hold. **Command–Option–Escape** immediately removes the shield and passes through to macOS Force Quit. The selected **1, 2, 3 or 5 minute** deadline is automatic, defaults to 3 minutes, and is based on monotonic uptime.

The mode starts only after explicit user action. It requires Accessibility access, confirms that macOS actually allowed key-down and key-up filtering, and refuses to start while Secure Keyboard Entry is active. It stops and releases input if the tap is disabled, Secure Keyboard Entry becomes active, displays sleep, the Mac sleeps, the system session resigns, or Bezel quits. Losing all displays also stops it. Connecting/disconnecting displays rebuilds the panels. The cursor is hidden/restored with balanced calls.

Cleanup disables and invalidates the event tap before removing panels and observers. If the process exits or crashes, macOS removes its windows and event tap; there is no persistent OS keyboard-disable setting or launch-time rearming. No keystroke contents, pointer locations or clipboard data are recorded.

`Scripts/test-cleaning.sh` tests the production escape/deadline policy: hold timing, autorepeat, releases, repeated short presses, pre-held keys, bounded durations and hard timeout. The Release archive compiles the actual event tap, overlays and lifecycle cleanup. Tests do not activate the input shield on the user's desktop; physical keyboard and multi-display interaction require user acceptance.

## October 21 startup repair

The user reported black covers appearing and immediately exiting. The former
input filter ran on the main UI run loop, which also built and rendered every
SwiftUI cover after the tap was enabled. A slow UI operation could therefore
stall the event callback and trigger macOS's automatic tap-disable behavior.

`CleaningInputShield` now owns a dedicated user-interactive thread and run loop.
It is prepared disabled, the covers are created, then input blocking is armed.
Its callback performs only bounded state updates under a lock; no SwiftUI or
AppKit work runs inside it. Escape hold, automatic expiry, Secure Keyboard Entry
and Force Quit release the filter on the worker independently of UI rendering.
The UI polls a content-free snapshot. Stop invalidates the filter first and is
idempotent. A finite run interval handles startup/shutdown races. Failure text
remains visible in the Cleaning page after its alert is dismissed, with recovery
links to Accessibility and Input Monitoring settings.

`BEZEL_CLEANING_NATIVE_PROBE=1 bash Scripts/test-cleaning.sh` passed ten native
prepare/stop cycles, verified each keyboard filter remained disabled during the
probe, and exercised repeated shutdown while the caller was briefly busy. No
black panels, synthetic key posts or active input suppression were used in the
probe. Escape timing/expiry policy tests also passed. This establishes the new
worker's setup/teardown, not physical keyboard interaction or confirmation that
the reported live issue is resolved on every recipient Mac.
