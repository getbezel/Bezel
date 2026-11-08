#!/usr/bin/env node
"use strict";
// Temporary renderer probe. It never patches Spotify, changes its preferences,
// reads account tokens, or closes the application. Attach requires a Spotify
// session explicitly launched with a loopback remote-debugging port.
const fs = require("node:fs/promises");
const path = require("node:path");
const crypto = require("node:crypto");
const { setTimeout: delay } = require("node:timers/promises");
const root = path.resolve(__dirname, "..");

class DebugSession {
  constructor(socket) {
    this.socket = socket;
    this.nextID = 1;
    this.pending = new Map();
    socket.addEventListener("message", event => {
      let reply;
      try { reply = JSON.parse(event.data); } catch { return; }
      const item = this.pending.get(reply.id);
      if (!item) return;
      this.pending.delete(reply.id);
      clearTimeout(item.timer);
      if (reply.error) item.reject(Error("Spotify's renderer rejected the debugging command."));
      else item.resolve(reply.result);
    });
    socket.addEventListener("close", () => {
      for (const item of this.pending.values()) {
        clearTimeout(item.timer); item.reject(Error("Spotify's temporary debugging connection closed."));
      }
      this.pending.clear();
    });
  }
  static async connect(url) {
    const socket = new WebSocket(url);
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { socket.close(); reject(Error("Spotify debugging connection timed out.")); }, 5000);
      socket.addEventListener("open", () => { clearTimeout(timeout); resolve(); }, { once: true });
      socket.addEventListener("error", () => { clearTimeout(timeout); reject(Error("Spotify debugging connection failed.")); }, { once: true });
    });
    return new DebugSession(socket);
  }
  async evaluate(expression) {
    const id = this.nextID++;
    const result = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(Error("Spotify did not answer the probe within five seconds.")); }, 5000);
      this.pending.set(id,{resolve,reject,timer});
      try {
        this.socket.send(JSON.stringify({id,method:"Runtime.evaluate",params:{expression,returnByValue:true}}));
      } catch (error) {
        clearTimeout(timer); this.pending.delete(id); reject(error);
      }
    });
    if (result.exceptionDetails) throw Error("Spotify's renderer could not run the prototype.");
    return result.result?.value;
  }
  close() { this.socket.close(); }
}

async function main() {
  const source = await fs.readFile(path.join(root,"Companions/Spotify/bezel-ad-speed.js"),"utf8");
  const args = process.argv.slice(2);
  const portIndex = args.indexOf("--attach");
  if (args.length === 0 || (args.length === 1 && args[0] === "--plan")) {
    console.log(JSON.stringify({
      mode:"plan-only", payloadSHA256:crypto.createHash("sha256").update(source).digest("hex"),
      payloadBytes:Buffer.byteLength(source),
      target:"Spotify Mac renderer on a temporary 127.0.0.1 debugging port",
      action:"Inject the local controller, measure ad timeline and completion, then restore settings and detach",
      installationChanges:[], accountAccess:false,
      acceptance:"An actual Spotify ad must finish at an effective rate near 10×; setter acceptance alone is insufficient",
      next:"With approval, normally quit and relaunch Spotify with --remote-debugging-address=127.0.0.1 --remote-debugging-port=<unused port>, then run --attach <port> --seconds 180",
    },null,2));
    return;
  }
  const secondsIndex = args.indexOf("--seconds");
  const port = Number(args[portIndex + 1]);
  const seconds = secondsIndex < 0 ? 180 : Number(args[secondsIndex + 1]);
  const expected = secondsIndex < 0 ? 2 : 4;
  if (portIndex !== 0 || args.length !== expected ||
      (secondsIndex >= 0 && secondsIndex !== 2) || !Number.isInteger(port) || port < 1024 || port > 65535 ||
      !Number.isInteger(seconds) || seconds < 5 || seconds > 600) {
    throw Error("Use --plan, or --attach <loopback port> --seconds <5–600>.");
  }
  const response = await fetch(`http://127.0.0.1:${port}/json/list`, {signal:AbortSignal.timeout(5000)});
  if (!response.ok) throw Error("Spotify's temporary debugging endpoint is unavailable.");
  const body = await response.text();
  if (body.length > 256 * 1024) throw Error("Unexpectedly large debugging discovery response.");
  const pages = JSON.parse(body);
  if (!Array.isArray(pages)) throw Error("Invalid debugging discovery response.");
  const targets = pages.filter(page => {
    try { return page.type === "page" && new URL(page.url).origin === "https://xpui.app.spotify.com"; }
    catch { return false; }
  });
  if (targets.length !== 1) throw Error("Expected exactly one Spotify renderer; no script was injected.");
  const url = new URL(targets[0].webSocketDebuggerUrl);
  if (url.protocol !== "ws:" || !["127.0.0.1","localhost"].includes(url.hostname) ||
      Number(url.port) !== port || url.username || url.password) throw Error("Debugging must stay on the specified loopback port.");
  const session = await DebugSession.connect(url.href);
  const abort = new AbortController();
  const interrupted = () => abort.abort();
  process.once("SIGINT",interrupted); process.once("SIGTERM",interrupted);
  let injected = false, verified = false;
  const ownership = crypto.randomUUID();
  try {
    const ready = await session.evaluate("({origin:location.origin,existing:typeof window.BezelAdSpeed !== 'undefined'})");
    if (ready?.origin !== "https://xpui.app.spotify.com" || ready.existing) throw Error("Unexpected renderer or existing controller; nothing was changed.");
    await session.evaluate(source);
    injected = true;
    await session.evaluate(`window.__bezelAdProbeOwner = ${JSON.stringify(ownership)}`);
    console.log("Attached a temporary local prototype. No Spotify files or account settings were changed.");
    let previous;
    const end = Date.now() + seconds * 1000;
    while (Date.now() < end && !abort.signal.aborted) {
      const result = await session.evaluate("({status:window.BezelAdSpeed.status(),domMediaElements:document.querySelectorAll('audio,video').length})");
      const serialized = JSON.stringify(result);
      if (previous !== serialized) { console.log(serialized); previous = serialized; }
      if (result?.status?.completed?.some(item => item.effectiveRate >= 7 && item.effectiveRate <= 13)) {
        verified = true; break;
      }
      await delay(1000,undefined,{signal:abort.signal}).catch(() => {});
    }
    console.log(verified ? "VERIFIED: a detected Spotify ad completed at an effective rate near 10×." :
      "UNVERIFIED: no accelerated Spotify ad completion was observed. Do not label the desktop feature working.");
  } finally {
    if (injected) {
      try {
        const cleaned = await session.evaluate(`(() => { if (window.__bezelAdProbeOwner !== ${JSON.stringify(ownership)}) return false; window.BezelAdSpeed.stop(); delete window.BezelAdSpeed; delete window.__bezelAdProbeOwner; return true; })()`);
        if (!cleaned) throw Error("Probe ownership changed.");
        console.log("Restored original media settings and removed the temporary prototype.");
      } catch {
        console.error("The renderer disconnected before cleanup could be confirmed. Reopen Spotify normally to clear the temporary script.");
        process.exitCode = 1;
      }
    }
    session.close();
    process.removeListener("SIGINT",interrupted); process.removeListener("SIGTERM",interrupted);
  }
  if (!verified) process.exitCode = 2;
}

main().catch(() => {
  // Avoid dumping remote exception descriptions, page contents, or account data.
  console.error("The Spotify probe could not connect or complete. Check the loopback debugging session; no desktop capability has been verified.");
  process.exitCode = 1;
});
