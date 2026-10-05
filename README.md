# Bezel

A native Swift 6 macOS utility with a SwiftUI dashboard, menu bar popover, and AppKit overlays. Built with the installed Xcode 27 macOS SDK; deployment target macOS 15 or newer. The existing Xcode scheme is **MyApp**, and its application product is **Bezel.app**.

## Build and run

Open `Untitled Project.xcodeproj`, select **MyApp → My Mac**, and run. Debug builds support local ad-hoc signing. For the optimized universal Apple silicon/Intel archive, run:

```sh
./Scripts/build-release.sh
```

The application is at `Build/Bezel.xcarchive/Products/Applications/Bezel.app`. This is a local, ad-hoc-signed development archive; distribution requires your Developer ID identity and notarization. No third-party runtime dependencies or downloaded audio drivers are used.

Bezel remains running when its dashboard closes. The menu bar popover opens the dashboard, Stack HUD, and Shelf and exposes quick focus/awake controls. Quit through the menu bar or application menu to restore power assertions and finish tearing down audio routes.

## Implemented capabilities and platform boundaries

| Module | Working behavior | Requirements and limits |
| --- | --- | --- |
| Stack | Clipboard polling; original per-item representations for text, RTF, PNG/TIFF, file URLs, and arbitrary data; metadata and source icons; searchable 50-item history/HUD; FIFO copy/paste sequence; ImageIO downsampled previews and clear/remove actions | Memory-only, 64 MB payload budget, 24 MB per item. Concealed/transient/generated pasteboard types are skipped. Unmarked sensitive data can still enter history. Copy/paste synthesis requires Accessibility. |
| AirBridge | HAL output/process discovery; independent process taps; private aggregate playback to one or two devices; per-route gain; real dBFS meters; format/disconnect watchdog and sleep cleanup | System audio recording permission. Native float32 PCM only. A second target mirrors stereo; routing latency and Bluetooth clock behavior need physical acceptance tests. Protected audio may not be capturable. |
| Aperture | Hardware-derived notch width/center/safe-area height; optional external-display capsule; scrolling clipboard text/thumbnails, 1.2-second dismissal, focus timer, real seven-band stereo FFT spectrum, file drop into Shelf; optional Music/Spotify track details, circular artwork and player-specific controls | Track connections require Automation access and a running player. Metadata and Spotify artwork downloads are off by default. Music artwork is local; Spotify covers use its image CDN. Other routed apps show app names and real levels, with system media-key controls. Universal metadata and live player acceptance remain incomplete. |
| Grid | Accessibility-based halves, thirds, quarters, full-screen-area fill, and custom cells; persisted spacing; multi-display coordinates; global half-screen shortcuts; separate menu-collapse chevron and icon shelf | Accessibility. Apps can enforce minimum sizes. On macOS 27, selected third-party menu icons use a runtime-checked private menu visibility interface; older systems use a status-item divider. The shelf invokes original menu icons through AX after revealing them. This does not reparent another app’s status item. |
| Scope | Concurrent allocated-size scanning including hidden files; interactive three-ring sunburst, list, drill/reveal; read-only archive inspector; native libarchive extraction; ZIP compression; embedded Finder context-menu extension | Scan detail is capped at 20,000 entries, six levels, and 80 largest children per folder. Inspector enumeration stops at 20,000 headers or before advancing past 512 MB of declared data, and marks partial listings. APFS shared extents/hard links prevent treating allocation totals as uniquely occupied blocks. Protected directories require OS access. |
| Monolith | Timed focus session; reusable click-through 90%-black panels outside the focused window; timer feeds Aperture; optional serialized starting/ending Focus shortcuts | Accessibility. Dimming is visual, not a change to other apps’ window alpha. Configure two native Set Focus shortcuts for automatic Do Not Disturb. Workflows run on start/end/expiry/normal quit; failed ending workflows retain a recovery action. They turn off the chosen Focus rather than restoring a previously active Focus. |
| Shelf | Multi-file/text tray, cross-Space floating panel, 80-point slide, edge drag detection, native drag/drop, outbound item providers, reveal/copy/remove | Up to 50 items; text limited to 1 MB each. Holds references to files; removing items never removes originals. |
| Lens | Pointer-display ScreenCaptureKit screenshot; frozen-frame region selector; offline Vision recognition; spatial line formatting; clipboard and Stack insertion; cancel/retry | Screen Recording. Protected/DRM surfaces may be blank and cannot be bypassed. Recognition quality depends on the selected pixels. |
| Tether | Real IOKit battery monitoring plus an isolated native controller for an 80% limit, temporary top-off to 100%, and limit removal | Experimental runtime-bound PowerUI interface, restricted to compatible Apple silicon Macs on macOS 26.4+. The bundled helper validates method signatures and accepts four fixed actions; no root access or SMC writes. This Mac’s read-only capability check passes. Write/top-off/charging behavior still needs acceptance testing. macOS may occasionally charge to 100% for calibration, so this is not an absolute electronic 80% ceiling. |
| Pulse | System/display/disk idle power assertions; continuous/countdown/PID observer modes; exact PID-start identity; CPU idle debounce; assertion release | Does not override lid-close, explicit Sleep, or critical-battery sleep. Process mode watches the chosen workload PID and ends on exit or <0.1% CPU for 30 seconds. Disk assertion is optional. |
| Border | One-physical-pixel accent outline; focused AX window tracking across displays/Spaces; click-through panel; accent-change redraw | Accessibility. Windows that do not expose AX geometry cannot be outlined. |

