# Bezel

A native Swift 6 macOS utility with a SwiftUI dashboard, menu bar popover, and AppKit overlays. Built with the installed Xcode 27 macOS SDK; deployment target macOS 15 or newer. The existing Xcode scheme is **Untitled Project**, and its application product is **Bezel.app**.

## Project status

Early-access source repository. See [the pre-upload audit](Documentation/GitHubAudit.md) for checks, fixes, and remaining release limitations. Build success does not certify every hardware configuration.

Signing and Google OAuth configuration are supplied locally and are not included in the repository. Google sign-in is optional and requires your own OAuth client configuration. Certificates, private keys, user sessions, caches, and app/DMG build products are excluded from Git.

Original Bezel contributions are proprietary; see [NOTICE](NOTICE) and [third-party notices](Untitled%20Project/Legal/ThirdPartyNotices.txt). DragWheel redistribution permission remains unresolved. No public binary release is included with this repository.

## Build and run

Use Xcode 27 and Node.js 22 or newer for the verified build/test setup. Open `Untitled Project.xcodeproj`, select **Untitled Project → My Mac**, copy `Configuration/Local.xcconfig.example` to `Configuration/Local.xcconfig`, enter your signing team, and run. The local configuration is Git-ignored. Google sign-in remains unavailable until you configure your own native OAuth client ID and callback scheme. For the optimized universal Apple silicon/Intel archive, run:

```sh
./Scripts/build-release.sh
```

The application is at `Build/Bezel-Signed.xcarchive/Products/Applications/Bezel.app`. This is an Apple Development-signed archive; distribution requires your Developer ID identity and notarization. Core utilities use system frameworks without downloaded audio drivers. DragWheel detects optional installed conversion tools for additional formats.

To package the local archive as a drag-to-Applications disk image:

```sh
./Scripts/package-release.sh --development
```

This creates `Build/Bezel-Development.dmg` and its SHA-256 sidecar. It does not install or launch the app, contact Apple, or change battery settings. Development packages are explicitly unnotarized.

For distribution, set `BEZEL_SIGNING_IDENTITY` to your full Developer ID Application certificate name, `BEZEL_DEVELOPMENT_TEAM` to its ten-character team identifier, and `BEZEL_NOTARY_PROFILE` to an existing `notarytool` Keychain profile. Run `build-release.sh` followed by `package-release.sh` without `--development`. The scripts build with manual Developer ID signing and secure timestamps, validate both architectures of every embedded executable against that team, sign the disk image, submit it to Apple, staple and validate the accepted ticket, and assess Gatekeeper before replacing `Build/Bezel.dmg`. Credentials are read from the named Keychain profile rather than embedded in source. This distribution path requires your credentials and has not been exercised here. See `Documentation/Release.md`.

Bezel remains running when its dashboard closes. The menu bar popover opens the dashboard, Stack HUD, and Shelf and exposes quick focus/awake controls. Quit through the menu bar or application menu to restore power assertions and finish tearing down audio routes.

## Implemented capabilities and platform boundaries

**DragWheel is part of Bezel.** Hold **Shift while dragging a file** to open its
conversion wheel. Release over an output format to convert, or the center to
cancel. Open **Capture & Collect → DragWheel** for a keyboard-accessible file
picker, format selection, trigger settings, conversion results, and helper-tool
status. New files save beside their originals; existing names receive numeric
suffixes. Bezel's existing menu bar includes **Convert Files…**. No standalone
DragWheel app, menu bar item, login service, or target is created.

Native conversions cover images, PDFs, documents, CSV/TSV, subtitles, folders and
archives. Audio/video uses installed FFmpeg (native audio fallback is available);
EPUB and enhanced Markdown use Pandoc, WebP/AVIF output may use ImageMagick or
FFmpeg, and presentations/office spreadsheets use LibreOffice. Missing helpers
are shown in the page and unavailable wheel choices are disabled. Nothing is
installed automatically. See `Documentation/DragWheel.md`.

