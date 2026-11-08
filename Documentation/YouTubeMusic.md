# YouTube Music browser connections

In Aperture > Now Playing, connect YouTube Music · Chrome or YouTube Music · Brave while that browser is running.
Start a song at https://music.youtube.com/. Approve Bezel's Automation
request for that browser and enable its View > Developer > Allow JavaScript from Apple Events.
Each browser connection is explicit and persists independently in media.players; it is not enabled by
Google account sign-in. No browser extension or Spotify account is needed.

The reader discovers HTTPS music.youtube.com tabs in the explicitly connected browser, executes the bundled
YouTubeMusic.js only on that origin, and returns bounded title/artist/album,
playback state, volume and finite timing. Other tab URLs are checked only to
locate YouTube Music; their content is not executed, retained or returned. It
prefers an actively playing tab; paused tabs remain available. Browser PID,
tab ID and song identity bind commands, with a fresh origin/song check before
transport, volume or seek. It never launches a browser or opens a tab during polling. Chrome and Brave have
separate process targets and caches, even when their numeric tab IDs match.

Album covers require the separate Download YouTube Music album artwork switch,
default off. Downloads use an ephemeral, cookie-free session, exact HTTPS image
hosts, safe redirect checks, a 4 MB limit, bounded decoding and cancellation.
Live/ad/invalid durations do not expose a seekable timeline. The notification
category obeys the Music & playback controls toggle introduced in Aperture.

Tests: Scripts/test-youtube-music.sh evaluates the actual JavaScript with browser
fixtures (including stale-song controls, origin rejection, seek/volume bounds,
missing/paused media, DOM fallback and ads). Scripts/test-media.sh covers native
source selection, payloads, artwork policies and invalid native browser targets.
Scripts/test-notch-player.sh checks the player, timeline and per-type toggles.
A read-only Chrome probe found no open YouTube Music tab on the development Mac;
actual site playback and app-origin Automation consent remain user acceptance
checks. YouTube may change its page structure, so failures are surfaced in the
Now Playing connection row. Current support is Chrome and Brave, not Safari or Firefox. Brave is not installed
on the development Mac; actual Brave playback and its Automation approval require
recipient acceptance. Native tests cover bundle allowlisting, Chrome/Brave source
selection, independent persisted connections, and missing-browser rejection.


## System menu-bar playback

Apple's public MPNowPlayingInfoCenter API publishes the calling app's own media.
It is not a documented cross-app reader for the menu-bar player. Bezel uses the
selected browser's scripting interface for these connections, keeping transport
and timeline controls tied to the actual browser/tab/song instead of scraping
Control Center or depending on private MediaRemote interfaces.
