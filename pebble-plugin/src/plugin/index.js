// Pebble Audio for the Pebble app: whether the watch is recording, and today's conversations,
// read from the person's Pebble Audio server.
//
// The plugin starts fresh for every request and holds nothing between them. Its one secret, the
// server token (pat_…), lives in Pebble.secureStorage and nowhere else: never in localStorage,
// never in a log line, never in an error message.

var SERVER = 'https://pebbleaudio.okgodoit.com';
var TOKEN_KEY = 'token';
var STATUS_REFRESH_SEC = 120;
var CONVERSATION_REFRESH_SEC = 900;
var SOURCES = ['audio/status', 'audio/conversation'];
// Two calls at most per request, both inside the host's 20-second budget, so a slow server fails
// cleanly instead of timing the whole request out.
var TIMEOUT_MS = 9000;

// An error the host can show. The message is ours, never the server's or the network's.
function PluginError(code, message) {
  this.code = code;
  this.message = message;
}

var NOT_CONNECTED = new PluginError('AUTH_REQUIRED', 'Connect Pebble Audio in this plugin\'s settings.');
var DISCONNECTED = new PluginError('AUTH_REQUIRED', 'Pebble Audio disconnected this plugin. Connect it again in settings.');
var UNREACHABLE = new PluginError('UNKNOWN', 'Couldn\'t reach Pebble Audio.');
var NO_ANSWER = new PluginError('UNKNOWN', 'Pebble Audio didn\'t answer.');
var NO_STATUS = new PluginError('PLUGIN_UNAVAILABLE', 'Your phone hasn\'t sent the watch\'s status yet.');

function safe(error) {
  return error instanceof PluginError ? error : new PluginError('UNKNOWN', 'Something went wrong.');
}

// ---------------------------------------------------------------- the server

function readToken() {
  return Pebble.secureStorage.getItem(TOKEN_KEY);
}

function withTimeout(promise) {
  if (typeof setTimeout !== 'function') return promise;
  return new Promise(function (resolve, reject) {
    var timer = setTimeout(function () { reject(UNREACHABLE); }, TIMEOUT_MS);
    promise.then(
      function (value) { clearTimeout(timer); resolve(value); },
      function (error) { clearTimeout(timer); reject(error); });
  });
}

// GET a /plugin path with the token. Resolves to the parsed body; rejects with a PluginError.
async function get(path, token) {
  var response;
  try {
    response = await withTimeout(fetch(SERVER + path, {
      headers: { Authorization: 'Bearer ' + token, Accept: 'application/json' },
    }));
  } catch (e) {
    // A blocked host, no network, a timeout: all the same to the person.
    console.log('Pebble Audio: ' + path + ' could not be fetched');
    throw UNREACHABLE;
  }
  if (response.status === 401) throw DISCONNECTED;
  if (response.status === 404) throw NO_STATUS;
  if (!response.ok) {
    console.log('Pebble Audio: ' + path + ' answered HTTP ' + response.status);
    throw NO_ANSWER;
  }
  try {
    return await response.json();
  } catch (e) {
    throw NO_ANSWER;
  }
}

async function authorized(path) {
  var token = await readToken();
  if (!token) throw NOT_CONNECTED;
  return get(path, token);
}

// ---------------------------------------------------------------- words and numbers

function text(value) { return { text: String(value) }; }

function minutesText(minutes) {
  if (minutes < 60) return minutes + 'm';
  var hours = Math.floor(minutes / 60);
  var rest = minutes % 60;
  return rest ? hours + 'h ' + rest + 'm' : hours + 'h';
}

// "now", "2m ago", "3h ago", "2d ago": as of this request, since nothing here runs between them.
function ago(ms, now) {
  var seconds = Math.max(0, Math.round((now - ms) / 1000));
  if (seconds < 60) return 'now';
  var minutes = Math.floor(seconds / 60);
  if (minutes < 60) return minutes + 'm ago';
  var hours = Math.floor(minutes / 60);
  if (hours < 24) return hours + 'h ago';
  return Math.floor(hours / 24) + 'd ago';
}

function bytesText(bytes) {
  var mb = bytes / (1024 * 1024);
  if (mb < 1024) return Math.round(mb) + ' MB';
  return (mb / 1024).toFixed(1) + ' GB';
}

function known(value) { return value !== null && value !== undefined; }

