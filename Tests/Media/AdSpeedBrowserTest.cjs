"use strict";
const assert = require("node:assert/strict");
const http = require("node:http");
const fs = require("node:fs/promises");
const path = require("node:path");
const { execFile } = require("node:child_process");
const { promisify } = require("node:util");
const run = promisify(execFile);
const root = path.resolve(__dirname, "../..");
const session = `bezel-ad-test-${process.pid}`;
const chrome = process.env.BEZEL_TEST_CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const agent = (...args) => run("npx", ["--yes", "agent-browser", "--session", session, ...args],
  { timeout: 45000, maxBuffer: 1024 * 1024 });

(async () => {
  await fs.access(chrome);
  const fixture = await fs.readFile(path.join(__dirname,"ad-speed-fixture.html"));
  const script = await fs.readFile(path.join(root,"Companions/Spotify/bezel-ad-speed.js"));
  // Serve only these two fixtures. Never expose the user's workspace or login.
  const server = http.createServer((request, response) => {
    if (request.url === "/Tests/Media/ad-speed-fixture.html") {
      response.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
      response.end(fixture);
    } else if (request.url === "/Companions/Spotify/bezel-ad-speed.js") {
      response.writeHead(200, { "Content-Type": "text/javascript; charset=utf-8", "Cache-Control": "no-store" });
      response.end(script);
    } else { response.writeHead(404); response.end(); }
  });
  await new Promise(resolve => server.listen(0,"127.0.0.1",resolve));
  let result;
  try {
    const port = server.address().port;
    await agent("--executable-path", chrome, "open", `http://127.0.0.1:${port}/Tests/Media/ad-speed-fixture.html`);
    console.log((await agent("snapshot", "-i")).stdout.trim());
    await agent("find", "role", "button", "click", "--name", "Run 30-second ad at 10×");
    await agent("wait", "--fn", "window.fixtureResult !== null");
    const output = (await agent("eval", "JSON.stringify(window.fixtureResult)")).stdout.trim();
    result = JSON.parse(output);
    if (typeof result === "string") result = JSON.parse(result);
    assert.equal(result.duration, 30);
    assert.ok(result.elapsed > 2 && result.elapsed < 5, `30-second audio finished in ${result.elapsed}s`);
    assert.ok(result.effectiveRate > 7 && result.effectiveRate < 13);
    assert.equal(result.restoredRate, 1);
    assert.equal(result.restoredMute, false);
    assert.equal(result.status.completed.length, 1, "natural ended event was captured");
    assert.equal(result.status.message, "Waiting for an ad");
    // A detached media element (Spotify creates these) must be discoverable,
    // while a track named Advertisement alone must never trigger acceleration.
    await agent("eval", "(async () => { document.title='Advertisement'; window.detachedFixture = new Audio(document.querySelector('audio').src); await new Promise(resolve => detachedFixture.addEventListener('loadeddata',resolve,{once:true})); await detachedFixture.play(); })()");
    const ordinary = JSON.parse((await agent("eval", "JSON.stringify({rate:detachedFixture.playbackRate,muted:detachedFixture.muted})")).stdout.trim());
    const ordinaryValue = typeof ordinary === "string" ? JSON.parse(ordinary) : ordinary;
    assert.deepEqual(ordinaryValue,{rate:1,muted:false});
    await agent("eval", "document.querySelector('#signal').dataset.testid='ad-controls'");
    await agent("wait", "--fn", "detachedFixture.playbackRate === 10 && detachedFixture.muted");
    await agent("eval", "BezelAdSpeed.setEnabled(false)");
    const disabled = JSON.parse((await agent("eval", "JSON.stringify({rate:detachedFixture.playbackRate,muted:detachedFixture.muted})")).stdout.trim());
    assert.deepEqual(typeof disabled === "string" ? JSON.parse(disabled) : disabled,{rate:1,muted:false});
    await agent("eval", "detachedFixture.pause(); BezelAdSpeed.stop()");
    if (process.env.BEZEL_AD_TEST_RESULT) {
      await fs.writeFile(process.env.BEZEL_AD_TEST_RESULT, JSON.stringify(result,null,2) + "\n");
    }
    console.log("PASS: real Chromium 30-second playback accelerated and restored", JSON.stringify(result));
  } finally {
    await agent("close").catch(() => {});
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
