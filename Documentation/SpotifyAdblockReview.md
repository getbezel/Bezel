# Prepared Spotify desktop ad blocker

The installed Spotify 1.3.3.264 remains unchanged. A separate copy is prepared
under `Build/Spotify-Adblock.noindex/Spotify.app`. This blocks local ads directly;
it does not implement 10× playback and is not yet integrated into Bezel's UI.
Actual playback/ad-blocking acceptance is pending installation approval.

Source: [SpotX-Bash revision 5cf0c31](https://github.com/SpotX-Official/SpotX-Bash/tree/5cf0c31eb736af4c54624d517430790c5616bb82).
Its MIT license is preserved alongside the downloaded source in
`Companions/Spotify/Research.noindex/LICENSE`.

The adapter applies nine ad patches: bGabo, bSlot, adsX2, adConfig,
adsEmptyBlock, esperantoProductState, hptoFetch, sGate3 and stateS3. Every selected
patch matched this exact copy. The native gate and slots patches each matched
once. The product-state override sets only ads=0; it does not set subscription
type or catalogue. No experimental features, unrelated music-video changes,
telemetry patches, account changes, cache clearing or updater changes are applied.

The prepared copy is ad-hoc signed and passes strict deep verification. The
original installed app still passes its original signature verification; its
resource and executable hashes match the preparation baseline. These checks
establish patch integrity, not that ads are eliminated during real playback.

Installing normally quits only the exact `/Applications/Spotify.app` instance,
rechecks both builds, keeps the entire original bundle in
`Build/Spotify-Recovery.noindex/StockSpotify.bundle`, places the prepared copy at
the existing application path and opens it normally. Bezel stays running.
Spotify's changed signature may require reconnecting Automation in Bezel.
Spotify updates can replace the patches; updates remain enabled.

After explicit approval:

```sh
python3 Scripts/manage-spotify-adblock.py install
```

Restore the exact original bundle and signature:

```sh
python3 Scripts/manage-spotify-adblock.py restore
```

Both paths refuse replacement if the app has changed since preparation. Neither
path executes a remotely fetched installer, force-kills Spotify, requests privacy
grants, changes account data, or leaves a debugging listener running.

Detailed patch counts and hashes: `SpotifyAdblockPreparation.json`.