| Module | Working behavior | Requirements and limits |
| --- | --- | --- |
| Stack | Clipboard polling; original per-item representations for text, RTF, PNG/TIFF, file URLs, and arbitrary data; metadata and source icons; searchable 50-item history/HUD; Quick Clips copy/paste picker; ImageIO downsampled previews; multi-selection, Delete Selected, and Delete All | Memory-only, 64 MB payload budget, 24 MB per item. Concealed/transient/generated pasteboard types are skipped. Unmarked sensitive data can still enter history. Copy/paste synthesis requires macOS keyboard-event authorization for this running build. Commands wait for shortcut modifiers to be released, restore the captured app/input focus, and deliver a private Command-C/V key pair to that exact process. |
| AirBridge | HAL output/process discovery; independent process taps; private aggregate playback to one or two devices; per-route gain; real dBFS meters; format/disconnect watchdog and sleep cleanup | System audio recording permission. Native float32 PCM only. A second target mirrors stereo; routing latency and Bluetooth clock behavior need physical acceptance tests. Protected audio may not be capturable. |
| Aperture | Hardware-derived notch width/center/safe-area height; optional external-display capsule; scrolling clipboard text/thumbnails, configurable 2.8-second moments, hover-to-hold, smooth opening and closing, shared Focus status changes, focus timer, real seven-band stereo FFT spectrum, file drop into Shelf; Music/Spotify track details and artwork; click-to-expand player with previous/next, play/pause, source volume and paused-track retention | Focus changes require Focus status authorization and macOS sharing. Unshared status is unknown, never treated as off. The public API supplies notification-silencing status, not a specific Focus name. Track connections require Automation access and a running player. Metadata and Spotify artwork downloads are off by default. Music artwork is local; Spotify covers use its image CDN. Other routed apps show app names and real levels, with system media-key controls. Universal metadata and live player acceptance remain incomplete. |
| Grid | Accessibility-based halves, thirds, quarters, full-screen-area fill, and custom cells; persisted spacing; multi-display coordinates; global half-screen shortcuts; separate menu-collapse chevron and icon shelf | Accessibility. Apps can enforce minimum sizes. On macOS 27, selected third-party menu icons use a runtime-checked private menu visibility interface; older systems use a status-item divider. The shelf invokes original menu icons through AX after revealing them. This does not reparent another app’s status item. |
| Scope | Concurrent allocated-size scanning including hidden files; interactive three-ring sunburst, list, drill/reveal; read-only archive inspector; native libarchive extraction; ZIP compression; embedded Finder context-menu extension | Scan detail is capped at 20,000 entries, six levels, and 80 largest children per folder. Inspector enumeration stops at 20,000 headers or before advancing past 512 MB of declared data, and marks partial listings. APFS shared extents/hard links prevent treating allocation totals as uniquely occupied blocks. Protected directories require OS access. |
| Monolith | Timed focus session; one click-through backdrop per display with a feathered active-window opening, adjustable 20–85% dimming (55% default), eased focus transitions, AX/drag event tracking and a four-Hz fallback; timer feeds Aperture; optional serialized starting/ending Focus shortcuts | Accessibility. Dimming is visual, not a change to other apps’ window alpha. Configure two native Set Focus shortcuts for automatic Do Not Disturb. Workflows run on start/end/expiry/normal quit; failed ending workflows retain a recovery action. They turn off the chosen Focus rather than restoring a previously active Focus. |
| Shelf | File/image/text tray, cross-Space floating panel, remembered position and size, header drag handle and resize grip, image thumbnails and native Quick Look, Add Clipboard and region capture, native drag/drop, outbound item providers, reveal/copy/remove | Up to 50 items; text limited to 1 MB each. Images are normalized to full-resolution temporary PNGs, limited to 32 MB/32 megapixels per input and 128 MB stored. Clear/quit removes captures; export them first. Original files remain unchanged. |
| Lens | Pointer-display ScreenCaptureKit screenshot; frozen-frame region selector; offline Vision recognition; spatial line formatting; clipboard and Stack insertion; cancel/retry; bounded, scrollable dashboard layout and a shared image capture mode for Shelf | Screen Recording. Protected/DRM surfaces may be blank and cannot be bypassed. Recognition quality depends on the selected pixels. |
| Tether | Real IOKit battery monitoring plus an isolated native controller for an 80% limit, temporary top-off to 100%, and limit removal | Experimental runtime-bound PowerUI interface, restricted to compatible Apple silicon Macs on macOS 26.4+. The bundled helper validates method signatures and accepts four fixed actions; no root access or SMC writes. This Mac’s read-only capability check passes. Write/top-off/charging behavior still needs acceptance testing. macOS may occasionally charge to 100% for calibration, so this is not an absolute electronic 80% ceiling. |
| Pulse | System/display/disk idle power assertions; continuous/countdown/PID observer modes; exact PID-start identity; CPU idle debounce; assertion release | Does not override lid-close, explicit Sleep, or critical-battery sleep. Process mode watches the chosen workload PID and ends on exit or <0.1% CPU for 30 seconds. Disk assertion is optional. |
| Border | One-physical-pixel accent outline; focused AX window tracking across displays/Spaces; click-through panel; accent-change redraw | Accessibility. Windows that do not expose AX geometry cannot be outlined. |

