// The plugin script, run as the Pebble app runs it: a fresh context per request with Pebble, fetch,
// and storage provided by the host. Here they are fakes, so the envelopes, error codes, and what is
// kept where can be checked without a phone.
//
//     node --test

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).pebble;
const script = fs.readFileSync(path.join(root, manifest.plugin.script), 'utf8');

const SERVER = 'https://pebbleaudio.okgodoit.com';
const NOW = Date.UTC(2026, 9, 28, 14, 0, 0);
const TOKEN = 'pat_Zm9vYmFyLXRlc3QtdG9rZW4tbmV2ZXItbG9nZ2Vk';

const STATUS = {
  updatedAtMs: NOW - 30_000,
  capture: 'active',
  link: 'streaming',
  recording: true,
  lastAudioAtMs: NOW - 125_000,
  watchBatteryPercent: 62,
  watchFirmware: 'v4.41.0-667',
  todayRecordedMinutes: 312,
  todayQuietMinutes: 95,
  todayLostMinutes: 4,
  storageUsedBytes: 734_003_200,
  phoneBatteryPercent: 81,
  receivedAtMs: NOW - 25_000,
  stale: false,
  deviceName: "Alex's iPhone",
};

const TODAY = {
  date: '2026-10-28',
  conversationCount: 3,
  recapHeadline: 'Tiles, teeth, and the launch',
  current: { id: 'conv-live', title: null, startedAtMs: NOW - 600_000, state: 'live' },
  last: { id: 'conv-standup', title: 'Morning standup', startedAtMs: NOW - 7_200_000, endedAtMs: NOW - 6_000_000, state: 'closed' },
  viewerUrl: `${SERVER}/d/2026-10-28`,
};

/** Loads the script with fake host APIs. `routes` maps "METHOD /path" to { status, body } or a function of the request. */
function load({ token = null, routes = {} } = {}) {
  const secure = new Map(token ? [['token', token]] : []);
  const local = new Map();
  const logs = [];
  const requests = [];
  const refreshed = [];
  const handlers = {};
  const Pebble = {
    registerSourceHandler: (handler) => { handlers.source = handler; },
    registerActionHandler: (handler) => { handlers.action = handler; },
    registerConfigHandler: (handler) => { handlers.config = handler; },
    secureStorage: {
      getItem: async (key) => (secure.has(key) ? secure.get(key) : null),
      setItem: async (key, value) => { secure.set(key, String(value)); },
      removeItem: async (key) => { secure.delete(key); },
    },
    refreshSources: (list) => { refreshed.push([...list]); },
  };
  const fetch = async (url, init = {}) => {
    requests.push({ url, method: init.method || 'GET', headers: { ...(init.headers || {}) }, body: init.body });
    const route = routes[`${init.method || 'GET'} ${new URL(url).pathname}`];
    if (!route) throw new TypeError(`Network request to ${url} failed`);
    const answer = typeof route === 'function' ? route({ url, init }) : route;
    if (answer instanceof Error) throw answer;
    return {
      status: answer.status,
      ok: answer.status >= 200 && answer.status < 300,
      json: async () => {
        if (answer.body === undefined) throw new SyntaxError('Unexpected end of JSON input');
        return JSON.parse(JSON.stringify(answer.body));
      },
    };
  };
  class FakeDate extends Date {
    constructor(...args) { if (args.length) super(...args); else super(NOW); }
    static now() { return NOW; }
  }
  const localStorage = {
    getItem: (key) => (local.has(key) ? local.get(key) : null),
    setItem: (key, value) => { local.set(key, String(value)); },
    removeItem: (key) => { local.delete(key); },
  };
  const log = (...parts) => { logs.push(parts.map(String).join(' ')); };
  const context = vm.createContext({
    Pebble,
    fetch,
    localStorage,
    console: { log, error: log, warn: log, info: log },
    Date: FakeDate,
    setTimeout,
    clearTimeout,
    URL,
  });
  vm.runInContext(script, context, { filename: manifest.plugin.script });
  return { handlers, secure, local, logs, requests, refreshed };
}

/** One source request; resolves to { data } or { error }. Copied out of the script's realm. */
function read(plugin, item, category = 'audio') {
  return new Promise((resolve) => {
    plugin.handlers.source({ category, item }, {
      data: (envelope) => resolve({ data: JSON.parse(JSON.stringify(envelope)) }),
      error: (code, message) => resolve({ error: { code, message } }),
    });
  });
}

