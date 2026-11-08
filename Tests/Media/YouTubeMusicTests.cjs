const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../../Untitled Project/Modules/AirBridge/YouTubeMusic.js'), 'utf8');
function fixture() {
    const media = {paused: false, ended: false, currentTime: 23, duration: 180, volume: 0.6, muted: false};
    const clicks = [];
    const buttons = Object.fromEntries(['.next-button', '.previous-button', '#play-pause-button'].map(key => [key, {
        disabled: false, getAttribute: () => null, click() { clicks.push(key); }
    }]));
    const metadata = {title: 'Song', artist: 'Artist', album: 'Album', artwork: [{src: 'https://lh3.googleusercontent.com/cover'}]};
    let ad = false, absent = false, queries = 0;
    const bar = {
        hasAttribute: () => ad,
        querySelector: key => buttons[key] || ({'.title': {textContent: 'DOM song'}, '.byline': {textContent: 'DOM artist'}, img: {src: 'https://i.ytimg.com/cover'}})[key]
    };
    const context = {URL, location: {protocol: 'https:', hostname: 'music.youtube.com', href: 'https://music.youtube.com/watch?v=abc'}, navigator: {mediaSession: {metadata}},
        document: {querySelector(key) { queries++; return absent ? null : key === 'ytmusic-player-bar' ? bar : key === 'video' ? media : null; }}};
    const run = request => JSON.parse(vm.runInNewContext(source + '(' + JSON.stringify(request) + ')', context, {timeout: 1000}));
    return {media, metadata, buttons, clicks, context, run, ad: () => {ad = true;}, absent: () => {absent = true;}, queries: () => queries};
}
let f = fixture();
let r = f.run({action: 'read'});
assert.equal(r.title, 'Song'); assert.equal(r.artist, 'Artist'); assert.equal(r.playing, true);
assert.equal(r.position, 23); assert.equal(r.duration, 180); assert.equal(r.volume, 60);
assert.equal(r.artworkURL, 'https://lh3.googleusercontent.com/cover');
for (const action of ['next', 'previous', 'playPause']) assert.equal(f.run({action, expectedID: r.id}).error, undefined);
assert.equal(f.clicks.length, 3);
assert.equal(f.run({action: 'seek', expectedID: r.id, seconds: 72}).error, undefined); assert.equal(f.media.currentTime, 72);
assert.ok(f.run({action: 'seek', expectedID: r.id, seconds: 181}).error); assert.equal(f.media.currentTime, 72);
assert.ok(f.run({action: 'seek', expectedID: r.id, seconds: null}).error);
assert.equal(f.run({action: 'volume', expectedID: r.id, volume: 0}).volume, 0); assert.equal(f.media.muted, true);
f.run({action: 'volume', expectedID: r.id, volume: 44}); assert.equal(f.media.muted, false); assert.equal(f.media.volume, 0.44);
assert.ok(f.run({action: 'volume', expectedID: r.id, volume: 101}).error); assert.equal(f.media.volume, 0.44);
f.metadata.title = 'Another song';
assert.ok(f.run({action: 'next', expectedID: r.id}).error); assert.equal(f.clicks.length, 3);
f = fixture(); r = f.run({action: 'read'}); f.buttons['.next-button'].disabled = true;
assert.ok(f.run({action: 'next', expectedID: r.id}).error); assert.equal(f.clicks.length, 0);
f.media.paused = true; assert.equal(f.run({action: 'read'}).playing, false);
f.media.duration = Infinity; assert.equal(f.run({action: 'read'}).duration, null);
f = fixture(); r = f.run({action: 'read'}); f.ad();
assert.equal(f.run({action: 'read'}).duration, null); assert.ok(f.run({action: 'seek', expectedID: r.id, seconds: 20}).error);
f = fixture(); f.context.location.hostname = 'youtube.com'; assert.ok(f.run({action: 'read'}).error); assert.equal(f.queries(), 0);
f = fixture(); f.absent(); assert.equal(f.run({action: 'read'}).playing, false);
f = fixture(); f.context.navigator.mediaSession.metadata = null; assert.equal(f.run({action: 'read'}).title, 'DOM song');
f = fixture(); f.metadata.title = 'x'.repeat(4000); f.metadata.artist = 'y'.repeat(4000); r = f.run({action: 'read'});
assert.equal(r.title.length, 512); assert.ok(r.id.length < 512); assert.equal(f.run({action: 'playPause', expectedID: r.id}).error, undefined);
console.log('YouTube Music script checks passed: origin, metadata, paused/missing player, DOM fallback, bounded identity, stale-song rejection, transport, volume, seek bounds and unavailable/ad timelines.');
