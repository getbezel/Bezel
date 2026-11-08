# AirBridge clock and browser-process repair — October 29, 2026

The reported “requires native 32-bit floating-point PCM” error was reproducible
with a 48 kHz process tap and 44.1 kHz built-in/headphone output streams, even
though both formats were already native Float32 PCM. Route creation incorrectly
required the individual stream-rate labels to match.

The private aggregate uses the selected primary output as its master clock.
Core Audio drift compensation converts the tap and secondary output into that
clock domain. The IOProc receives equal frame counts on this clock; it must not
apply another resampling step based on the member streams' original ASBD rates.
Route setup now accepts those different rate labels, uses the aggregate nominal
rate for spectrum analysis, enables maximum-quality tap/secondary-device drift
compensation, and obtains the tap UID from Core Audio. Health checks monitor the
aggregate clock as well as stream formats and device liveness. Physical device
rates are never changed by the fix. Unsupported PCM layouts remain rejected.

Browser audio often lives in a service process that NSRunningApplication does
not expose. Discovery now uses proc_pidpath when needed, resolves the outer
application bundle, and groups its audio objects into one application row with
the owning app's name/icon. Unknown helpers stay separate. Routing includes all
members; the engine updates tap membership as the app's audio processes change.
This also supplies the correct parent bundle ID to Aperture's player matching.

Inactive rows now say Not playing audio, explain that playback must start before
sound is available, and identify a prepared route as waiting for audio. Volume
controls explain that Start Routing is needed before they affect playback.

## Verification

- Scripts/test-airbridge.sh passes renderer, gain, channel-layout, silence,
  spectrum and owning-application grouping checks.
- Scripts/test-airbridge.sh --check-active-route is an explicit opt-in live test:
  it routes the first currently emitting application through the current default
  output at unity gain for one second, checks buffer progress and route health,
  stops, and verifies the output's original stream rates remain unchanged.
- On the development Mac, Chrome's three audio processes grouped into one active
  Google Chrome row. The live External Headphones route delivered 87 healthy
  callbacks, equal input/output peaks and unchanged hardware rates. A separate
  bounded live probe delivered 113 callbacks with 512 input/output frames and
  matching nonzero levels. All test routes stopped and restored normal audio.
- These checks do not establish audible acceptance on every USB, Bluetooth or
  multi-output hardware combination. No audio samples are saved by the probes.