This is a working release candidate, **not a claim that all eleven requested behaviors are production-certified**. The restricted capabilities in the table are visible in the interface. Physical audio routing, notch/drag behavior across display configurations, permission-dependent capture/window control, and distribution acceptance still need the release checks in `Documentation/Release.md`.

## Daily use

- **Quick Clips:** ⇧⌘C copies the selection in your active app, saves it to Quick Clips, and opens the pointer-anchored HUD. ⇧⌘V opens a picker; click a clip to paste immediately into the original app/text field, or press Return for the highlighted clip. Clicking a clip in copy mode copies it to the system clipboard. Pasting a Quick Clip consumes only that selected queue occurrence and keeps its history. The History tab also offers pasting without consuming a Quick Clip. Without keyboard-event authorization, use Add Clipboard and Copy, then paste manually.
- **History:** Select enables checkboxes; Select All selects the current filtered results. Delete Selected or the Delete key removes the selection. Delete All confirms clearing both history and Quick Clips while preserving the system clipboard.
- **Aperture:** opening uses a gentle spring; closing eases over 0.34 seconds inside a fixed native canvas. Moments stay for 2.8 seconds by default, configurable from 1.6–6 seconds. Hover holds a moment; leaving starts a fresh display interval. Reduce Motion removes movement. In Aperture → Focus Status, use Allow Focus Status and enable macOS Share Focus Status for the Focus you use. Bezel reports denied, restricted, or unshared status instead of inventing an event.
- **Shelf:** drag the header to move it and the bottom-right grip to resize; Size offers three presets and the dashboard exposes width/height controls. Position and size persist. Add Clipboard imports files, images, or text. Capture Image reuses Lens's frozen-frame selection and adds a full-resolution PNG to Shelf. The eye button opens a native Quick Look preview. Drag the captured file into Finder or another app before clearing Shelf or quitting Bezel.

## Permissions and Finder

Use **Settings → Privacy** or the setup button for Accessibility and Screen Recording. Setup and Lens show the actual running app path and whether it was rebuilt while running. If the Settings toggle is enabled but access is still blocked, use Show This App in Finder, remove the stale Bezel permission entry, add that exact app again, then quit Bezel from its menu bar and reopen the same build without rebuilding. Closing the dashboard does not quit it. The earlier local signatures could invalidate permissions on each rebuild. After the owner added their Xcode account, Xcode created an Apple Development certificate and the project now uses that team for all three targets. The updated signed app is `Build/Bezel-Signed.xcarchive/Products/Applications/Bezel.app`. macOS needs a fresh grant when moving from the earlier ad-hoc identity to this signed identity. No privacy database was edited. AirBridge requests system audio access when a user explicitly starts a route. The app never requests elevated permissions at launch. An explicit Lens capture goes through ScreenCaptureKit even when the older CoreGraphics permission preflight is stale; real framework denial is reported beside the Capture button. Content discovery and screenshot callbacks have 15/10-second deadlines and reject late replies after cancellation. This does not bypass macOS authorization. Login registration is opt-in through `SMAppService`.

In **Aperture → Now Playing**, Connect explicitly requests Automation access for a running Apple Music or Spotify app. Disconnect stops that connection in Bezel; macOS retains its permission until you revoke it in Privacy & Security → Automation. Track polling runs every two seconds only while Aperture, metadata and a connection are enabled. It does not launch players. Controls target the selected connected player; the audio route determines which player's artwork may appear. Spotify cover downloads require a separate opt-in and accept only HTTPS responses from `i.scdn.co`, with a four-megabyte input limit and a downsampled preview. Music artwork is read through its local scripting interface. Optional Google sign-in personalizes the greeting; utility data has no cloud sync.

Scope’s **Enable Finder Extension…** opens macOS extension management. Enable **Bezel Finder Actions** yourself. The embedded sandboxed FinderSync extension offers Analyze, Inspect Archive, Compress, and Extract actions and sends validated `bezel://scope` requests to the host app. Inspection reads headers without creating files and flags unsafe paths/links. Compression/extraction still asks for a destination and refuses overwrites. The extension does not walk folders or alter Finder badges. It supports a single selected item.

Monolith’s notification automation uses the system `shortcuts` executable with direct arguments, bounded output, timeout, and cancellation. Create the two Set Focus workflows described in the module before enabling it. Bezel reports workflow execution; it cannot independently prove that an arbitrary user-selected workflow changed Focus. Menu collapse and native charge controls use private interfaces and need release-specific acceptance tests; they fail with a visible error when the installed interface differs.