This is a working release candidate, **not a claim that all eleven requested behaviors are production-certified**. The restricted capabilities in the table are visible in the interface. Physical audio routing, notch/drag behavior across display configurations, permission-dependent capture/window control, and distribution acceptance still need the release checks in `Documentation/Release.md`.

## Permissions and Finder

Use **Settings → Privacy** or the setup button for Accessibility and Screen Recording. AirBridge requests system audio access when a user explicitly starts a route. The app never requests elevated permissions at launch. Login registration is opt-in through `SMAppService`.

In **Aperture → Now Playing**, Connect explicitly requests Automation access for a running Apple Music or Spotify app. Disconnect stops that connection in Bezel; macOS retains its permission until you revoke it in Privacy & Security → Automation. Track polling runs every two seconds only while Aperture, metadata and a connection are enabled. It does not launch players. Controls target the selected connected player; the audio route determines which player's artwork may appear. Spotify cover downloads require a separate opt-in and accept only HTTPS responses from `i.scdn.co`, with a four-megabyte input limit and a downsampled preview. Music artwork is read through its local scripting interface. Bezel has no account or cloud sync.

Scope’s **Enable Finder Extension…** opens macOS extension management. Enable **Bezel Finder Actions** yourself. The embedded sandboxed FinderSync extension offers Analyze, Inspect Archive, Compress, and Extract actions and sends validated `bezel://scope` requests to the host app. Inspection reads headers without creating files and flags unsafe paths/links. Compression/extraction still asks for a destination and refuses overwrites. The extension does not walk folders or alter Finder badges. It supports a single selected item.

Monolith’s notification automation uses the system `shortcuts` executable with direct arguments, bounded output, timeout, and cancellation. Create the two Set Focus workflows described in the module before enabling it. Bezel reports workflow execution; it cannot independently prove that an arbitrary user-selected workflow changed Focus. Menu collapse and native charge controls use private interfaces and need release-specific acceptance tests; they fail with a visible error when the installed interface differs.

## Architecture

