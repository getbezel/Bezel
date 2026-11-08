/* Temporary native Spotify experiment. No installation, network hooks or gate changes. */
(function installNativeAdTest(root) {
  "use strict";
  if (root.BezelNativeAdTest) return;
  class NativeAdController {
    constructor(player, ads, volume, clock = () => performance.now()) {
      this.player = player; this.ads = ads; this.volume = volume; this.clock = clock;
      this.active = false; this.busy = false; this.record = null;
      this.attempts = new Set(); this.results = []; this.message = "Watching for a native ad";
      this.ownsMute = false;
      this.originalSpeed = null;
    }
    isAd(state) {
      return state?.item?.type === "ad" && typeof state.item.uri === "string" &&
        state.item.uri.startsWith("spotify:ad:");
    }
    start() { this.active = true; }
    tick() {
      if (!this.active) return;
      const state = this.player.getState();
      const uri = this.isAd(state) ? state.item.uri : null;
      if (this.record && uri !== this.record.uri) {
        const record = this.record;
        this.results.push({ mode: record.mode, elapsed: (this.clock() - record.started) / 1000,
          remainingAtAttempt: record.remaining / 1000, advancedTo: this.isAd(state) ? "another-ad" : "content" });
        if (this.results.length > 8) this.results.shift();
        this.record = null;
        this.restoreMute();
        this.restoreSpeed();
        this.attempts.delete(record.uri);
        this.message = record.mode === "skip" ? "Ad transition observed after skip request" : "Ad transition observed";
      }
      if (!uri || state.isPaused || this.busy || this.record || this.attempts.has(uri)) return;
      this.busy = true;
      this.attempts.add(uri);
      if (this.attempts.size > 64) this.attempts.delete(this.attempts.values().next().value);
      const position = Math.max(0, state.positionAsOfTimestamp || 0);
      const elapsed = typeof state.timestamp === "number" ? Math.max(0, Date.now() - state.timestamp) : 0;
      const remaining = Math.max(0, state.duration - position - elapsed);
      this.record = { uri, started: this.clock(), remaining, mode: "checking",
        originalSpeed: Number.isFinite(state.speedEsperanto) ? state.speedEsperanto : 1 };
      try {
        if (!this.volume.isMuted()) { this.volume.mute(); this.ownsMute = true; }
      } catch { this.message = "Mute control unavailable"; }
      this.attemptSpeed(uri);
    }
    async attemptSpeed(uri) {
      const originalSpeed = this.record?.originalSpeed ?? 1;
      try {
        await this.player.setSpeed(10);
        this.originalSpeed = originalSpeed;
        const current = this.player.getState();
        if (this.active && this.record?.uri === uri && this.isAd(current) && current.item.uri === uri) {
          this.record.mode = "speed-requested";
          this.message = "Native 10× requested; completion is not yet verified";
        } else await this.restoreSpeed();
      } catch {
        const current = this.player.getState();
        // Recheck after the asynchronous speed command. The ad may have ended
        // naturally while the rejected command was in flight.
        if (this.active && this.record?.uri === uri && this.isAd(current) &&
            current.item.uri === uri && !current.isPaused) {
          this.record.mode = "skip";
          this.message = "Native 10× rejected; requested ad-specific skip";
          try { this.ads.skipToNext(); }
          catch { this.message = "Ad-specific skip unavailable"; this.record.mode = "failed"; }
        }
      } finally { this.busy = false; }
    }
    restoreMute() {
      if (this.ownsMute) {
        try { if (this.volume.isMuted()) this.volume.unmute(); } catch { /* Renderer may be closing. */ }
      }
      this.ownsMute = false;
    }
    async restoreSpeed() {
      const original = this.originalSpeed;
      this.originalSpeed = null;
      if (original === null) return;
      try {
        if (this.player.getState().speedEsperanto === 10) await this.player.setSpeed(original);
      } catch { this.message = "Speed restoration could not be confirmed; reopen Spotify normally"; }
    }
    async stop() {
      this.active = false;
      this.restoreMute();
      this.message = "Stopped";
      await this.restoreSpeed();
    }
    status() {
      return { active: this.active, pending: this.busy, message: this.message,
        ownsMute: this.ownsMute, results: this.results.map(result => ({ ...result })) };
    }
  }
  if (typeof module === "object" && module.exports) {
    module.exports = { NativeAdController }; return;
  }
  const button = document.querySelector('[data-testid="control-button-playpause"]');
  const key = Object.keys(button || {}).find(value => value.startsWith("__reactFiber$"));
  let fiber = button?.[key], player, ads, inspected = 0;
  while (fiber && inspected++ < 500) {
    const value = fiber.memoizedProps?.value;
    if (value && typeof value.resolve === "function") {
      try {
        const candidate = value.resolve(Symbol.for("PlayerAPI"));
        if (typeof candidate?.getState === "function" && typeof candidate?.setSpeed === "function") player = candidate;
      } catch { /* Not the player's registry. */ }
    }
    const connector = value?.adsAPI?.inStreamApi?.adsCoreConnector;
    if (connector && typeof connector.skipToNext === "function") ads = connector;
    fiber = fiber.return;
  }
  if (!player || !ads) throw Error("Native player/ad controls unavailable; nothing was changed.");
  const muteButton = () => document.querySelector('[data-testid="volume-bar-toggle-mute-button"]');
  const volume = {
    isMuted: () => Number(document.querySelector('[data-testid="volume-bar"] input')?.value) === 0,
    mute: () => {
      const button = muteButton();
      if (!button || button.disabled) throw Error("Mute unavailable");
      if (!volume.isMuted()) button.click();
    },
    unmute: () => { if (volume.isMuted()) muteButton()?.click(); },
  };
  const controller = new NativeAdController(player, ads, volume);
  controller.start();
  const timer = setInterval(() => controller.tick(), 150);
  root.BezelNativeAdTest = Object.freeze({
    status: () => controller.status(),
    stop: () => { clearInterval(timer); return controller.stop(); },
  });
})(typeof window === "object" ? window : globalThis);
