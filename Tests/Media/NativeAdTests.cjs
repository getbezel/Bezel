"use strict";
const assert = require("node:assert/strict");
const { NativeAdController } = require("../../Companions/Spotify/native-ad-test.js");
let time = 0, muted = false, skips = 0, reject;
let state = { item:{type:"track",uri:"spotify:track:content"},isPaused:false,duration:30000,positionAsOfTimestamp:0,timestamp:Date.now() };
const player = {getState:()=>state,setSpeed:()=>new Promise((_,r)=>{reject=r;})};
const volume = {isMuted:()=>muted,mute:()=>{muted=true},unmute:()=>{muted=false}};
const controller = new NativeAdController(player,{skipToNext:()=>{skips++;}},volume,()=>time);
controller.start();
controller.tick();
assert.equal(skips,0); assert.equal(muted,false);
state={...state,item:{type:"ad",uri:"spotify:ad:first"}};
controller.tick(); assert.equal(muted,true);
// Late rejection after the next song started must never skip that song.
state={...state,item:{type:"track",uri:"spotify:track:next"}};
reject(Error("not_supported_by_content_type"));
setImmediate(()=>{
  assert.equal(skips,0,"stale speed reply must not skip content");
  controller.tick(); assert.equal(muted,false);
  state={...state,item:{type:"ad",uri:"spotify:ad:second"}};
  controller.tick(); reject(Error("not_supported_by_content_type"));
  setImmediate(()=>{
    assert.equal(skips,1,"only a still-current verified ad may be skipped");
    controller.tick(); assert.equal(skips,1,"no repeated requests for the same ad");
    time=400;
    state={...state,item:{type:"track",uri:"spotify:track:after"}};
    controller.tick(); assert.equal(muted,false);
    assert.equal(controller.status().results.at(-1).elapsed,.4);
    state={...state,item:{type:"ad",uri:"spotify:ad:third"}};
    controller.tick(); controller.stop(); reject(Error("not_supported_by_content_type"));
    setImmediate(()=>{
      assert.equal(skips,1,"stop must cancel pending skip intent"); assert.equal(muted,false);
      console.log("PASS: native ad identity, asynchronous stale replies, single skip, mute restoration and stop cancellation");
    });
  });
});

// A future client may accept the speed command. Restore the exact prior speed
// both on a normal stop and when acceptance arrives after the test was stopped.
(async () => {
  let current = { item: { type: "ad", uri: "spotify:ad:accepted" }, isPaused: false,
    duration: 30000, positionAsOfTimestamp: 0, timestamp: Date.now(), speedEsperanto: 1.25 };
  let accept, localMuted = true;
  const supportedPlayer = {
    getState: () => current,
    setSpeed: speed => speed === 10 ? new Promise(resolve => {
      accept = () => { current = { ...current, speedEsperanto: 10 }; resolve(); };
    }) : (current = { ...current, speedEsperanto: speed }, Promise.resolve()),
  };
  const localVolume = { isMuted: () => localMuted, mute: () => { localMuted = true; },
    unmute: () => { localMuted = false; } };
  const supported = new NativeAdController(supportedPlayer, {
    skipToNext: () => assert.fail("Accepted speed must not trigger an ad skip"),
  }, localVolume);
  supported.start(); supported.tick(); accept();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(current.speedEsperanto, 10);
  await supported.stop();
  assert.equal(current.speedEsperanto, 1.25, "stop restores the original speed");
  assert.equal(localMuted, true, "a preexisting mute belongs to the user");
  const late = new NativeAdController(supportedPlayer, {
    skipToNext: () => assert.fail("A stopped controller must never skip"),
  }, localVolume);
  late.start(); late.tick(); await late.stop(); accept();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(current.speedEsperanto, 1.25, "late acceptance is also restored");
  assert.equal(localMuted, true);
  console.log("PASS: accepted speed restoration, late acceptance cleanup and preexisting mute ownership");
})().catch(error => { console.error(error); process.exitCode = 1; });
