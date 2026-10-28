# Pebble Audio plugin

A plugin for the official Pebble app (Core Devices) that shows Pebble Audio on the watch: whether the
watch is recording, its link and battery, today's recorded and lost minutes, and today's conversations.
It reads the person's Pebble Audio server (`pebbleaudio.okgodoit.com`, the app in [`../server`](../server))
and nothing else; the official app never sees audio. Any watchface or app that reads plugins can show it,
for example the Dashboard demo.

It is a plugin-only project for the plugin API of the Pebble app 1.15 and 1.16
(`mobileapp/test-apps/plugins.md`): no watch binary, a script, and a bundled settings page.

| File | What it is |
| --- | --- |
| `package.json` | The manifest (`pebble` block): uuid `dd26acba-10b0-4424-b196-afea043c2526`, the Internet permission for `pebbleaudio.okgodoit.com` only, the plugin's own `ReadConversations` permission, and every source, property, and shape |
| `src/plugin/index.js` | The plugin script |
| `src/config.html` | The settings page: connect with a code, see the watch's status, disconnect |
| `src/icon.svg` | The icon (one 1.6 px line on a 24 × 24 grid, as the pebble-plugins repo draws them) |
| `tools/pack-pbw.py` | Packages the pbw without the Pebble SDK |
| `test/plugin.test.js` | Runs the script against a fake host and server |
| `wscript` | The SDK's rules, for when a released `pebble-tool` builds plugin-only projects |

## Build and test

```sh
cd pebble-plugin
node --test                         # the plugin against a fake host (Node 20 or later)
python3 tools/pack-pbw.py           # writes build/pebble-audio.pbw (--out FILE writes there instead)
```

Released `pebble-tool` cannot build a plugin-only project yet; `tools/pack-pbw.py` writes the same pbw it
would: `appinfo.json` from `package.json`'s `pebble` block with `manifestVersion` 2 (uses permissions), and the
script and settings page at the paths the manifest names. It refuses a manifest the Pebble app would reject.

The iOS app carries the plugin: its build runs `tools/pack-pbw.py --out` into the app's resources on every build
(`ios/project.yml`, "Bundle Pebble Plugin"), so Settings › Watch › **Install in Pebble App** always installs the
plugin exactly as it is in this directory. Nothing is copied by hand for that.

To put a build where the phone can open it from Files instead:

```sh
mkdir -p ~/Desktop/PebblePlugins "$HOME/Library/Mobile Documents/com~apple~CloudDocs/PebblePlugins"
cp build/pebble-audio.pbw ~/Desktop/PebblePlugins/
cp build/pebble-audio.pbw "$HOME/Library/Mobile Documents/com~apple~CloudDocs/PebblePlugins/"
```

Bump `version` in `package.json` for every build you install over an earlier one.

## Install and connect on the phone

The server must have the plugin's endpoints first (deployed from `server/`, see its README).

1. Turn on plugins in the Pebble app. On 1.15: **Settings › Debug › Show debug options**, then **Use
   experimental plugins**. On 1.16: **Settings › Plugins › Plugins / permissions preview**. An **Apps ›
   Plugins** tab appears.
2. In Pebble Audio on the phone (linked to the server in Settings › AI Assistants), open **Settings › Watch** and
   tap **Install in Pebble App**, then choose Pebble. (Or, in the Files app, open **iCloud Drive › PebblePlugins**
   and tap **pebble-audio.pbw**.) Install it, and allow internet access to `pebbleaudio.okgodoit.com` when the
   Pebble app asks.
3. Under the install button, Settings › Watch shows a one-time code. Tap **Copy**.
4. In the Pebble app, open **Apps › Plugins › Pebble Audio** and its settings, paste the code, and tap
   **Connect**. The settings page says **Connected** with the watch's status, and Pebble Audio's Settings › Watch
   says **Connected** with the plugin's last read. On the server, **Who can read** lists it under **On your
   watch** as "Pebble plugin", read-only, and it is disconnected there.
5. Open **Dashboard (Plugin Demo)** (1.15 names it "Plugin Demo: Dashboard"; it comes with plugins turned on)
   and its settings in the Pebble app. Point a tile at **audio/status** (for example `recording`, which draws
   a check and says Recording, Paused, Off, No watch, or Unknown) and another at **audio/conversation**
   (`conversations`, or `last_title`). Open Dashboard on the watch. The first time it reads
   audio/conversation, the Pebble app asks once whether Dashboard may "Read your conversation titles and
   recaps (via Pebble Audio)"; until you allow it, that tile shows nothing.

A pasted access key (`pat_…`, made at **Connect an app › Another assistant**) works in the code field too.

## Data sources

Read by Index and agents. Each has one instance; a property the server does not know right now is left out.

