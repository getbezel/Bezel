# GitHub preparation audit — November 7, 2026

Scope: existing Bezel source, all modules and integrations, release scripts,
automated tests, dependencies, and Git history. This is a source review and development repository, not approval for a production release.

## Confirmed defects repaired

- **Cleaning startup:** the input worker could observe an active session before
  its event tap was enabled and immediately end the session. Enabling, verifying,
  and publishing the session now use the same lock as shutdown. Regression tests
  force the activation/observer interleaving and check failed activation and stop.
- **DragWheel document conversion:** failed text reads could silently become
  successful blank PDFs. Reads now throw, snapshot at most 32 MiB before AppKit
  rendering, reject non-regular files, and enforce limits while reading. Missing,
  unreadable, oversized, directory and FIFO sources are covered alongside valid
  UTF/legacy text and rich-document conversions.
- **Browser media polling:** per-event timeouts multiplied across many tabs could
  occupy the shared player reader for minutes. YouTube Music scans now have a
  three-second monotonic budget, shrinking event timeouts, cached collection
  counts, and immediate transport-error exits. Tests use fake browser objects;
  they neither read real tabs nor request Automation permission.

## Verification

- The baseline and final production-source suites cover Stack, AirBridge, system
  utilities, automation, media, interface/capture, notch player, DragWheel,
  greetings, dashboard arrangement, Cleaning, and YouTube Music.
- A universal Release archive is built locally with Xcode 27, Swift 6 and the
  existing Apple Development identity. The main app, Finder extension and charge
  helper are verified for both arm64 and x86_64. The running app is not replaced.
- The separate Spotify prototype's deterministic JavaScript fixtures are checked
  as research code. This does not establish working Spotify ad acceleration.
- Shell/Python/JSON/plist/entitlement/shared-scheme syntax and Git whitespace are
  checked. The shared Xcode scheme and package lockfile are included for fresh
  checkouts.
- Gitleaks 8.30.1 checks both candidate files and all Git history. Its official
  binary download is checksum-verified. The only allowlist is structurally
  constrained source-file SHA-256 entries in verification manifests; these are
  file hashes, not API keys. No credentials or private keys were identified.
- GitHub Actions repeats secret scanning, the regression suites, and an unsigned
  universal build. It has read-only repository permissions, pinned action
  revisions, finite timeouts, and no deployment or signing credentials. The Xcode
  27 hosted runner is currently a preview image.

Build warnings remain for Google's upstream umbrella headers, a deprecated but
working AppAuth callback overload, and skipped AppIntents metadata extraction.
They are not compilation failures.

## Repository hygiene

Build/DMG artifacts, DerivedData variants, package checkouts, downloaded research
trees, user Xcode state, Python caches, environment files, certificates and
private-key containers are excluded. Account-specific signing and OAuth settings are read from an ignored local configuration. Account tokens remain in the user's Keychain and are not uploaded.

## Remaining release limitations

- Physical Bluetooth/mirrored audio, live privacy prompts on a clean recipient
  Mac, real Cleaning-mode input blocking, and multi-display/Space interaction
  still need acceptance testing. Passing injected tests is not that testing.
- The archive is Apple Development signed, not Developer ID notarized.
- Google OAuth requires developer-supplied local configuration and appropriate provider-side consent settings.
- The user-supplied DragWheel implementation has no confirmed upstream
  redistribution permission. Preserve the third-party notices and resolve this
  before public source or binary distribution.
- Native menu visibility and battery controls use private, runtime-checked
  interfaces. Charging behavior still requires hardware acceptance.
- Complex rich-document parsing/layout can occupy AppKit's main thread despite
  the bounded input read. The Spotify ad prototype remains experimental.

See [Release.md](Release.md) for the broader physical acceptance checklist.