/** One settings-page message; resolves to the reply. */
function configure(plugin, message) {
  return new Promise((resolve) => {
    plugin.handlers.config(message, (reply) => resolve(JSON.parse(JSON.stringify(reply))));
  });
}

/** Nothing the plugin said, to the host or to its log, may carry the token or a server address. */
function assertNothingLeaks(plugin, ...said) {
  for (const text of [...plugin.logs, ...said.map((s) => JSON.stringify(s))]) {
    assert.ok(!text.includes(TOKEN), `the token leaked: ${text}`);
    assert.ok(!text.includes('pat_'), `a token leaked: ${text}`);
    assert.ok(!text.includes(SERVER), `a server address leaked: ${text}`);
  }
}

/** Every property and shape in an envelope must be declared, or a 1.15 host drops it. */
function assertDeclared(item, envelope) {
  const source = manifest.plugin.sources.find((s) => s.category === 'audio' && s.items.includes(item));
  assert.ok(source, `audio/${item} is not declared`);
  for (const instance of envelope.instances) {
    for (const [property, shapes] of Object.entries(instance.properties)) {
      const declared = source.properties[property];
      assert.ok(declared, `audio/${item} sends ${property}, which the manifest does not declare`);
      for (const shape of Object.keys(shapes)) {
        assert.ok(declared.includes(shape), `audio/${item} sends ${property}.${shape}, which the manifest does not declare`);
      }
    }
  }
}

test('audio/status reads the server with the token and answers every declared shape', async () => {
  const plugin = load({ token: TOKEN, routes: { 'GET /plugin/status': { status: 200, body: STATUS } } });
  const { data } = await read(plugin, 'status');

  assert.equal(plugin.requests.length, 1);
  assert.equal(plugin.requests[0].url, `${SERVER}/plugin/status`);
  assert.equal(plugin.requests[0].headers.Authorization, `Bearer ${TOKEN}`);
  assert.deepEqual(data, {
    validUntilMs: NOW + 120_000,
    instances: [{
      instanceId: 'watch',
      properties: {
        name: { shortText: { text: "Alex's iPhone" } },
        recording: { boolean: { value: true }, shortText: { text: 'Recording' } },
        capture: { shortText: { text: 'On' } },
        link: { shortText: { text: 'Streaming' } },
        stale: { boolean: { value: false } },
        last_audio: { timestamp: { value: Math.floor((NOW - 125_000) / 1000) }, shortText: { text: '2m ago' } },
        watch_battery: { numericValue: { value: 62, unit: '%', min: 0, max: 100 }, shortText: { text: '62%' } },
        today_recorded: { numericValue: { value: 312, unit: 'min' }, shortText: { text: '5h 12m' } },
        today_lost: { numericValue: { value: 4, unit: 'min' }, shortText: { text: '4m' } },
        storage_used: { numericValue: { value: 700, unit: 'MB' }, shortText: { text: '700 MB' } },
      },
    }],
  });
  assertDeclared('status', data);
  assert.equal(plugin.local.size, 0, 'nothing goes in localStorage');
  assertNothingLeaks(plugin, data);
});

test('audio/status leaves out what the phone does not know, and says Watch without a name', async () => {
  const sparse = { ...STATUS, lastAudioAtMs: null, watchBatteryPercent: null, todayRecordedMinutes: null, todayLostMinutes: null, storageUsedBytes: null, deviceName: null };
  const plugin = load({ token: TOKEN, routes: { 'GET /plugin/status': { status: 200, body: sparse } } });
  const { data } = await read(plugin, 'status');
  const properties = data.instances[0].properties;
  assert.deepEqual(Object.keys(properties).sort(), ['capture', 'link', 'name', 'recording', 'stale']);
  assert.equal(properties.name.shortText.text, 'Watch');
});

