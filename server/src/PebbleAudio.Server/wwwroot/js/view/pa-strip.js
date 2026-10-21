// <pa-strip>: a conversation drawn to scale, one lane per voice (timeline-first's strip). Quiet is a row of
// dots, the watch's power-save pause muted stripes, missing audio a full-height amber hatch — to scale for a hole,
// and a tick where it starts for brief drops spread over a stretch (the app's scrubber tick). It can show the
// clip's window, the moment a link cites, and the playhead; tapping or dragging it, or its arrow keys, asks
// to move there with a `pa-seek` event ({ t } in seconds from the conversation's start).
//
// model: { dur, startMs, tz, lanes: [{ name, cls }], turns: [[lane, s, e]], gaps: [{ k, s, e, label }] }

import { clock, duration } from './format.js';

const STRIP_LANE = 8, STRIP_LANE_COMPACT = 4, STRIP_GAP = 3, STRIP_GAP_COMPACT = 2, STRIP_PAD = 5, STRIP_PAD_COMPACT = 3;

const stripPct = (t, dur) => `${((Math.max(0, Math.min(dur, t)) / dur) * 100).toFixed(3)}%`;

class PaStrip extends HTMLElement {
  constructor() {
    super();
    this._head = null;
  }

  set model(m) {
    this._m = m;
    this.render();
  }

  get model() {
    return this._m;
  }

  connectedCallback() {
    if (!this.hasAttribute('tabindex') && !this.hasAttribute('compact')) this.tabIndex = 0;
    if (!this.hasAttribute('compact')) {
      this.setAttribute('role', 'slider');
      this.setAttribute('aria-valuemin', '0');
      this.addEventListener('keydown', (e) => this.onKey(e));
    }
  }

  render() {
    const m = this._m;
    if (!m) return;
    const compact = this.hasAttribute('compact');
    const laneH = compact ? STRIP_LANE_COMPACT : STRIP_LANE, gap = compact ? STRIP_GAP_COMPACT : STRIP_GAP, pad = compact ? STRIP_PAD_COMPACT : STRIP_PAD;
    const lanes = m.lanes.length ? m.lanes : [{ name: 'Speech', cls: 's0' }];
    const dur = Math.max(1, m.dur);
    this.textContent = '';

    const band = document.createElement('div');
    band.className = 'st-band';
    band.style.height = `${pad * 2 + lanes.length * laneH + (lanes.length - 1) * gap}px`;
    lanes.forEach((lane, li) => {
      const row = document.createElement('div');
      row.className = `st-lane ${lane.cls}`;
      row.style.top = `${pad + li * (laneH + gap)}px`;
      row.style.height = `${laneH}px`;
      let html = '', run = null;
      const flush = () => { if (run) html += `<i style="left:${stripPct(run[0], dur)};width:${stripPct(run[1] - run[0], dur)}"></i>`; };
      for (const [l, s, e] of m.turns) {
        if (l !== li) continue;
        if (run && s - run[1] < 2) run[1] = Math.max(run[1], e);
        else { flush(); run = [s, e]; }
      }
      flush();
      row.innerHTML = html;
      band.append(row);
    });
    for (const g of m.gaps) {
      const cls = { quiet: 'st-quiet', paused: 'st-paused', lost: 'st-lost', masked: 'st-masked' }[g.k];
      if (!cls) continue;
      const d = document.createElement('div');
      d.className = cls;
      d.style.left = stripPct(g.s, dur);
      d.style.width = stripPct(g.e - g.s, dur);
      d.title = g.label || '';
      band.append(d);
    }
    // The window, the pin, and the playhead sit on the band only, never over the times under it.
    const track = document.createElement('div');
    track.className = 'st-track';
    track.append(band);
    this.append(track);

    this.$clip = this.mark(track, 'st-clip');
    this.$pin = this.mark(track, 'st-pin');
    this.$pin.innerHTML = '<span></span>';
    this.$headEl = this.mark(track, 'st-head');

    if (!compact) {
      const ticks = document.createElement('div');
      ticks.className = 'st-ticks';
      ticks.setAttribute('aria-hidden', 'true');
      this.$ticks = ticks;
      this.append(ticks);
      this.layoutTicks();
      // The labels depend on the width: thinned to fit, and laid out again when it changes.
      if (!this._ro) {
        this._ro = new ResizeObserver(() => this.layoutTicks());
        this._ro.observe(this);
      }
      this.setAttribute('aria-label', `Conversation, ${duration(dur)}${this.summary()}`);
      this.setAttribute('aria-valuemax', String(Math.round(dur)));
    }

    this.bindPointer(band);
    if (this._clip) this.setClip(...this._clip);
    if (this._pin) this.setPin(...this._pin);
    this.setHead(this._head);
  }

  mark(parent, cls) {
    const el = document.createElement('div');
    el.className = cls;
    el.hidden = true;
    parent.append(el);
    return el;
  }

