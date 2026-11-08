// Runs only in an explicitly connected supported browser tab on the YouTube Music origin.
(function (request) {
    if (location.protocol !== 'https:' || location.hostname !== 'music.youtube.com')
        return JSON.stringify({error: 'This tab is no longer YouTube Music.'});
    const bar = document.querySelector('ytmusic-player-bar');
    const media = document.querySelector('video');
    if (!bar || !media) return JSON.stringify({playing: false});
    const clean = value => typeof value === 'string' ? value.replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').trim().slice(0, 512) : '';
    const metadata = navigator.mediaSession && navigator.mediaSession.metadata;
    const titleNode = bar.querySelector('.title');
    const artistNode = bar.querySelector('.byline');
    const title = clean((metadata && metadata.title) || (titleNode && titleNode.textContent));
    const artist = clean((metadata && metadata.artist) || (artistNode && artistNode.textContent));
    // Include the displayed song as well as the URL: SPA navigation can update these separately.
    const videoID = [clean(new URL(location.href).searchParams.get('v')).slice(0, 128), title.slice(0, 128), artist.slice(0, 128)].join('|');
    const advert = bar.hasAttribute('ad-showing') || !!document.querySelector('.ad-showing');
    const timed = !advert && Number.isFinite(media.duration) && media.duration > 0 && media.duration <= 604800 && Number.isFinite(media.currentTime);
    if (request.action !== 'read') {
        if (!request.expectedID || request.expectedID !== videoID)
            return JSON.stringify({error: 'The song changed. Wait a moment and try again.'});
        let button;
        if (request.action === 'next') button = bar.querySelector('.next-button');
        else if (request.action === 'previous') button = bar.querySelector('.previous-button');
        else if (request.action === 'playPause') button = bar.querySelector('#play-pause-button');
        else if (request.action === 'volume') {
            if (!Number.isInteger(request.volume) || request.volume < 0 || request.volume > 100)
                return JSON.stringify({error: 'Invalid volume.'});
            media.volume = request.volume / 100;
            media.muted = request.volume === 0;
        } else if (request.action === 'seek') {
            if (!timed || !Number.isFinite(request.seconds) || request.seconds < 0 || request.seconds > media.duration)
                return JSON.stringify({error: 'This source has no seekable timeline.'});
            media.currentTime = request.seconds;
        } else return JSON.stringify({error: 'Unknown playback action.'});
        if (['next', 'previous', 'playPause'].includes(request.action)) {
            if (!button || button.disabled || button.getAttribute('aria-disabled') === 'true')
                return JSON.stringify({error: 'YouTube Music has not made that control available.'});
            button.click();
        }
    }
    const artwork = metadata && metadata.artwork;
    const image = bar.querySelector('img');
    return JSON.stringify({playing: !media.paused && !media.ended, id: title ? videoID : '',
        title, artist, album: clean(metadata && metadata.album),
        artworkURL: (artwork && artwork.length ? artwork[artwork.length-1].src : image && image.src) || '',
        volume: media.muted ? 0 : Math.round(media.volume * 100),
        position: timed ? Math.max(0, Math.min(media.duration, media.currentTime)) : null,
        duration: timed ? media.duration : null});
})