test('one answer to "is it recording?", settled in order', async () => {
  const cases = [
    [{ stale: true }, false, 'Unknown'],
    [{ link: 'unbound', recording: false }, false, 'No watch'],
    [{ link: 'revoked', recording: false }, false, 'No watch'],
    [{ capture: 'off', recording: false }, false, 'Off'],
    [{ capture: 'paused', recording: false }, false, 'Paused'],
    [{}, true, 'Recording'],
    [{ link: 'disconnected', recording: false }, false, 'Offline'],
    [{ link: 'connecting', recording: false }, false, 'Offline'],
    [{ link: 'connected', recording: false }, false, 'Not recording'],
  ];
  for (const [change, on, words] of cases) {
    const plugin = load({ token: TOKEN, routes: { 'GET /plugin/status': { status: 200, body: { ...STATUS, ...change } } } });
    const { data } = await read(plugin, 'status');
    const recording = data.instances[0].properties.recording;
    assert.deepEqual(recording, { boolean: { value: on }, shortText: { text: words } }, JSON.stringify(change));
  }

  // An old report is no answer at all: the link reads unknown too, and stale says so.
  const plugin = load({ token: TOKEN, routes: { 'GET /plugin/status': { status: 200, body: { ...STATUS, stale: true } } } });
  const properties = (await read(plugin, 'status')).data.instances[0].properties;
  assert.equal(properties.link.shortText.text, 'Unknown');
  assert.deepEqual(properties.stale, { boolean: { value: true } });
});

test('audio/conversation answers today, with the conversation still going and the one before', async () => {
  const plugin = load({ token: TOKEN, routes: { 'GET /plugin/today': { status: 200, body: TODAY } } });
  const { data } = await read(plugin, 'conversation');
  const clock = (ms) => { const at = new Date(ms); return `${at.getHours()}:${String(at.getMinutes()).padStart(2, '0')}`; };

  assert.equal(plugin.requests[0].url, `${SERVER}/plugin/today`);
  assert.deepEqual(data, {
    validUntilMs: NOW + 900_000,
    instances: [{
      instanceId: 'today',
      properties: {
        name: { shortText: { text: 'Today' } },
        conversations: { numericValue: { value: 3 }, shortText: { text: '3' } },
        current_title: { shortText: { text: 'Conversation in progress' }, longText: { text: 'Conversation in progress' } },
        last_title: { shortText: { text: 'Morning standup' }, longText: { text: 'Morning standup' } },
        current_started: { timestamp: { value: Math.floor((NOW - 600_000) / 1000) }, shortText: { text: clock(NOW - 600_000) } },
        last_started: { timestamp: { value: Math.floor((NOW - 7_200_000) / 1000) }, shortText: { text: clock(NOW - 7_200_000) } },
        recap: { longText: { text: 'Tiles, teeth, and the launch' } },
      },
    }],
  });
  assertDeclared('conversation', data);
  assertNothingLeaks(plugin, data);

  // A quiet morning: no conversation yet, empty titles, no times, no recap.
  const empty = load({ token: TOKEN, routes: { 'GET /plugin/today': { status: 200, body: { ...TODAY, conversationCount: 0, recapHeadline: null, current: null, last: null } } } });
  const properties = (await read(empty, 'conversation')).data.instances[0].properties;
  assert.deepEqual(properties.current_title, { shortText: { text: '' }, longText: { text: '' } });
  assert.deepEqual(properties.last_title, { shortText: { text: '' }, longText: { text: '' } });
  assert.deepEqual(Object.keys(properties).sort(), ['conversations', 'current_title', 'last_title', 'name']);
});

test('errors carry the host codes and safe words, never the token or the server', async () => {
  const cases = [
    ['no token', null, {}, 'AUTH_REQUIRED'],
    ['token revoked', TOKEN, { 'GET /plugin/status': { status: 401 } }, 'AUTH_REQUIRED'],
    ['no status yet', TOKEN, { 'GET /plugin/status': { status: 404, body: { error: 'No watch status has arrived from a linked phone yet.' } } }, 'PLUGIN_UNAVAILABLE'],
    ['server error', TOKEN, { 'GET /plugin/status': { status: 500 } }, 'UNKNOWN'],
    ['not JSON', TOKEN, { 'GET /plugin/status': { status: 200 } }, 'UNKNOWN'],
    ['network down or host blocked', TOKEN, {}, 'UNKNOWN'],
  ];
  for (const [what, token, routes, code] of cases) {
    const plugin = load({ token, routes });
    const answer = await read(plugin, 'status');
    assert.equal(answer.data, undefined, what);
    assert.equal(answer.error.code, code, what);
    assert.ok(answer.error.message && answer.error.message.length < 120, what);
    assertNothingLeaks(plugin, answer);
    if (!token) assert.equal(plugin.requests.length, 0, 'nothing is fetched without a token');
  }

  const plugin = load({ token: TOKEN });
  assert.equal((await read(plugin, 'weather', 'other')).error.code, 'PLUGIN_UNAVAILABLE');
  assert.equal(plugin.requests.length, 0);
});

