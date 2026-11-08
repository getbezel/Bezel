# Aperture moment preferences

Aperture > Show in Aperture provides independent Clipboard previews, Music &
playback controls, Focus session timer and Shelf drop zone toggles. Shared system
Focus changes retain their existing separate toggle and permission controls below.

The four new preferences default to enabled for existing installations and persist
in UserDefaults under aperture.moments.*. Turning a type off immediately dismisses
its current display and restores the next enabled persistent state. Hiding music
also closes expanded controls, suppresses track-change moments and prevents notch
clicks from reopening the hidden player. Incoming metadata remains available for
immediate restoration if re-enabled. Disabling Shelf rejects notch drops as well
as suppressing drag detection. These settings do not disable Stack capture, focus
sessions, audio routing, or the standalone Shelf drawer.

Scripts/test-notch-player.sh verifies default behavior, immediate dismissal,
clipboard suppression during playback/focus, music polling/expansion suppression,
restoration, and persistence across service instances, alongside existing player
and seek tests. Universal archive and mounted DMG verification are recorded in
AperturePreferencesVerification.json. Live interaction on another Mac is not
established by these checks.

## Compact height correction

Compact music and focus states no longer add four points below the camera/menu
bar area. The built-in display reports a 32-point camera safe area and the compact
state now uses exactly that height. Non-notched displays use native status-bar
thickness instead of a fixed 28-point capsule. Hover and explicit expansion
retain their larger content heights. Notch player tests assert compact alignment
and retained hover expansion.
