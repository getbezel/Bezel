# Spotify ad speed prototype

This is a first-party Bezel prototype, written for this workspace. It requests
10× playback and mutes only during explicit Spotify ad controls or an ad URI.
It restores the media element's original playback speed and mute state afterward,
when disabled, on source replacement, and when stopped. It makes no network
requests and reads no Spotify credentials, cookies, or account tokens.

**Status:** verified against real Chromium fixture audio playback. Live testing
of Spotify for Mac 1.3.3.264 found native audio ads with no HTML media element.
The native player's `setSpeed(10)` rejected a real ad with
`not_supported_by_content_type`; seeking rejected with `ad_disallow`. An
ad-specific skip request did not produce a verified early completion. This is
not a shipped or validated ad blocker in Bezel. A successful rate setter is never reported as
proof: the prototype measures `currentTime` and records effective speed at the
natural end of playback. An ad with no controllable media reports that fact.

Ordinary track titles, including “Advertisement,” do not trigger the controller.
Looping Canvas artwork and live/unknown-duration streams are excluded. If the
user unmutes an ad, the controller backs off for that element. A changed source
is restored and held at its original settings until the old ad UI disappears;
this favors protecting the next song over accelerating consecutive ads that
reuse an element while keeping stale UI on screen.

## Reproducible checks

```sh
node Tests/Media/AdSpeedTests.cjs
node Tests/Media/AdSpeedBrowserTest.cjs
node Scripts/probe-spotify-ad-speed.cjs --plan
```

The browser test starts a loopback server that serves only the two fixture files,
launches an isolated headless Chrome session via agent-browser, plays a generated
30-second silent PCM fixture, checks actual completion time and restoration,
then checks detached media, title false positives, and disabling. It closes only
its own test browser. It never visits Spotify or accesses the user's browser
profile. `BEZEL_TEST_CHROME` overrides the installed Chrome executable path;
`BEZEL_AD_TEST_RESULT` writes the measured JSON result.

## Desktop experiment

The reviewed live probe injects the controller temporarily through Spotify's
loopback debugging connection. It does not modify or re-sign Spotify, change
preferences, launch it, or install Spicetify/SpotX. Testing requires a separately
authorized normal quit and relaunch of Spotify with a temporary debugging port.
An existing renderer is accepted only at `https://xpui.app.spotify.com`; discovery
and output are restricted to counts and controller diagnostics. The probe removes
its own script and restores settings when stopped. Reopen Spotify normally after
the experiment to close the debugging port. If Spotify refuses remote debugging,
the experiment must report that failure rather than silently patching the app.

The owner authorized the desktop test. Spotify was quit normally, tested through
a temporary loopback connection, and reopened normally afterward. Volume was
confirmed restored to its original value, playback speed remained 1, and the
debugging listener was closed. The original `xpui.spa` SHA-256 and strict app
signature were unchanged. Bezel's running app and signed archive were untouched.

`native-ad-test.js` contains the separate, temporary native experiment. It
rechecks the exact native ad URI after asynchronous speed rejection before an
ad-specific skip, restores only its own mute, and restores any accepted speed.
Its tests include late replies, cancellation, accepted-speed cleanup and an
already-muted player:

```sh
node Tests/Media/NativeAdTests.cjs
```

The presence of an internal command does not establish that Spotify permits it.
The native experiment must not be installed as a working 10× feature. The web
companion still requires a real Spotify web ad test; the Chromium fixture result
alone does not establish that Spotify's web player accepts the same behavior.

## Browser experiment

`manifest.json` is an unpacked Chrome/Chromium companion restricted to
`https://open.spotify.com/*`. It injects at document start into the main world to
observe detached media playback. It has no storage, network, tab, or broad host
permissions. Loading it still requires the user's explicit browser installation.
Remove/disable it and reload Spotify to remove the prototype. Console controls:

```js
BezelAdSpeed.status()
BezelAdSpeed.setEnabled(false)
BezelAdSpeed.stop()
```

## Research

[Speedify's playback-rate implementation](https://github.com/Quema100/Speedify/blob/main/main.js)
shows the in-player browser technique. This prototype uses independently written
code with completion measurement and cleanup. [Spicetify's speed documentation](https://spicetify.app/docs/development/api-wrapper/methods/platform#setspeed)
states that its internal command changes podcast speed, not music. [Spotify's
debugging flags](https://spicetify.app/docs/development/spotify-cli-flags) provide
the temporary desktop probe route, subject to the installed client's support.