var CAPTURE_WORDS = { active: 'On', paused: 'Paused', off: 'Off' };
var LINK_WORDS = {
  unbound: 'No watch',
  disconnected: 'Offline',
  connecting: 'Connecting',
  connected: 'Connected',
  streaming: 'Streaming',
  revoked: 'Refused',
};

// One answer to "is it recording?", in the order a person would want it settled: an old report is
// no answer at all, then no watch, then the person's own choice, then what the phone saw.
function recordingReading(status) {
  if (status.stale) return { on: false, words: 'Unknown' };
  if (status.link === 'unbound' || status.link === 'revoked') return { on: false, words: 'No watch' };
  if (status.capture === 'off') return { on: false, words: 'Off' };
  if (status.capture === 'paused') return { on: false, words: 'Paused' };
  if (status.recording) return { on: true, words: 'Recording' };
  if (status.link === 'disconnected' || status.link === 'connecting') return { on: false, words: 'Offline' };
  return { on: false, words: 'Not recording' };
}

// ---------------------------------------------------------------- sources

function statusInstance(status, now) {
  var recording = recordingReading(status);
  var properties = {
    // The instance is the watch; the phone that reports for it is its own property.
    name: { shortText: text('Watch') },
    recording: { boolean: { value: recording.on }, shortText: text(recording.words) },
    capture: { shortText: text(CAPTURE_WORDS[status.capture] || status.capture) },
    // An old report says nothing about the link now; the capture setting is the person's own choice.
    link: { shortText: text(status.stale ? 'Unknown' : (LINK_WORDS[status.link] || status.link)) },
    stale: { boolean: { value: !!status.stale } },
  };
  if (status.deviceName) {
    properties.device = { shortText: text(status.deviceName), longText: text(status.deviceName) };
  }
  if (known(status.lastAudioAtMs)) {
    properties.last_audio = {
      timestamp: { value: Math.floor(status.lastAudioAtMs / 1000) },
      shortText: text(ago(status.lastAudioAtMs, now)),
    };
  }
  if (known(status.watchBatteryPercent)) {
    properties.watch_battery = {
      numericValue: { value: status.watchBatteryPercent, unit: '%', min: 0, max: 100 },
      shortText: text(status.watchBatteryPercent + '%'),
    };
  }
  if (known(status.todayRecordedMinutes)) {
    properties.today_recorded = {
      numericValue: { value: status.todayRecordedMinutes, unit: 'min' },
      shortText: text(minutesText(status.todayRecordedMinutes)),
    };
  }
  if (known(status.todayLostMinutes)) {
    properties.today_lost = {
      numericValue: { value: status.todayLostMinutes, unit: 'min' },
      shortText: text(minutesText(status.todayLostMinutes)),
    };
  }
  if (known(status.storageUsedBytes)) {
    properties.storage_used = {
      numericValue: { value: Math.round(status.storageUsedBytes / (1024 * 1024)), unit: 'MB' },
      shortText: text(bytesText(status.storageUsedBytes)),
    };
  }
  return { instanceId: 'watch', properties: properties };
}

function clockText(ms) {
  var at = new Date(ms);
  var hours = at.getHours();
  var minutes = at.getMinutes();
  return hours + ':' + (minutes < 10 ? '0' : '') + minutes;
}

function titled(title, fallback) {
  return title && String(title).trim() ? String(title).trim() : fallback;
}

function todayInstance(today) {
  var count = today.conversationCount || 0;
  var properties = {
    name: { shortText: text('Today') },
    conversations: { numericValue: { value: count }, shortText: text(count) },
    current_title: { shortText: text(''), longText: text('') },
    last_title: { shortText: text(''), longText: text('') },
  };
  if (today.current) {
    var current = titled(today.current.title, 'Conversation in progress');
    properties.current_title = { shortText: text(current), longText: text(current) };
    properties.current_started = {
      timestamp: { value: Math.floor(today.current.startedAtMs / 1000) },
      shortText: text(clockText(today.current.startedAtMs)),
    };
  }
  if (today.last) {
    var last = titled(today.last.title, 'Untitled conversation');
    properties.last_title = { shortText: text(last), longText: text(last) };
    properties.last_started = {
      timestamp: { value: Math.floor(today.last.startedAtMs / 1000) },
      shortText: text(clockText(today.last.startedAtMs)),
    };
  }
  if (today.recapHeadline) {
    properties.recap = { longText: text(today.recapHeadline) };
  }
  return { instanceId: 'today', properties: properties };
}