## Architecture

- `Untitled Project/Core/`: shared observable model, permission center, Carbon shortcut lifecycle, validated Finder request parser.
- `Untitled Project/Design/`: native sidebar/dashboard, menu popover, reusable cards, Settings and setup.
- `Untitled Project/Modules/Stack/`: main-actor pasteboard/UI bridge and actor-owned raw payload store.
- `Untitled Project/Modules/AirBridge/`: HAL bindings, serial route actor, allocation-free realtime renderer with atomic gain/meter state, opt-in actor-owned player metadata through native ScriptingBridge, and UI.
- `Untitled Project/Modules/Aperture/`: nonactivating panel, hardware geometry, transient/persistent state arbitration, SwiftUI spring transitions and drop zone.
- `Untitled Project/Utilities/`: distinct Grid, Scope, Monolith, Shelf, Lens, Tether, Pulse, Border, and menu shelf services.
- `BezelFinder/`: embedded FinderSync extension target.
- `Untitled Project/Utilities/Tether/ChargeAgent/`: separate bundled executable target with a narrow runtime-checked battery interface.

Passive clipboard polling checks `changeCount` every 450 ms with tolerance; audio discovery runs on an actor every 1.5 seconds; battery refreshes every 30 seconds with tolerance. Window tracking exists only while a feature is enabled. Aperture synchronization uses Observation rather than a continuous timer. Its text timeline runs only while overflowing text is visible. Shared Focus status is checked once per second with tolerance only while Aperture and its Focus integration are enabled; it never requests consent in the background. Image previews downsample during decode. Audio callbacks allocate no memory and take no locks; stereo FFT workspaces are preallocated and run at most twenty analysis pairs per second per route. Focus reuses overlay windows. Storage scanning limits worker concurrency to six and bounds detail. Shutdown waits for Shelf temporary-image cleanup, Focus cleanup, requested battery writes, and audio teardown before replying to macOS.

Focus and anti-sleep countdowns use a shared `ContinuousClock` calculation. Calendar/network-clock changes do not alter the requested session duration, and elapsed time during sleep is reflected on wake. Pulse's expiry regression inspects the test process's actual IOKit assertions before and after expiry and restart.

## Reproducible verification

```sh
./Scripts/test-all.sh
# Headless renderer checks without live CoreAudio discovery:
./Scripts/test-airbridge.sh --skip-hardware
```

The scripts compile actual production sources in Swift 6 optimized mode, then check clipboard bounds/FIFO/stale consumers/retention, selected pasting, atomic bulk deletion, Focus transition/privacy baselines, owned-image cleanup and storage bounds, multi-display Shelf placement, realtime channel mapping and FFT frequency response, archive inspection and tar.gz/RAR5/7z extraction, ZIP round trips and attack fixtures, validated Finder URLs, storage/inspection cancellation, and power assertion lifecycle. Automation checks exercise literal process arguments, both output streams, inherited-pipe deadlines/cancellation, forced termination, output bounds, Focus races and recovery, menu visibility policy, and serialized charge requests using injected workflows. Media checks cover typed/bounded replies, route/player matching, player-specific controls, opt-in polling, stale results/consent cancellation, and artwork decode/HTTP/byte limits and request cancellation using a local URLProtocol fixture. They do not access players or the network. Native probes only read compatibility and charge state; they do not change charge settings, invoke user shortcuts, request privacy access, hide icons, or create audio taps. See `Tests/AirBridge/README.md` for audio acceptance cases.

## GitHub verification

The `Verify Bezel` workflow runs the production-source suites and an unsigned universal Release build on the Xcode 27 runner. It needs no signing certificate or Google credentials. Tests use injected permission/player fixtures; they never approve Accessibility, block input, or route live audio. System tests briefly create and release an idle-sleep assertion. Live permission flows and physical hardware checks remain manual.

## Apple API references

