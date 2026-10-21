// <pa-player>: instrument's clip player, on the conversation's wall clock. The scrubber shows the clip's
// window with speech as lane-colored bars (whether someone spoke, never a made-up amplitude), quiet as dots,
// the watch's pause as stripes, and missing audio as a full-height amber hatch. Under it a lane per voice
// lights the turn being spoken. Missing audio is skipped and said so; quiet the audio still holds can be
// skipped with one tap. The viewer page and the clip-player widget both use it.
//
//   player.model  = { startMs, tz, dur, span: [a, b], t, lanes: [{ name, cls }], turns: [[lane, s, e]], gaps: [{ k, s, e }], holes?: [{ k, s, e }] }
//   player.source = { url, covered: [c0, c1], lost: [[s, e]], quiet?: [[s, e]], durationMs }   (seconds from the conversation's start)
//
// `gaps` are what the scrubber draws: the rows the phone's transcript shows, which are for reading — an interruption
// row covers minutes of brief drops with the audio between them intact, and a quiet row can hold stored silence. They
// never place audio on the clock. What does is where the audio really has none: the clip's own `lost` and `quiet`
// (X-Clip-Gaps), and for an older phone's conversation `holes`, its gap records as they were sent.
//   player.setState({ head, line, action, busy })   when there is no audio to play; null clears it
//   player.cueAt(t, play)
// Events: `pa-time` { t, playing, turn } as it plays or moves; `pa-action` when the state's button is pressed.

import { clock, dayPeriod, duration, elapsed, esc } from './format.js';

const PL_ICON = {
  play: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5.5v13a1 1 0 0 0 1.5.86l10.2-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5z" fill="currentColor"/></svg>',
  pause: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="6.5" y="5" width="4" height="14" rx="1.2" fill="currentColor"/><rect x="13.5" y="5" width="4" height="14" rx="1.2" fill="currentColor"/></svg>',
  back: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3"/><path d="M4 4.5v3.5h3.5"/><text x="12" y="15.6" text-anchor="middle" font-size="7.5" font-weight="700" fill="currentColor" stroke="none" font-family="-apple-system,system-ui,sans-serif">10</text></svg>',
  fwd: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3"/><path d="M20 4.5v3.5h-3.5"/><text x="12" y="15.6" text-anchor="middle" font-size="7.5" font-weight="700" fill="currentColor" stroke="none" font-family="-apple-system,system-ui,sans-serif">10</text></svg>',
};
const SVG_NS = 'http://www.w3.org/2000/svg';
// The phone's thresholds for a transcript row: an interruption from 10 s, quiet from 30 s.
const NOTE_LOST_SECONDS = 10, NOTE_QUIET_SECONDS = 30;
const clampTo = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

/** Merges intervals [[s, e, kind]] that touch or overlap, keeping the first kind. */
function mergeHoles(holes) {
  const sorted = holes.filter((h) => h[1] > h[0]).sort((x, y) => x[0] - y[0]);
  const out = [];
  for (const h of sorted) {
    const last = out[out.length - 1];
    if (last && h[0] <= last[1]) {
      last[1] = Math.max(last[1], h[1]);
      if (h[2] === 'lost') last[2] = 'lost';
    } else out.push([...h]);
  }
  return out;
}

let playerCount = 0;

class PaPlayer extends HTMLElement {
  constructor() {
    super();
    this._id = `pl${++playerCount}`;
    this._raf = 0;
    this._active = -2;
    this._noteTimer = 0;
    this._wall = 0;
  }

  connectedCallback() {
    if (!this.$) this.build();
  }

  disconnectedCallback() {
    cancelAnimationFrame(this._raf);
    this._ro?.disconnect();
  }

  set model(m) {
    if (!this.$) this.build();
    this._m = m;
    this.a = m.span[0];
    this.b = Math.max(m.span[1], m.span[0] + 1);
    this._wall = clampTo(m.t ?? this.a, this.a, this.b);
    this._W = 0;
    this.draw();
  }

