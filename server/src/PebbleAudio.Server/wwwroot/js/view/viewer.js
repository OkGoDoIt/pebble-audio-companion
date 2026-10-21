// The conversation page: the strip and its sticky mini copy, the transcript opened at the cited moment, and
// the clip player docked at the bottom on phones. The clip comes from the server's clip machinery: played
// when it is here, requested from the phone (and waited for) when the person asks.

import { clock } from './format.js';
import './pa-strip.js';
import './pa-player.js';

const model = JSON.parse(document.getElementById('cv-model').textContent);
const strips = [...document.querySelectorAll('pa-strip')];
const player = document.querySelector('pa-player');
const dock = document.querySelector('[data-dock]');
const rows = [...document.querySelectorAll('.tx .row')];
const starts = rows.map((r) => Number(r.dataset.s));
const backTo = document.querySelector('[data-back-to]');
const phone = matchMedia('(max-width: 1099px)');
const csrf = document.querySelector('meta[name="csrf-token"]')?.content ?? '';

let clipState = model.clip;
let nowRow = null;
let following = false;
let pollTimer = 0;
let pollStarted = 0;

// ── Strips ───────────────────────────────────────────────────────────────

for (const strip of strips) {
  strip.model = model;
  if (model.t != null) strip.setPin(model.t, clock(model.startMs + model.t * 1000, model.tz));
}

function showClipWindow() {
  for (const strip of strips) strip.setClip(clipState.from, clipState.to);
}

document.addEventListener('pa-seek', (e) => {
  const t = e.detail.t;
  for (const strip of strips) strip.setHead(t);
  if (!e.detail.done) return;
  goToWords(t, true);
  cue(t, player.playing);
});

// ── The player and its clip ──────────────────────────────────────────────

function syncDock() {
  player.toggleAttribute('docked', phone.matches);
  player.redraw();
}

function applyClip(state) {
  clipState = state;
  showClipWindow();
  player.toggleAttribute('docked', phone.matches);
  player.model = { ...model, span: [clipState.from, clipState.to], t: model.t ?? clipState.from };
  clearTimeout(pollTimer);
  if (state.status === 'ready' && state.audioUrl) {
    player.source = {
      url: state.audioUrl,
      covered: [state.coveredFrom ?? state.from, state.coveredTo ?? state.to],
      lost: state.lost ?? [],
      quiet: state.quiet ?? [],
      durationMs: state.durationMs,
    };
    if (model.t != null && model.t >= state.from && model.t <= state.to) player.cueAt(model.t, false);
    return;
  }
  player.source = null;
  player.setState(words(state));
  if (state.status === 'requested') poll();
}

/** A heading, at most one line, and the one thing to do: the state in the app's voice. */
function words(state) {
  switch (state.status) {
    case 'requested':
      return { head: 'Waiting for your phone', line: 'It sends the clip on its next sync.', busy: true };
    case 'notAllowed':
      return { head: "Clips aren't allowed", line: 'Allow them on your phone, under Pebble Audio server.' };
    case 'unavailable':
      switch (state.reason) {
        case 'failed':
          return { head: "This clip couldn't be made", line: 'Try again later.' };
        case 'notDelivered':
          return { head: "Your phone didn't send this clip", line: 'It may have been out of reach.', action: 'Request this clip' };
        case 'notFound':
          return { head: "This conversation isn't in your archive" };
        default:
          return { head: 'This audio is no longer on your phone' };
      }
    default:
      return state.reason === 'notDelivered'
        ? { head: "Your phone didn't send this clip", line: 'It may have been out of reach.', action: 'Request this clip' }
        : { head: 'Audio stays on your phone', line: 'Your phone sends this clip when you ask.', action: 'Request this clip' };
  }
}

async function call(url, options) {
  const response = await fetch(url, { credentials: 'same-origin', headers: { Accept: 'application/json', ...(options?.headers ?? {}) }, ...options });
  if (response.status === 401) return { status: 'signedOut' };
  if (!response.ok) throw new Error(String(response.status));
  return response.json();
}

player.addEventListener('pa-action', async () => {
  player.setState({ head: 'Asking your phone', busy: true });
  try {
    const state = await call(model.clipUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', RequestVerificationToken: csrf },
      body: JSON.stringify({ start: clipState.from, end: clipState.to }),
    });
    if (state.status === 'signedOut') return location.reload();
    pollStarted = Date.now();
    applyClip(state);
  } catch {
    player.setState({ head: "Couldn't reach the server", line: 'Check the connection and try again.', action: 'Request this clip' });
  }
});

/** While the page is open and in view: every 5 seconds for two minutes, then every 20. */
function poll() {
  clearTimeout(pollTimer);
  if (document.hidden || !clipState.requestId) return;
  const wait = Date.now() - (pollStarted || Date.now()) < 120_000 ? 5_000 : 20_000;
  pollTimer = setTimeout(async () => {
    try {
      const state = await call(`${model.clipUrl}/${clipState.requestId}`);
      if (state.status === 'signedOut') return location.reload();
      if (state.status === 'requested') { clipState = { ...clipState, ...state }; poll(); }
      else applyClip({ ...state, from: state.from || clipState.from, to: state.to || clipState.to });
    } catch {
      poll();
    }
  }, wait);
}