test('settings: a code from the connect page becomes a token kept only in secure storage', async () => {
  let linked = null;
  const plugin = load({
    routes: {
      'POST /plugin/link': ({ init }) => { linked = JSON.parse(init.body); return { status: 201, body: { token: TOKEN } }; },
      'GET /plugin/status': { status: 404, body: { error: 'none yet' } },
    },
  });

  assert.deepEqual(await configure(plugin, { type: 'status' }), { connected: false });
  assert.deepEqual(await configure(plugin, { type: 'connect', code: '  ' }), { connected: false, error: 'Enter the code from Pebble Audio.' });

  const reply = await configure(plugin, { type: 'connect', code: 'k7qm-3xwd' });
  assert.deepEqual(linked, { code: 'k7qm-3xwd' });
  assert.equal(plugin.requests[0].url, `${SERVER}/plugin/link`);
  assert.equal(plugin.requests[0].headers.Authorization, undefined, 'linking sends no token');
  // Its first read is what turns the connect page's wait into a check.
  assert.equal(plugin.requests[1].headers.Authorization, `Bearer ${TOKEN}`);
  assert.deepEqual(reply, { connected: true, line: "Your phone hasn't sent the watch's status yet." });
  assert.equal(plugin.secure.get('token'), TOKEN);
  assert.equal(plugin.local.size, 0, 'the token never goes in localStorage');
  assert.deepEqual(plugin.refreshed, [['audio/status', 'audio/conversation']]);
  assertNothingLeaks(plugin, reply);

  // Disconnect forgets it and refreshes the readings, which then ask to connect.
  assert.deepEqual(await configure(plugin, { type: 'disconnect' }), { connected: false });
  assert.equal(plugin.secure.has('token'), false);
  assert.equal(plugin.refreshed.length, 2);
  assert.equal((await read(plugin, 'status')).error.code, 'AUTH_REQUIRED');
});

test('settings: a wrong code or a dead key is refused and nothing is kept', async () => {
  const plugin = load({
    routes: {
      'POST /plugin/link': { status: 409, body: { error: 'That code is not valid.' } },
      'GET /plugin/today': { status: 401 },
    },
  });
  const wrong = await configure(plugin, { type: 'connect', code: 'AAAA-AAAA' });
  assert.deepEqual(wrong, { connected: false, error: "That code didn't work. Codes last ten minutes and work once." });
  const dead = await configure(plugin, { type: 'connect', code: TOKEN });
  assert.deepEqual(dead, { connected: false, error: "That key isn't valid." });
  assert.equal(plugin.secure.size, 0);
  assertNothingLeaks(plugin, wrong, dead);
});

test('settings: a pasted access key is checked, then kept, and the page shows the watch', async () => {
  const plugin = load({
    routes: {
      'GET /plugin/today': { status: 200, body: TODAY },
      'GET /plugin/status': { status: 200, body: STATUS },
    },
  });
  const reply = await configure(plugin, { type: 'connect', code: ` ${TOKEN} ` });
  assert.deepEqual(plugin.requests.map((r) => r.url), [`${SERVER}/plugin/today`, `${SERVER}/plugin/status`]);
  assert.deepEqual(reply, { connected: true, line: "Recording · Alex's iPhone · last audio 2m ago" });
  assert.equal(plugin.secure.get('token'), TOKEN);
  assertNothingLeaks(plugin, reply);
});

test('settings: a token the server no longer takes is forgotten when the page opens', async () => {
  const plugin = load({ token: TOKEN, routes: { 'GET /plugin/status': { status: 401 } } });
  const reply = await configure(plugin, { type: 'status' });
  assert.equal(reply.connected, false);
  assert.match(reply.error, /Connect it again/);
  assert.equal(plugin.secure.has('token'), false);
  assertNothingLeaks(plugin, reply);
});
