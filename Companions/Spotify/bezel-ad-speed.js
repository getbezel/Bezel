/* Bezel Spotify companion — experimental, local, no network or account access. */
(function installBezelAdSpeed(root) {
  "use strict";
  if (root.BezelAdSpeed) return;

  // This controller deliberately reports a REQUEST until the media timeline
  // advances. A rate setter accepting 10 is not evidence of faster playback.
  class AdSpeedController {
    constructor(clock = () => performance.now()) {
      this.clock = clock;
      this.enabled = true;
      this.active = false;
      this.records = new Map();
      this.overrides = new WeakSet();
      this.changedSources = new WeakSet();
      this.completed = [];
      this.message = "Waiting for an ad";
    }

    reconcile(isAd, media) {
      if (!this.enabled || !isAd) {
        this.restore();
        this.active = false;
        this.overrides = new WeakSet();
        this.changedSources = new WeakSet();
        this.message = this.enabled ? "Waiting for an ad" : "Off";
        return;
      }
      this.active = true;
      const candidates = new Set(media);
      for (const [element, record] of this.records) {
        const source = element.currentSrc || element.src || "";
        if (!candidates.has(element) || source !== record.source) {
          this.restoreElement(element, record);
          this.records.delete(element);
        }
      }
      for (const element of candidates) {
        if (this.overrides.has(element) || this.changedSources.has(element)) continue;
        const old = this.records.get(element);
        if (old) {
          if (!element.muted) {
            // A user unmuting the ad takes precedence; do not fight the slider.
            this.restoreElement(element, old);
            this.records.delete(element);
            this.overrides.add(element);
          }
          continue;
        }
        if (element.paused || element.ended || element.loop ||
            !Number.isFinite(element.duration) || element.duration <= 0 ||
            !Number.isFinite(element.currentTime) || element.readyState < 2) continue;
        const record = {
          source: element.currentSrc || element.src || "",
          muted: element.muted,
          rate: element.playbackRate,
          started: this.clock(),
          position: element.currentTime,
          duration: element.duration,
          requested: false,
          measured: null,
        };
        this.records.set(element, record);
        try {
          element.muted = true;
          element.playbackRate = 10;
          record.requested = element.playbackRate === 10;
        } catch {
          // Unsupported rates still leave the ad silent; status says so.
          record.requested = false;
        }
      }
      this.sample();
    }

    sample() {
      if (!this.active) return this.status();
      let fastest = null;
      for (const [element, record] of this.records) {
        const seconds = (this.clock() - record.started) / 1000;
        const advance = element.currentTime - record.position;
        if (!element.paused && seconds >= 0.8 && advance >= 0 &&
            element.playbackRate === 10 && record.requested) {
          // Read real media currentTime; never extrapolate from requested rate.
          record.measured = advance / seconds;
          if (record.measured >= 7 && record.measured <= 13) fastest = record.measured;
        }
      }
      this.message = fastest !== null ? `Muted · measured ${fastest.toFixed(1)}×` :
        this.records.size ? "Muted · 10× requested, checking progress" :
        "Ad detected · no controllable media element";
      return this.status();
    }

    ended(element) {
      const record = this.records.get(element);
      if (!record) return;
      const elapsed = (this.clock() - record.started) / 1000;
      const played = element.currentTime - record.position;
      // An ended event counts only if the media actually reached its duration.
      if (element.ended && element.currentTime >= record.duration - 0.15 && elapsed > 0) {
        this.completed.push({ elapsed, played, effectiveRate: played / elapsed });
        if (this.completed.length > 8) this.completed.shift();
      }
      this.restoreElement(element, record);
      this.records.delete(element);
    }

    sourceChanged(element) {
      const record = this.records.get(element);
      if (record) this.restoreElement(element, record);
      // Ad UI can linger after the next song starts. Never carry acceleration
      // onto a new source based solely on the old ad controls still being drawn.
      if (record && this.active) this.changedSources.add(element);
      this.records.delete(element);
      this.overrides.delete(element);
    }

    restoreElement(element, record) {
      try {
        // Preserve deliberate user changes made while the ad was playing.
        if (element.playbackRate === 10) element.playbackRate = record.rate;
        if (element.muted === true) element.muted = record.muted;
      } catch { /* An already destroyed player cannot retain these settings. */ }
    }

    restore() {
      for (const [element, record] of this.records) this.restoreElement(element, record);
      this.records.clear();
    }

    setEnabled(value) {
      this.enabled = value === true;
      if (!this.enabled) this.reconcile(false, []);
      return this.status();
    }

    status() {
      return {
        enabled: this.enabled, adDetected: this.active, message: this.message,
        controlledElements: this.records.size,
        completed: this.completed.map(value => ({ ...value })),
      };
    }
  }

  if (typeof module === "object" && module.exports) {
    module.exports = { AdSpeedController };
    return;
  }
  const controller = new AdSpeedController();
  const tracked = new Set();
  const listeners = new Map();
  let stopped = false;
  let timer;
  let scheduled = false;
  const selectors = [
    '[data-testid="ad-controls"]', '[data-testid="ad-countdown-timer"]',
    '[data-testid="ads-video-player-npv"]', '[data-testid="standalone-video-ad-player"]',
    '[data-testid="canvas-ad-player"]',
  ].join(",");

  function detectAd() {
    // A song called “Advertisement” is not an ad. Do not inspect page titles.
    const uri = root.Spicetify?.Player?.data?.item?.uri;
    if (typeof uri === "string" && uri.startsWith("spotify:")) {
      return uri.startsWith("spotify:ad:");
    }
    return document.querySelector(selectors) !== null;
  }

  function track(element) {
    if (tracked.has(element) || tracked.size >= 64) return;
    tracked.add(element);
    const ended = () => { controller.ended(element); schedule(); };
    const source = () => { controller.sourceChanged(element); schedule(); };
    const change = () => schedule();
    element.addEventListener("ended", ended);
    element.addEventListener("loadstart", source);
    for (const name of ["playing", "pause", "loadeddata", "ratechange", "volumechange"]) {
      element.addEventListener(name, change);
    }
    listeners.set(element, { ended, source, change });
  }

  function untrack(element) {
    controller.sourceChanged(element);
    const item = listeners.get(element);
    if (item) {
      element.removeEventListener("ended", item.ended);
      element.removeEventListener("loadstart", item.source);
      for (const name of ["playing", "pause", "loadeddata", "ratechange", "volumechange"]) {
        element.removeEventListener(name, item.change);
      }
    }
    listeners.delete(element);
    tracked.delete(element);
  }

  function tick() {
    if (stopped) return;
    for (const element of tracked) {
      // Chromium queues pause before ended. Its pause handler can run our tick
      // after ended becomes true but before the ended callback is dispatched.
      if (element.ended) { controller.ended(element); untrack(element); }
      else if (element.paused && !element.isConnected) untrack(element);
    }
    document.querySelectorAll("audio, video").forEach(track);
    controller.reconcile(detectAd(), tracked);
    clearTimeout(timer);
    timer = setTimeout(tick, controller.active ? 150 : 1500);
  }

  function schedule() {
    if (scheduled || stopped) return;
    scheduled = true;
    queueMicrotask(() => { scheduled = false; tick(); });
  }

  // Spotify can keep its media elements outside the DOM. Capturing play()
  // finds those without changing creation, src, buffering, DRM, or networking.
  const originalPlay = HTMLMediaElement.prototype.play;
  function play(...args) {
    if (!stopped) { track(this); schedule(); }
    return Reflect.apply(originalPlay, this, args);
  }
  HTMLMediaElement.prototype.play = play;
  const observer = new MutationObserver(schedule);
  observer.observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: ["data-testid"] });
  const pagehide = () => { controller.restore(); };
  root.addEventListener("pagehide", pagehide);
  root.BezelAdSpeed = Object.freeze({
    version: "0.1.0",
    status: () => controller.sample(),
    setEnabled: value => { const result = controller.setEnabled(value); schedule(); return result; },
    stop: () => {
      if (stopped) return;
      stopped = true;
      clearTimeout(timer);
      observer.disconnect();
      root.removeEventListener("pagehide", pagehide);
      controller.restore();
      for (const element of [...tracked]) untrack(element);
      if (HTMLMediaElement.prototype.play === play) HTMLMediaElement.prototype.play = originalPlay;
      controller.enabled = false;
      controller.active = false;
      controller.message = "Stopped";
    },
  });
  tick();
})(typeof window === "object" ? window : globalThis);