document.addEventListener('visibilitychange', () => {
  if (!document.hidden && clipState.status === 'requested') poll();
});

/** Moves the player to t: inside this clip at once, else to the clip around t. */
async function cue(t, play) {
  if (t >= clipState.from && t <= clipState.to) {
    player.cueAt(t, play);
    return;
  }
  try {
    const state = await call(`${model.clipUrl}?t=${Math.round(t)}`);
    if (state.status === 'signedOut') return location.reload();
    model.t = t;
    applyClip(state);
    if (state.status === 'ready') player.cueAt(t, play);
  } catch {
    // The clip around t stays as it was.
  }
}

player.addEventListener('pa-time', (e) => {
  const { t, playing } = e.detail;
  for (const strip of strips) strip.setHead(t);
  markNow(t, playing);
});

// ── The transcript ───────────────────────────────────────────────────────

function rowAt(t) {
  let lo = 0, hi = starts.length - 1, found = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (starts[mid] <= t) { found = mid; lo = mid + 1; } else hi = mid - 1;
  }
  return found < 0 ? null : rows[found];
}

function visible(el) {
  const r = el.getBoundingClientRect();
  const top = document.querySelector('[data-bar]').getBoundingClientRect().bottom;
  const bottom = phone.matches ? dock.getBoundingClientRect().top : innerHeight;
  return r.bottom > top + 8 && r.top < bottom - 8;
}

function markNow(t, playing) {
  const row = rowAt(t);
  if (row !== nowRow) {
    nowRow?.classList.remove('now');
    row?.classList.add('now');
    nowRow = row;
    if (row && playing && following && !visible(row)) scrollToRow(row, true);
  }
  backTo.hidden = !(playing && row && !following && !visible(row));
}

function scrollToRow(row, smooth) {
  const top = document.querySelector('[data-bar]').getBoundingClientRect().height;
  const y = row.getBoundingClientRect().top + scrollY - top - (innerHeight - top) * 0.3;
  scrollTo({ top: Math.max(0, y), behavior: smooth && !matchMedia('(prefers-reduced-motion: reduce)').matches ? 'smooth' : 'auto' });
}

function goToWords(t, smooth) {
  const row = rowAt(t);
  if (row) scrollToRow(row, smooth);
}

document.addEventListener('click', (e) => {
  const stamp = e.target.closest('[data-t]');
  if (stamp && !e.metaKey && !e.ctrlKey) {
    e.preventDefault();
    const t = Number(stamp.dataset.t);
    following = true;
    if (!stamp.classList.contains('stamp')) goToWords(t, true);
    cue(t, true);
    return;
  }
  const from = e.target.closest('[data-play-from]');
  if (from) {
    following = true;
    cue(Number(from.dataset.playFrom), true);
  }
});

// The reader scrolling away stops the transcript following the audio; "Back to playing" brings it back.
for (const type of ['wheel', 'touchmove']) addEventListener(type, () => { if (player.playing) following = false; }, { passive: true });
addEventListener('keydown', (e) => { if (['PageDown', 'PageUp', 'ArrowDown', 'ArrowUp', 'Home', 'End'].includes(e.key) && e.target === document.body) following = false; });
addEventListener('scroll', () => { if (player.playing && nowRow) backTo.hidden = following || visible(nowRow); }, { passive: true });
backTo.addEventListener('click', () => {
  following = true;
  backTo.hidden = true;
  if (nowRow) scrollToRow(nowRow, true);
});

// ── The bar, the mini strip, and the dock ────────────────────────────────

const bar = document.querySelector('[data-bar]');
const mini = document.querySelector('[data-mini]');
const title = document.querySelector('.cv-ident h1');
const shape = document.querySelector('.cv-shape');
new IntersectionObserver(([entry]) => bar.classList.toggle('scrolled', !entry.isIntersecting && entry.boundingClientRect.top < 0), { rootMargin: '-56px 0px 0px 0px' }).observe(title);
new IntersectionObserver(([entry]) => mini?.classList.toggle('on', !entry.isIntersecting && entry.boundingClientRect.top < 0), { rootMargin: '-56px 0px 0px 0px' }).observe(shape);

const sizeDock = () => document.body.style.setProperty('--dock-h', phone.matches ? `${Math.ceil(dock.getBoundingClientRect().height)}px` : '0px');
new ResizeObserver(sizeDock).observe(dock);
phone.addEventListener('change', () => { syncDock(); sizeDock(); });

applyClip(clipState);
for (const strip of strips) strip.setHead(model.t ?? clipState.from);

// Opened at a moment: the cited words sit a third of the way down, under the bar.
const cited = document.querySelector('.row.cited');
if (cited) requestAnimationFrame(() => scrollToRow(cited, false));