[Core Audio process taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps), [NSScreen notch safe areas](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea), [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit), and [FinderSync](https://developer.apple.com/documentation/findersync) provide the public framework foundations. Installed SDK headers are authoritative for the exact APIs compiled by this project.

[ScriptingBridge](https://developer.apple.com/documentation/scriptingbridge/sbapplication) provides native access to the installed Music/Spotify scripting dictionaries. The [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events) permits a hardened app to request Automation access; the user still grants each player's permission. Background queries use nonprompting [Automation permission preflight](https://developer.apple.com/documentation/coreservices/3025784-aedeterminepermissiontoautomatet).

Apple documents [running Shortcuts from the command line](https://support.apple.com/en-au/guide/shortcuts-mac/apd455c82f02/mac) and [native Charge Limit behavior](https://support.apple.com/en-us/102338). The private menu interface was investigated against the [Hidden Bar implementation](https://github.com/dwarvesf/hidden/tree/develop/hidden/Features/StatusBar/Engine/Native); charge-client selectors were investigated against [battery’s macOS 27 work](https://github.com/actuallymentor/battery/pull/480) and validated read-only against this Mac’s runtime. These community interfaces are not Apple-supported SDK contracts.

The public [Focus status center](https://developer.apple.com/documentation/intents/infocusstatuscenter) and [Focus usage-description key](https://developer.apple.com/documentation/bundleresources/information-property-list/nsfocusstatususagedescription) provide consent-based status reads. Native file previews use [QLPreviewView](https://developer.apple.com/documentation/quicklookui/qlpreviewview).

Apple DTS confirms that [ad-hoc signing changes the identity used by screen-capture permissions after rebuilds](https://developer.apple.com/forums/thread/819406). Apple's [ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) documents restarting after permission is granted.

Accessibility setup now shows **Window Access** (the Accessibility row) and **Keyboard Commands** separately, refreshes live, and offers **Check Access**. A bounded real window-list read confirms access when the trust flag disagrees. Release builds cannot overwrite a running archive; the latest repair is `Build/Bezel-Signed.xcarchive`. `BEZEL_ARCHIVE_PATH` selects build/package input, and `BEZEL_SIGNING_IDENTITY` defaults to Apple Development for stable local signing; `-` explicitly opts into ad-hoc signing.

Monolith now uses one continuous overlay per display instead of four moving rectangles. The active window stays clear, the edge feathers outward over 14 points, the Dock/menu bar stay visible, and beginning/ending a session fades the shade. Drag and AX events coalesce updates; stationary geometry falls back to four checks per second and only changed paths redraw. Reduce Motion skips transitions. Rendering tests inspect actual Core Animation output, along with spanning-window and negative-origin geometry. Live dragging and performance acceptance remain pending.

In-app action buttons use standard bordered macOS styles. Floating panels and notification surfaces retain native SwiftUI Liquid Glass on macOS 26 and later. Content cards keep inexpensive readable backgrounds. The dashboard has a simpler header, consistent spacing and rounded surfaces; the sidebar keeps native navigation behavior. Reduce Transparency and Increase Contrast use opaque surfaces, Reduce Motion skips custom hover transitions, and macOS 15–25 use standard materials and buttons. No continuously animated gradients or custom glass shaders run in the background. The camera-masking Aperture capsule stays black. Clicking a track moment or compact playback capsule opens a larger player with artwork, artist/album, previous/next, play/pause and source volume; a chevron or an outside click closes it. Track changes and pauses preserve the open controls. Spotify covers use the existing bounded image download path when enabled.

### Personal welcome

Overview now greets you by local time and cycles through five languages and native typefaces on hover. Optional Google sign-in supplies your first name, with session credentials saved in the macOS login Keychain. The account menu supports sign-out and disconnect. See [Google sign-in configuration and verification](Documentation/GoogleSignIn.md).

### Make the dashboard yours

Drag a utility card onto another card to rearrange Overview. The order is saved locally across launches; Arrange → Reset Layout restores the default. Right-click a card for Move Earlier/Later, also exposed as accessibility actions. Cards have a subtle pointer glow, lift, press response and icon bounce. The welcome card’s time-of-day symbol plays a brief bounce when clicked. Reduce Motion disables movement, and Reduce Transparency removes the pointer glow.

### Cleaning mode

The Cleaning utility blanks connected displays and pauses ordinary keyboard/mouse input for wiping your Mac. Hold Escape for two seconds to exit, use ⌘⌥Esc for an immediate exit, or wait for the chosen 1–5 minute deadline. See [Cleaning behavior and verification](Documentation/Cleaning.md).

### Aperture timeline

The expanded music player includes elapsed/remaining time and a draggable seek slider for connected Spotify and Apple Music tracks. Scrubs are bound to the player instance and track being displayed. See [timeline implementation and verification](Documentation/MusicTimeline.md).

YouTube Music in Chrome or Brave can connect directly to Aperture for track details, optional artwork, playback controls, volume and seeking. See [browser setup and verification](Documentation/YouTubeMusic.md).