- `MyApp/Core/`: shared observable model, permission center, Carbon shortcut lifecycle, validated Finder request parser.
- `MyApp/Design/`: native sidebar/dashboard, menu popover, reusable cards, Settings and setup.
- `MyApp/Modules/Stack/`: main-actor pasteboard/UI bridge and actor-owned raw payload store.
- `MyApp/Modules/AirBridge/`: HAL bindings, serial route actor, allocation-free realtime renderer with atomic gain/meter state, opt-in actor-owned player metadata through native ScriptingBridge, and UI.
- `MyApp/Modules/Aperture/`: nonactivating panel, hardware geometry, transient/persistent state arbitration, SwiftUI spring transitions and drop zone.
- `MyApp/Utilities/`: distinct Grid, Scope, Monolith, Shelf, Lens, Tether, Pulse, Border, and menu shelf services.
- `BezelFinder/`: embedded FinderSync extension target.
- `MyApp/Utilities/Tether/ChargeAgent/`: separate bundled executable target with a narrow runtime-checked battery interface.

Passive clipboard polling checks `changeCount` every 450 ms with tolerance; audio discovery runs on an actor every 1.5 seconds; battery refreshes every 30 seconds with tolerance. Window tracking exists only while a feature is enabled. Aperture synchronization uses Observation rather than a continuous timer. Its text timeline runs only while overflowing text is visible. Image previews downsample during decode. Audio callbacks allocate no memory and take no locks; stereo FFT workspaces are preallocated and run at most twenty analysis pairs per second per route. Focus reuses overlay windows. Storage scanning limits worker concurrency to six and bounds detail. Shutdown waits for Focus cleanup, requested battery writes, and audio teardown before replying to macOS.

Focus and anti-sleep countdowns use a shared `ContinuousClock` calculation. Calendar/network-clock changes do not alter the requested session duration, and elapsed time during sleep is reflected on wake. Pulse's expiry regression inspects the test process's actual IOKit assertions before and after expiry and restart.

## Reproducible verification

```sh
./Scripts/test-all.sh
# Headless renderer checks without live CoreAudio discovery:
./Scripts/test-airbridge.sh --skip-hardware
```

The scripts compile actual production sources in Swift 6 optimized mode, then check clipboard bounds/FIFO/stale consumers/retention, realtime channel mapping and FFT frequency response, archive inspection and tar.gz/RAR5/7z extraction, ZIP round trips and attack fixtures, validated Finder URLs, storage/inspection cancellation, and power assertion lifecycle. Automation checks exercise literal process arguments, both output streams, inherited-pipe deadlines/cancellation, forced termination, output bounds, Focus races and recovery, menu visibility policy, and serialized charge requests using injected workflows. Media checks cover typed/bounded replies, route/player matching, player-specific controls, opt-in polling, stale results/consent cancellation, and artwork decode/HTTP/byte limits and request cancellation using a local URLProtocol fixture. They do not access players or the network. Native probes only read compatibility and charge state; they do not change charge settings, invoke user shortcuts, request privacy access, hide icons, or create audio taps. See `Tests/AirBridge/README.md` for audio acceptance cases.

## Apple API references

[Core Audio process taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps), [NSScreen notch safe areas](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea), [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit), and [FinderSync](https://developer.apple.com/documentation/findersync) provide the public framework foundations. Installed SDK headers are authoritative for the exact APIs compiled by this project.

[ScriptingBridge](https://developer.apple.com/documentation/scriptingbridge/sbapplication) provides native access to the installed Music/Spotify scripting dictionaries. The [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events) permits a hardened app to request Automation access; the user still grants each player's permission. Background queries use nonprompting [Automation permission preflight](https://developer.apple.com/documentation/coreservices/3025784-aedeterminepermissiontoautomatet).

Apple documents [running Shortcuts from the command line](https://support.apple.com/en-au/guide/shortcuts-mac/apd455c82f02/mac) and [native Charge Limit behavior](https://support.apple.com/en-us/102338). The private menu interface was investigated against the [Hidden Bar implementation](https://github.com/dwarvesf/hidden/tree/develop/hidden/Features/StatusBar/Engine/Native); charge-client selectors were investigated against [battery’s macOS 27 work](https://github.com/actuallymentor/battery/pull/480) and validated read-only against this Mac’s runtime. These community interfaces are not Apple-supported SDK contracts.