  get model() {
    return this._m;
  }

  /** The audio to play, or null for none. Times are seconds from the conversation's start. */
  set source(src) {
    if (!this.$) this.build();
    this.pause(true);
    this._src = src;
    const audio = this.$.audio;
    if (!src) {
      audio.removeAttribute('src');
      audio.load();
      this.$.root.classList.add('no-audio');
      return;
    }
    this.setState(null);
    this.$.root.classList.remove('no-audio');
    this._c0 = src.covered?.[0] ?? this.a;
    this._c1 = src.covered?.[1] ?? this.b;
    this.mapFor(src.durationMs ? src.durationMs / 1000 : null);
    audio.src = src.url;
    this.paint(true);
  }

  /** Draws again, for a change of size the element itself cannot see (docking). */
  redraw() {
    this._W = 0;
    this.draw();
  }

  get playing() {
    return !!this._playing;
  }

  /** When there is nothing to play: a heading, at most one line, and an optional button. */
  setState(state) {
    if (!this.$) this.build();
    const box = this.$.state;
    if (!state) { box.hidden = true; return; }
    this.$.root.classList.add('no-audio');
    box.hidden = false;
    box.classList.toggle('busy', !!state.busy);
    box.querySelector('.pl-state-head').textContent = state.head || '';
    box.querySelector('.pl-state-line').textContent = state.line || '';
    const action = box.querySelector('.pl-action');
    action.hidden = !state.action;
    action.textContent = state.action || '';
  }

  build() {
    this.innerHTML = `
      <div class="pl no-audio">
        <div class="pl-top"><span class="pl-label">Clip</span><span class="pl-range"></span></div>
        <div class="pl-scrub" role="slider" tabindex="0" aria-label="Position in the clip" aria-valuemin="0">
          <div class="pl-wave"></div>
          <div class="pl-lanes"></div>
          <div class="pl-head" aria-hidden="true"><span></span></div>
        </div>
        <div class="pl-axis" aria-hidden="true"></div>
        <div class="pl-bar">
          <button type="button" class="pl-play" aria-label="Play">${PL_ICON.play}</button>
          <div class="pl-read"><div class="pl-clock"></div><div class="pl-pos"></div></div>
          <div class="pl-skip">
            <button type="button" class="pl-icon" data-skip="-10" aria-label="Back 10 seconds">${PL_ICON.back}</button>
            <button type="button" class="pl-icon" data-skip="10" aria-label="Forward 10 seconds">${PL_ICON.fwd}</button>
          </div>
        </div>
        <div class="pl-note" role="status" aria-live="polite"></div>
        <div class="pl-state" hidden>
          <p class="pl-state-head"></p>
          <p class="pl-state-line"></p>
          <button type="button" class="pl-action" hidden></button>
        </div>
        <audio preload="metadata"></audio>
      </div>`;
    const q = (s) => this.querySelector(s);
    this.$ = {
      root: q('.pl'), range: q('.pl-range'), scrub: q('.pl-scrub'), wave: q('.pl-wave'), lanes: q('.pl-lanes'),
      head: q('.pl-head'), axis: q('.pl-axis'), play: q('.pl-play'), clock: q('.pl-clock'), pos: q('.pl-pos'),
      note: q('.pl-note'), state: q('.pl-state'), audio: q('audio'),
    };
    this.$.play.addEventListener('click', () => this.toggle());
    this.querySelectorAll('[data-skip]').forEach((b) => b.addEventListener('click', () => this.seek(this._wall + Number(b.dataset.skip))));
    q('.pl-action').addEventListener('click', () => this.dispatchEvent(new CustomEvent('pa-action', { bubbles: true })));
    const audio = this.$.audio;
    audio.addEventListener('loadedmetadata', () => {
      if (!this._src?.durationMs && Number.isFinite(audio.duration)) this.mapFor(audio.duration);
      // A seek asked for before the file's length was known is placed again with the mapping it gives.
      if (this._pendingSeek) { audio.currentTime = this.audioAt(this._wall); this._pendingSeek = false; }
    });
    audio.addEventListener('ended', () => this.pause());
    audio.addEventListener('error', () => {
      if (!this._src) return;
      this._src = null;
      this.pause(true);
      this.setState({ head: "This clip didn't load", line: 'The link may have expired. Reload the page for a new one.' });
    });
    // While the page is hidden there are no animation frames; the clock still moves.
    audio.addEventListener('timeupdate', () => { if (this._playing && document.hidden) this.tick(); });
    this.bindScrub();
    this._ro = new ResizeObserver(() => this.draw());
    this._ro.observe(this.$.scrub);
  }