**Who may read them.** `audio/status` is open: any watchface or app reads it without asking.
`audio/conversation` carries what was said, so it asks its callers for the plugin's own read permission,
`ReadConversations` ("Read your conversation titles and recaps"): the Pebble app asks the person once,
per watchface or app, before that one can read it, and it can be changed on the app's page afterwards. (That is
the Pebble app's default for an app that can send data off the phone, which the Dashboard can; with its
setting changed, it may ask for every app or for none.) A face
that wants it declares `{ "name": "ReadConversations", "plugin": "dd26acba-10b0-4424-b196-afea043c2526" }`
in its `usesPermissions`, so the question comes at install.

- `audio/status`, instance `watch`, refreshed every 2 minutes:
  `name` ("Watch"), `device` (the phone that reports for it, "Sam's iPhone"), `recording` (boolean, and Recording, Paused, Off, No watch,
  Offline, Not recording, or Unknown when the phone's last report is too old), `capture` (On, Paused, Off),
  `link` (No watch, Offline, Connecting, Connected, Streaming, Refused; Unknown when too old), `last_audio`
  (timestamp, and "2m ago" as of the read), `watch_battery` (0–100 %), `today_recorded` and `today_lost`
  (minutes, and "5h 12m"), `storage_used` (MB, and "700 MB"), `stale` (boolean).
- `audio/conversation`, instance `today`, refreshed every 15 minutes:
  `name` ("Today"), `conversations` (today's count), `current_title` and `current_started` (the conversation
  still being recorded, "" when there is none), `last_title` and `last_started` (the latest finished one,
  which may be from an earlier day), and `recap` (the first line of today's recap).

Times are `timestamp` shapes (epoch seconds), which the 1.15 host already knows, so a face that wants the
number reads `.timestamp.value`; the Dashboard shows them as a clock time. Errors: `AUTH_REQUIRED` before the
plugin is connected or after it is disconnected on the server, `PLUGIN_UNAVAILABLE` until the phone has sent
the watch's status, `UNKNOWN` when the server cannot be reached or answers wrongly. Messages never carry the
token or an address.

The token lives in `Pebble.secureStorage` only (key `token`), never in `localStorage`, a log line, or an
error message. The plugin keeps no other state.

## Server endpoints

On `https://pebbleaudio.okgodoit.com`, JSON, `Cache-Control: no-store`. The two reads take
`Authorization: Bearer pat_…` with `archive:read` (a personal token; OAuth tokens and the phone's device
token are refused) and answer 401 without one.

`POST /plugin/link` (no token) `{ "code": "K7QM-3XWD" }` → `201 { "token": "pat_…" }`, a new read-only token
named "Pebble plugin". Codes come from the phone app, which asks for one at `POST /sync/plugin-code`
(`server/docs/sync-protocol.md` §5): eight characters, ten minutes, once; case, spaces, and dashes do not matter,
and a new code ends the last. `409 { "error" }` for a wrong, used, or
expired code; after ten wrong codes from one address in ten minutes, `429` (shared with `POST /link`).

`GET /plugin/status` → the newest report from a linked phone (sync-protocol.md §2.8), with when it arrived and
whether that is too long ago (the *Watch status on Pebble* setting, 35 minutes by default), or `404 { "error" }`
before the first:

```json
{
  "updatedAtMs": 1791999175292, "capture": "active", "link": "streaming", "recording": true,
  "lastAudioAtMs": 1791999170000, "watchBatteryPercent": 62, "watchFirmware": "v4.41.0-667",
  "todayRecordedMinutes": 312, "todayQuietMinutes": 95, "todayLostMinutes": 4,
  "storageUsedBytes": 734003200, "phoneBatteryPercent": 81,
  "receivedAtMs": 1791999176012, "stale": false, "deviceName": "Sam's iPhone"
}
```

`GET /plugin/today` → today in the archive (the logical day, rolling over at 5 AM in the account's time zone),
read inside the phone's sharing scope as the MCP tools read it. Music and other audio that is not a
conversation is not counted. `current` is the day's newest conversation while it is `live` or `provisional`;
`last` is the latest closed one before it, from any day. A title is `null` until the phone has one.

```json
{
  "date": "2026-10-28", "conversationCount": 4, "recapHeadline": "Tiles, teeth, and the launch",
  "current": { "id": "conv-…", "title": null, "startedAtMs": 1791999000000, "state": "live" },
  "last": { "id": "conv-…", "title": "Morning standup", "startedAtMs": 1791990000000, "endedAtMs": 1791991200000, "state": "closed" },
  "viewerUrl": "https://pebbleaudio.okgodoit.com/d/2026-10-28"
}
```

Neither read is entered in the AI-read log: the plugin polls, and it is not an assistant. Its token's last use
shows in Who can read.
