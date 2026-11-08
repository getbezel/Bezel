"use strict";
const assert = require("node:assert/strict");
const { AdSpeedController } = require("../../Companions/Spotify/bezel-ad-speed.js");

function player(overrides = {}) {
  return { src: "blob:ad", currentSrc: "blob:ad", muted: false, playbackRate: 1,
    paused: false, ended: false, loop: false, duration: 30, currentTime: 0,
    readyState: 4, ...overrides };
}
let now = 0;
const controller = new AdSpeedController(() => now);
const ad = player();
controller.reconcile(false, [ad]);
assert.equal(ad.playbackRate, 1, "ordinary content must not accelerate");
assert.equal(ad.muted, false);
controller.reconcile(true, [ad]);
assert.equal(ad.playbackRate, 10);
assert.equal(ad.muted, true);
assert.match(controller.status().message, /requested/, "setting rate is not proof");
now = 1000; ad.currentTime = 1;
controller.sample();
assert.doesNotMatch(controller.status().message, /measured/, "ignored rate must not be labelled successful");
now = 2000; ad.currentTime = 20;
assert.match(controller.sample().message, /measured 10.0/);
now = 3000; ad.currentTime = 30; ad.ended = true;
controller.ended(ad);
assert.equal(controller.status().completed[0].effectiveRate, 10);
assert.equal(ad.muted, false);
assert.equal(ad.playbackRate, 1);
controller.reconcile(false, []);
assert.equal(controller.sample().message, "Waiting for an ad");

const alreadyMuted = player({ muted: true, playbackRate: 1.5 });
controller.reconcile(true, [alreadyMuted]);
controller.setEnabled(false);
assert.equal(alreadyMuted.muted, true, "preserve original mute state");
assert.equal(alreadyMuted.playbackRate, 1.5, "restore original playback speed");
controller.setEnabled(true);
controller.reconcile(false, []);

const manual = player();
controller.reconcile(true, [manual]);
manual.muted = false;
controller.reconcile(true, [manual]);
assert.equal(manual.muted, false);
assert.equal(manual.playbackRate, 1);
controller.reconcile(true, [manual]);
assert.equal(manual.muted, false, "manual override must not be fought");
controller.reconcile(false, []);

const replaced = player();
controller.reconcile(true, [replaced]);
replaced.src = replaced.currentSrc = "blob:next-song";
controller.sourceChanged(replaced);
controller.reconcile(true, [replaced]);
assert.equal(replaced.playbackRate, 1, "lingering ad UI must not speed up the next song");
assert.equal(replaced.muted, false);
controller.reconcile(false, []);

const unsupported = player();
Object.defineProperty(unsupported, "playbackRate", { get: () => 1, set: () => { throw Error("unsupported"); } });
controller.reconcile(true, [unsupported]);
assert.equal(unsupported.muted, true);
assert.doesNotMatch(controller.status().message, /measured/);
controller.restore();
assert.equal(unsupported.muted, false);

const frozen = player({ duration: Infinity });
const canvas = player({ loop: true });
controller.reconcile(true, [frozen, canvas]);
assert.equal(controller.status().controlledElements, 0, "ignore live streams and looping artwork");
assert.equal(canvas.playbackRate, 1);
console.log("PASS: actual-progress verification, completion timing, source transition, restoration, user override, unsupported rate, artwork exclusion");