  // ── The audio's own time and the conversation's wall clock ─────────────
  // A clip is remuxed from the stored audio, which has no audio for quiet the watch skipped, its pauses, or
  // what was lost. Whether those stretches are cut out of the file or kept as silence is read from its length.

  mapFor(audioSeconds) {
    const m = this._m;
    const holes = [];
    for (const g of m.holes ?? []) if (g.k === 'lost' || g.k === 'quiet' || g.k === 'paused') holes.push([Math.max(g.s, this._c0), Math.min(g.e, this._c1), g.k]);
    for (const [s, e] of this._src?.lost ?? []) holes.push([Math.max(s, this._c0), Math.min(e, this._c1), 'lost']);
    for (const [s, e] of this._src?.quiet ?? []) holes.push([Math.max(s, this._c0), Math.min(e, this._c1), 'quiet']);
    this._holes = mergeHoles(holes);
    const span = this._c1 - this._c0;
    const lost = this._holes.filter((h) => h[2] === 'lost').reduce((x, h) => x + h[1] - h[0], 0);
    const all = this._holes.reduce((x, h) => x + h[1] - h[0], 0);
    let mode = 'linear';
    if (audioSeconds) {
      const fits = [['linear', span], ['cutLost', span - lost], ['cutAll', span - all]];
      mode = fits.sort((x, y) => Math.abs(x[1] - audioSeconds) - Math.abs(y[1] - audioSeconds))[0][0];
    }
    this._mode = mode;
    const removed = mode === 'linear' ? [] : this._holes.filter((h) => mode === 'cutAll' || h[2] === 'lost');
    this._segments = [];
    let w = this._c0, at = 0;
    for (const h of removed) {
      if (h[0] > w) { this._segments.push({ w0: w, w1: h[0], a0: at }); at += h[0] - w; }
      w = Math.max(w, h[1]);
    }
    if (this._c1 > w) this._segments.push({ w0: w, w1: this._c1, a0: at });
  }

  wallAt(audioT) {
    const segs = this._segments || [];
    for (const s of segs) if (audioT < s.a0 + (s.w1 - s.w0)) return s.w0 + Math.max(0, audioT - s.a0);
    return segs.length ? segs[segs.length - 1].w1 : this._c0;
  }

  audioAt(wall) {
    for (const s of this._segments || []) {
      if (wall < s.w0) return s.a0;
      if (wall < s.w1) return s.a0 + (wall - s.w0);
    }
    const last = (this._segments || []).at(-1);
    return last ? last.a0 + (last.w1 - last.w0) : 0;
  }

  holeAt(wall) {
    return (this._holes || []).find((h) => wall >= h[0] && wall < h[1]);
  }

  // ── Drawing ────────────────────────────────────────────────────────────