  summary() {
    const m = this._m;
    // The page's own total when it gives one: a mark of brief drops is a tick, not their sum.
    const lost = m.missing ?? m.gaps.filter((g) => g.k === 'lost').reduce((a, g) => a + g.e - g.s, 0);
    const quiet = m.gaps.filter((g) => g.k === 'quiet').reduce((a, g) => a + g.e - g.s, 0);
    return (quiet ? `, quiet ${duration(quiet, { seconds: true })}` : '') + (lost ? `, ${duration(lost, { seconds: true })} missing` : '');
  }

  /**
   * The times under the strip: its start and end always, and round times between them, as many as the width holds.
   * The step is thinned to the width first; then every label is measured, and one that would come within a few pixels
   * of the one before it, or of the end, is left out — so no two ever run together ("10:51 AM11:00"), at any width.
   */
  layoutTicks() {
    const m = this._m, el = this.$ticks;
    if (!m || !el) return;
    const width = el.clientWidth || this.clientWidth || 320;
    if (width === this._ticksWidth && el.childElementCount) return;
    this._ticksWidth = width;
    const dur = Math.max(1, m.dur);
    const start = m.startMs;
    const steps = [60, 120, 300, 600, 900, 1800, 3600, 7200];
    // About one label per 72 px, the two ends included.
    const most = Math.max(1, Math.floor(width / 72) - 1);
    const step = steps.find((s) => dur / s <= most) || steps[steps.length - 1];
    let html = `<span>${clock(start, m.tz)}</span>`;
    const first = Math.ceil(start / 1000 / step) * step * 1000;
    for (let w = first; w < start + dur * 1000; w += step * 1000) {
      const f = (w - start) / 1000 / dur;
      if (f <= 0 || f >= 1) continue;
      html += `<span data-mid style="left:${(f * 100).toFixed(2)}%">${clock(w, m.tz, { period: false })}</span>`;
    }
    html += `<span style="left:100%">${clock(start + dur * 1000, m.tz)}</span>`;
    el.innerHTML = html;

    const GAP = 8;
    const spans = [...el.children];
    const box = el.getBoundingClientRect();
    const edges = (s) => { const r = s.getBoundingClientRect(); return [r.left - box.left, r.right - box.left]; };
    const end = edges(spans[spans.length - 1]);
    let right = edges(spans[0])[1];
    for (const span of spans.slice(1, -1)) {
      const [l, r] = edges(span);
      if (l < right + GAP || r > end[0] - GAP) span.remove();
      else right = r;
    }
    // Narrower than both ends: the start alone (hidden rather than removed, so the start keeps its own alignment).
    if (spans.length > 1 && end[0] < edges(spans[0])[1] + GAP) spans[spans.length - 1].style.visibility = 'hidden';
  }

  bindPointer(band) {
    const at = (e) => {
      const r = band.getBoundingClientRect();
      return Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * this._m.dur;
    };
    let dragging = false;
    band.addEventListener('pointerdown', (e) => {
      dragging = true;
      band.setPointerCapture?.(e.pointerId);
      this.seek(at(e), false);
    });
    band.addEventListener('pointermove', (e) => { if (dragging) this.seek(at(e), false); });
    const end = (e) => {
      if (!dragging) return;
      dragging = false;
      this.seek(at(e), true);
    };
    band.addEventListener('pointerup', end);
    band.addEventListener('pointercancel', () => { dragging = false; });
  }

  onKey(e) {
    const t = this._head ?? 0;
    const step = e.shiftKey ? 60 : 10;
    const moves = { ArrowRight: step, ArrowUp: step, ArrowLeft: -step, ArrowDown: -step, PageUp: 60, PageDown: -60 };
    if (e.key in moves) { e.preventDefault(); this.seek(t + moves[e.key], true); }
    else if (e.key === 'Home') { e.preventDefault(); this.seek(0, true); }
    else if (e.key === 'End') { e.preventDefault(); this.seek(this._m.dur, true); }
  }

  seek(t, done) {
    t = Math.max(0, Math.min(this._m.dur, t));
    this.setHead(t);
    this.dispatchEvent(new CustomEvent('pa-seek', { bubbles: true, detail: { t, done } }));
  }

  /** The clip's window; a window that is the whole conversation is not drawn. */
  setClip(a, b) {
    this._clip = [a, b];
    if (!this.$clip) return;
    this.$clip.hidden = a <= 0 && b >= this._m.dur;
    this.$clip.style.left = stripPct(a, this._m.dur);
    this.$clip.style.width = stripPct(b - a, this._m.dur);
  }

  setPin(t, label = '') {
    this._pin = [t, label];
    if (!this.$pin) return;
    this.$pin.hidden = false;
    this.$pin.style.left = stripPct(t, this._m.dur);
    this.$pin.firstChild.textContent = label;
    this.classList.add('has-pin');
  }

  setHead(t) {
    this._head = t;
    if (!this.$headEl) return;
    if (t == null) { this.$headEl.hidden = true; return; }
    this.$headEl.hidden = false;
    this.$headEl.style.left = stripPct(t, this._m.dur);
    if (!this.hasAttribute('compact')) {
      this.setAttribute('aria-valuenow', String(Math.round(t)));
      this.setAttribute('aria-valuetext', clock(this._m.startMs + t * 1000, this._m.tz, { seconds: true }));
    }
  }
}

if (!customElements.get('pa-strip')) customElements.define('pa-strip', PaStrip);