Pebble.registerSourceHandler(async function (request, respond) {
  var item = request && request.category === 'audio' ? request.item : null;
  if (item !== 'status' && item !== 'conversation') {
    respond.error('PLUGIN_UNAVAILABLE', 'Pebble Audio has no ' + (request && request.category) + '/' + (request && request.item) + '.');
    return;
  }
  try {
    var now = Date.now();
    if (item === 'status') {
      var status = await authorized('/plugin/status');
      respond.data({ validUntilMs: now + STATUS_REFRESH_SEC * 1000, instances: [statusInstance(status, now)] });
    } else {
      var today = await authorized('/plugin/today');
      respond.data({ validUntilMs: now + CONVERSATION_REFRESH_SEC * 1000, instances: [todayInstance(today)] });
    }
  } catch (error) {
    var answer = safe(error);
    console.log('Pebble Audio: audio/' + item + ' failed: ' + answer.code);
    respond.error(answer.code, answer.message);
  }
});

// ---------------------------------------------------------------- settings page

function refresh() {
  if (typeof Pebble.refreshSources === 'function') Pebble.refreshSources(SOURCES);
}

// What the settings page shows once connected: one line about the watch, or why there is none.
async function describe(token) {
  try {
    var status = await get('/plugin/status', token);
    var reading = recordingReading(status);
    var parts = [reading.words];
    if (status.deviceName) parts.push(status.deviceName);
    if (!status.stale && known(status.lastAudioAtMs)) parts.push('last audio ' + ago(status.lastAudioAtMs, Date.now()));
    return { connected: true, line: parts.join(' · ') };
  } catch (error) {
    var answer = safe(error);
    if (answer === DISCONNECTED) {
      await Pebble.secureStorage.removeItem(TOKEN_KEY);
      return { connected: false, error: answer.message };
    }
    return { connected: true, line: answer.message };
  }
}

// A code from Pebble Audio on the phone (Settings › Watch), or a pasted access key (pat_…) for someone who made
// one by hand.
async function connect(entered) {
  var value = String(entered || '').trim();
  if (!value) return { connected: false, error: 'Enter the code from Pebble Audio.' };
  var token;
  if (value.indexOf('pat_') === 0) {
    token = value;
  } else {
    var response;
    try {
      response = await withTimeout(fetch(SERVER + '/plugin/link', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify({ code: value }),
      }));
    } catch (e) {
      return { connected: false, error: UNREACHABLE.message };
    }
    if (response.status === 409) return { connected: false, error: 'That code didn\'t work. Codes last ten minutes and work once.' };
    if (response.status === 429) return { connected: false, error: 'Too many tries. Wait a few minutes, then try a new code.' };
    if (response.status !== 201) {
      console.log('Pebble Audio: linking answered HTTP ' + response.status);
      return { connected: false, error: NO_ANSWER.message };
    }
    try {
      token = (await response.json()).token;
    } catch (e) {
      token = null;
    }
    if (typeof token !== 'string' || token.indexOf('pat_') !== 0) return { connected: false, error: NO_ANSWER.message };
  }
  // A pasted key is checked before it is kept. A linked one is known good; its first read below is
  // what Pebble Audio's Settings › Watch shows as its last read.
  if (value === token) {
    try {
      await get('/plugin/today', token);
    } catch (error) {
      var answer = safe(error);
      return { connected: false, error: answer === DISCONNECTED ? 'That key isn\'t valid.' : answer.message };
    }
  }
  await Pebble.secureStorage.setItem(TOKEN_KEY, token);
  refresh();
  return describe(token);
}

Pebble.registerConfigHandler(async function (message, respond) {
  var type = message && message.type;
  try {
    if (type === 'status') {
      var token = await readToken();
      respond(token ? await describe(token) : { connected: false });
    } else if (type === 'connect') {
      respond(await connect(message.code));
    } else if (type === 'disconnect') {
      await Pebble.secureStorage.removeItem(TOKEN_KEY);
      refresh();
      respond({ connected: false });
    } else {
      respond({ error: 'Unknown request.' });
    }
  } catch (error) {
    console.log('Pebble Audio: settings ' + type + ' failed');
    respond({ error: safe(error).message });
  }
});