  draw() {
    const m = this._m;
    if (!m || !this.$) return;
    const W = Math.max(120, Math.round(this.$.scrub.clientWidth));
    if (W === this._W) return this.paint(true);
    this._W = W;
    // With nothing to draw and nothing to play, the scrubber is not shown at all.
    this.$.root.classList.toggle('empty', !m.turns.length && !m.gaps.length);
    const docked = this.hasAttribute('docked');
    const H = docked ? 32 : 56;
    const a = this.a, b = this.b, span = b - a;
    const X = (t) => ((clampTo(t, a, b) - a) / span) * W;
    const pitch = 3, barW = 2, n = Math.max(8, Math.floor(W / pitch)), step = span / n;
    const lanes = m.lanes.length ? m.lanes : [{ cls: 's0' }];
    const paths = { room: '', masked: '' };
    lanes.forEach((l) => { paths[l.cls] = paths[l.cls] || ''; });
    const gapAt = (t) => m.gaps.find((g) => t >= g.s && t < g.e);
    const speechH = Math.round(H * 0.6), mid = H / 2;
    for (let i = 0; i < n; i++) {
      const t0 = a + i * step, t1 = t0 + step, tc = (t0 + t1) / 2;
      const g = gapAt(tc);
      if (g && g.k !== 'masked') continue;
      const x = (i * pitch + barW / 2).toFixed(1);
      if (g) { paths.masked += `M${x} ${(mid - H * 0.15).toFixed(1)}v${(H * 0.3).toFixed(1)}`; continue; }
      const cover = new Map();
      for (const [l, s, e] of m.turns) {
        const o = Math.min(e, t1) - Math.max(s, t0);
        if (o > 0) cover.set(l, (cover.get(l) || 0) + o);
      }
      if (!cover.size) continue;
      const lane = [...cover.entries()].sort((p, q) => q[1] - p[1])[0][0];
      const cls = lanes[Math.min(lane, lanes.length - 1)].cls;
      paths[cls] += `M${x} ${(mid - speechH / 2).toFixed(1)}v${speechH}`;
    }
    // Between turns the audio is room sound: a hairline under the speech, broken where there is no audio.
    let w0 = a;
    paths.room = '';
    for (const g of [...m.gaps].filter((x) => x.k !== 'masked' && x.e > a && x.s < b).sort((x, y) => x.s - y.s)) {
      if (g.s > w0) paths.room += `M${X(w0).toFixed(1)} ${mid}H${X(g.s).toFixed(1)}`;
      w0 = Math.max(w0, g.e);
    }
    if (w0 < b) paths.room += `M${X(w0).toFixed(1)} ${mid}H${W}`;
    const bars = () => Object.entries(paths).map(([cls, d]) => (d ? `<path class="b-${cls}" d="${d}" fill="none" stroke-width="${cls === 'room' ? 1 : barW}"/>` : '')).join('');
    let marks = '';
    for (const g of m.gaps) {
      if (g.e <= a || g.s >= b || g.k === 'masked') continue;
      const x0 = X(g.s), x1 = X(g.e), w = Math.max(2, x1 - x0);
      if (g.k === 'quiet') {
        marks += `<line class="w-quiet" x1="${(x0 + 3).toFixed(1)}" x2="${Math.max(x0 + 3, x0 + w - 3).toFixed(1)}" y1="${mid}" y2="${mid}"/>`;
        if (!docked && w > 64) marks += `<text class="w-label" x="${(x0 + w / 2).toFixed(1)}" y="${mid - 9}">Quiet</text>`;
      } else if (g.k === 'paused') {
        marks += `<rect fill="url(#${this._id}-p)" x="${x0.toFixed(1)}" y="${(H * 0.3).toFixed(1)}" width="${w.toFixed(1)}" height="${(H * 0.4).toFixed(1)}" rx="2"/>`;
        if (!docked && w > 64) marks += `<text class="w-label" x="${(x0 + w / 2).toFixed(1)}" y="${(H * 0.3 - 5).toFixed(1)}">Paused</text>`;
      } else {
        marks += `<rect class="w-lost-bg" x="${x0.toFixed(1)}" y="0" width="${w.toFixed(1)}" height="${H}"/><rect fill="url(#${this._id}-h)" x="${x0.toFixed(1)}" y="0" width="${w.toFixed(1)}" height="${H}"/>`;
        marks += `<line class="w-lost-edge" x1="${(x0 + 1).toFixed(1)}" x2="${(x0 + 1).toFixed(1)}" y1="0" y2="${H}"/><line class="w-lost-edge" x1="${(x0 + w - 1).toFixed(1)}" x2="${(x0 + w - 1).toFixed(1)}" y1="0" y2="${H}"/>`;
        if (!docked && w > 64) marks += `<text class="w-label lost" x="${(x0 + w / 2).toFixed(1)}" y="${mid + 4}">Missing</text>`;
      }
    }
    this.$.wave.innerHTML = `<svg xmlns="${SVG_NS}" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" aria-hidden="true" focusable="false">
      <defs>
        <pattern id="${this._id}-h" width="5" height="5" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect class="hatch-ink" width="2" height="5"/></pattern>
        <pattern id="${this._id}-p" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="6" height="6" style="fill:var(--paused-ground)"/><rect class="paused-ink" width="2" height="6"/></pattern>
        <clipPath id="${this._id}-c"><rect class="pl-cliprect" x="0" y="0" width="0" height="${H}"/></clipPath>
      </defs>
      <g class="pl-unplayed">${bars()}</g>
      <g clip-path="url(#${this._id}-c)">${bars()}</g>
      ${marks}
    </svg>`;
    this.$.clipRect = this.$.wave.querySelector('.pl-cliprect');

    // Lanes: who spoke when.
    const laneH = docked ? 3 : 4, laneGap = 2;
    let rects = '';
    m.turns.forEach(([l, s, e], i) => {
      if (e <= a || s >= b) return;
      const cls = lanes[Math.min(l, lanes.length - 1)].cls;
      const x0 = X(s), x1 = X(e);
      rects += `<rect class="ln-${cls}" data-i="${i}" x="${x0.toFixed(1)}" y="${l * (laneH + laneGap)}" width="${Math.max(1.5, x1 - x0 - 0.5).toFixed(1)}" height="${laneH}" rx="1"/>`;
    });
    const LH = lanes.length * (laneH + laneGap) - laneGap;
    this.$.lanes.innerHTML = `<svg xmlns="${SVG_NS}" viewBox="0 0 ${W} ${LH}" width="${W}" height="${LH}" aria-hidden="true" focusable="false">${rects}</svg>`;
    this._active = -2;

    // Axis: ticks on the wall clock, a label on each minute (or every few on long clips).
    const wall0 = m.startMs + a * 1000, wall1 = m.startMs + b * 1000;
    const tickStep = span <= 180 ? 15 : span <= 600 ? 30 : span <= 1800 ? 60 : 300;
    const labelEvery = [60, 120, 300, 600, 900, 1800].find((s) => span / s <= Math.max(3, W / 90)) || 1800;
    let ax = '';
    for (let w = Math.ceil(wall0 / (tickStep * 1000)) * tickStep * 1000; w <= wall1; w += tickStep * 1000) {
      const x = ((w - wall0) / (wall1 - wall0)) * 100;
      const major = (w / 1000) % labelEvery === 0;
      ax += `<span class="tick${major ? ' major' : ''}" style="left:${x.toFixed(2)}%"></span>`;
      if (major && x > 6 && x < 94) ax += `<span class="tick-label" style="left:${x.toFixed(2)}%">${clock(w, m.tz, { period: false })}</span>`;
    }
    this.$.axis.innerHTML = ax;
    this.$.range.textContent = `${clock(wall0, m.tz)} – ${clock(wall1, m.tz)}`;
    this.$.scrub.setAttribute('aria-valuemax', String(Math.round(span)));
    this.paint(true);
  }

