// Times, durations, and lists in the app's words, for the viewer's scripts and the widgets (which include
// this file inline). Times are always shown on the conversation's own wall clock, in its IANA zone.

const formats = new Map();

function formatter(tz, options) {
  const key = tz + JSON.stringify(options);
  let f = formats.get(key);
  if (!f) {
    try {
      f = new Intl.DateTimeFormat('en-US', { timeZone: tz || 'UTC', ...options });
    } catch {
      f = new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', ...options });
    }
    formats.set(key, f);
  }
  return f;
}

function part(parts, type) {
  return parts.find((p) => p.type === type)?.value ?? '';
}

/** "10:54 AM", "10:54:12 AM" with seconds, "10:54" without the day's half. */
export function clock(ms, tz, { seconds = false, period = true } = {}) {
  const parts = formatter(tz, { hour: 'numeric', minute: '2-digit', second: seconds ? '2-digit' : undefined, hour12: true }).formatToParts(new Date(ms));
  const time = `${part(parts, 'hour')}:${part(parts, 'minute')}${seconds ? ':' + part(parts, 'second') : ''}`;
  return period ? `${time} ${part(parts, 'dayPeriod')}` : time;
}

/** "AM" or "PM". */
export function dayPeriod(ms, tz) {
  return part(formatter(tz, { hour: 'numeric', hour12: true }).formatToParts(new Date(ms)), 'dayPeriod');
}

/** "10:54 – 11:21 AM", or "11:40 AM – 12:15 PM" across noon. */
export function range(a, b, tz) {
  return dayPeriod(a, tz) === dayPeriod(b, tz) ? `${clock(a, tz, { period: false })} – ${clock(b, tz)}` : `${clock(a, tz)} – ${clock(b, tz)}`;
}

/** "Wed, Oct 14" for a yyyy-MM-dd day key. */
export function shortDay(dayKey) {
  const [y, m, d] = dayKey.split('-').map(Number);
  return formatter('UTC', { weekday: 'short', month: 'short', day: 'numeric' }).format(Date.UTC(y, m - 1, d));
}

/** "Wednesday, October 14" for a yyyy-MM-dd day key. */
export function longDay(dayKey) {
  const [y, m, d] = dayKey.split('-').map(Number);
  return formatter('UTC', { weekday: 'long', month: 'long', day: 'numeric' }).format(Date.UTC(y, m - 1, d));
}

/** "27 min", "1 hr 5 min", "under 1 min", or "48 sec" with seconds (for loss, which must read as real). */
export function duration(totalSeconds, { seconds = false } = {}) {
  const whole = Math.round(Math.max(0, totalSeconds));
  if (whole < 60) return seconds ? `${Math.max(1, whole)} sec` : 'under 1 min';
  const minutes = Math.round(whole / 60);
  if (minutes < 60) return `${minutes} min`;
  const h = Math.floor(minutes / 60), m = minutes % 60;
  return m ? `${h} hr ${m} min` : `${h} hr`;
}

/** "1:05" from seconds, for positions inside a clip. */
export function elapsed(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
  return h ? `${h}:${String(m).padStart(2, '0')}:${String(r).padStart(2, '0')}` : `${m}:${String(r).padStart(2, '0')}`;
}

/** An Oxford-comma list: "a, b, and c". */
export function list(items, conjunction = 'and') {
  if (items.length <= 1) return items.join('');
  if (items.length === 2) return `${items[0]} ${conjunction} ${items[1]}`;
  return `${items.slice(0, -1).join(', ')}, ${conjunction} ${items[items.length - 1]}`;
}

/**
 * "Sam, Priya, and 1 other voice": named people first, never a name the app has not matched;
 * "2 voices" when nobody is named.
 */
export function peopleLine(people) {
  const named = [...new Set(people.filter((p) => p.name).map((p) => p.name))];
  const unnamed = people.filter((p) => !p.name).length;
  if (!named.length) return unnamed ? (unnamed === 1 ? '1 voice' : `${unnamed} voices`) : '';
  if (unnamed) named.push(unnamed === 1 ? '1 other voice' : `${unnamed} other voices`);
  return list(named);
}

/** Escapes text for HTML. */
export function esc(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}

/** Milliseconds since the epoch from an RFC 3339 instant. */
export function instant(text) {
  return text ? Date.parse(text) : NaN;
}

/** Why audio is missing, in the app's words, from a lost gap's origin. */
export function lossCause(origin) {
  return origin === 'link' ? 'connection was interrupted' : origin === 'watch' ? "the watch didn't record it" : '';
}