  paint(force) {
    const m = this._m;
    if (!m || !this.$) return;
    const span = this.b - this.a, w = this._wall, p = (w - this.a) / span;
    if (this.$.clipRect) this.$.clipRect.setAttribute('width', (p * (this._W || 0)).toFixed(1));
    this.$.head.style.left = `${(clampTo(p, 0, 1) * 100).toFixed(3)}%`;
    const wallMs = m.startMs + w * 1000;
    this.$.clock.innerHTML = `${esc(clock(wallMs, m.tz, { seconds: true, period: false }))}<span class="ap">${esc(dayPeriod(wallMs, m.tz))}</span>`;
    this.$.pos.textContent = `${elapsed(w - this.a)} / ${elapsed(span)}`;
    this.$.scrub.setAttribute('aria-valuenow', String(Math.round(w - this.a)));
    this.$.scrub.setAttribute('aria-valuetext', `${clock(wallMs, m.tz, { seconds: true })}, ${elapsed(w - this.a)} of ${elapsed(span)}`);
    const i = this.turnAt(w);
    if (i !== this._active || force) {
      this.$.lanes.querySelector('rect.on')?.classList.remove('on');
      if (i >= 0) this.$.lanes.querySelector(`rect[data-i="${i}"]`)?.classList.add('on');
      this._active = i;
    }
  }

  turnAt(t) {
    const turns = this._m.turns;
    let found = -1;
    for (let i = 0; i < turns.length; i++) {
      if (turns[i][1] > t) break;
      if (t <= turns[i][2] + 0.6) found = i;
    }
    return found;
  }

  emit() {
    this.dispatchEvent(new CustomEvent('pa-time', { bubbles: true, detail: { t: this._wall, playing: this.playing, turn: this._active } }));
  }

  // ── Playing ────────────────────────────────────────────────────────────

  bindScrub() {
    const s = this.$.scrub;
    const at = (e) => {
      const r = s.getBoundingClientRect();
      return this.a + clampTo((e.clientX - r.left) / r.width, 0, 1) * (this.b - this.a);
    };
    let dragging = false;
    s.addEventListener('pointerdown', (e) => {
      if (!this._src) return;
      dragging = true;
      s.setPointerCapture?.(e.pointerId);
      s.classList.add('is-drag');
      this.seek(at(e));
    });
    s.addEventListener('pointermove', (e) => { if (dragging) this.seek(at(e)); });
    const end = () => { dragging = false; s.classList.remove('is-drag'); };
    s.addEventListener('pointerup', end);
    s.addEventListener('pointercancel', end);
    s.addEventListener('keydown', (e) => {
      if (!this._src) return;
      const moves = { ArrowRight: 5, ArrowUp: 5, ArrowLeft: -5, ArrowDown: -5, PageUp: 15, PageDown: -15 };
      if (e.key in moves) { e.preventDefault(); this.seek(this._wall + moves[e.key]); }
      else if (e.key === 'Home') { e.preventDefault(); this.seek(this.a); }
      else if (e.key === 'End') { e.preventDefault(); this.seek(this.b); }
      else if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); this.toggle(); }
    });
  }

  /** Moves to conversation time t inside the clip; outside the audio it lands on the nearest audio. */
  seek(t) {
    const lo = this._src ? this._c0 : this.a, hi = this._src ? this._c1 : this.b;
    this._wall = clampTo(t, lo, hi);
    const hole = this._src && this._mode !== 'linear' ? this.holeAt(this._wall) : null;
    if (hole && (this._mode === 'cutAll' || hole[2] === 'lost')) this._wall = Math.min(hole[1], hi);
    if (this._src) {
      const target = this.audioAt(this._wall);
      if (this.$.audio.readyState >= 1) this.$.audio.currentTime = target;
      else this._pendingSeek = true;
    }
    this._quiet = null;
    this.note('');
    this.paint();
    this.emit();
  }

  /** Moves to t (and plays when asked and there is audio). */
  cueAt(t, play) {
    this.seek(t);
    if (play && this._src) this.play();
  }

  toggle() {
    this.playing ? this.pause() : this.play();
  }

  async play() {
    if (!this._src) return;
    if (this._wall >= Math.min(this.b, this._c1) - 0.3) this.seek(this._c0);
    if (this.$.audio.readyState < 1) this._pendingSeek = true;
    try {
      await this.$.audio.play();
    } catch {
      return;
    }
    // One player plays at a time, here and in any other widget of this connector.
    PaPlayer.channel?.postMessage({ playing: this._id });
    this._playing = true;
    this.$.play.innerHTML = PL_ICON.pause;
    this.$.play.setAttribute('aria-label', 'Pause');
    this.classList.add('is-playing');
    this._last = this._wall;
    cancelAnimationFrame(this._raf);
    const loop = () => {
      if (!this._playing) return;
      this.tick();
      this._raf = requestAnimationFrame(loop);
    };
    this._raf = requestAnimationFrame(loop);
    this.emit();
  }

  pause(quiet) {
    const wasPlaying = this._playing;
    this._playing = false;
    cancelAnimationFrame(this._raf);
    if (this.$) {
      this.$.audio.pause();
      this.$.play.innerHTML = PL_ICON.play;
      this.$.play.setAttribute('aria-label', 'Play');
    }
    this.classList.remove('is-playing');
    if (!quiet && wasPlaying) { this.paint(true); this.emit(); }
  }

  tick() {
    const audio = this.$.audio;
    let w = this.wallAt(audio.currentTime);
    const before = this._last ?? w;
    // Only what the phone's transcript would give a row is said out loud: a drop under 10 s is skipped without a word
    // (the watch can drop a fraction of a second every two seconds), and quiet under 30 s is not worth a button.
    const said = (h) => h[1] - h[0] >= (h[2] === 'lost' ? NOTE_LOST_SECONDS : NOTE_QUIET_SECONDS);
    if (this._mode === 'linear') {
      const hole = this.holeAt(w);
      if (hole?.[2] === 'lost') {
        audio.currentTime = this.audioAt(hole[1]);
        w = hole[1];
        if (said(hole)) this.note(`Skipped ${duration(hole[1] - hole[0], { seconds: true })} of missing audio`, 'missing', 3600);
      } else if (hole && this._quiet !== hole && said(hole)) {
        this._quiet = hole;
        this.offerSkip(hole);
      } else if (!hole && this._quiet) {
        this._quiet = null;
        this.note('');
      }
    } else {
      for (const h of this._holes || []) {
        if (before < h[1] && w >= h[1] && before <= h[0] + 0.5 && (this._mode === 'cutAll' || h[2] === 'lost') && said(h)) {
          this.note(h[2] === 'lost'
            ? `Skipped ${duration(h[1] - h[0], { seconds: true })} of missing audio`
            : `Skipped ${duration(h[1] - h[0], { seconds: true })} of quiet`, h[2] === 'lost' ? 'missing' : '', 3600);
        }
      }
    }
    this._last = w;
    this._wall = w;
    if (w >= Math.min(this.b, this._c1) - 0.05 || audio.ended) {
      this._wall = Math.min(this.b, this._c1);
      this.pause();
      return;
    }
    this.paint();
    this.emit();
  }

  offerSkip(hole) {
    clearTimeout(this._noteTimer);
    const n = this.$.note;
    n.className = 'pl-note on';
    n.innerHTML = `<span><i class="g"></i>${esc(hole[2] === 'paused' ? 'Paused' : 'Quiet')} for ${esc(duration(hole[1] - hole[0], { seconds: true }))}</span><button type="button">Skip quiet</button>`;
    n.querySelector('button').addEventListener('click', () => {
      this.seek(hole[1]);
      if (!this.playing) this.play();
    });
  }

  note(text, tone = '', ms = 0) {
    clearTimeout(this._noteTimer);
    const n = this.$.note;
    n.textContent = text;
    n.className = `pl-note${text ? ' on' : ''}${tone ? ' ' + tone : ''}`;
    if (ms) this._noteTimer = setTimeout(() => this.note(''), ms);
  }
}

try {
  PaPlayer.channel = new BroadcastChannel('pebble-audio-player');
  PaPlayer.channel.addEventListener('message', (e) => {
    for (const p of document.querySelectorAll('pa-player')) if (p._id !== e.data?.playing && p.playing) p.pause();
  });
} catch {
  PaPlayer.channel = null;
}

if (!customElements.get('pa-player')) customElements.define('pa-player', PaPlayer);
