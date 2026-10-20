# Pebble Audio server

The archive server for Pebble Audio: one ASP.NET Core 10 app that mirrors the text of the iOS app's
archive (the app lives in [`../ios`](../ios)) so assistants can read it through MCP while the phone is in a
pocket. The iPhone stays the system of record; this server holds a copy of the text, and audio clips only
when one is asked for.

This server is the companion to the iOS app in `../ios`. The architecture and the decisions behind it are
in the workspace report `AI_AGENT_ARCHIVE_ACCESS_RESEARCH.md` (at the root of the `pebble` workspace, outside
this repo). The engineering baseline is the workspace's `WEB_PROJECT_DEFAULTS.md`.

This README is the engineer handoff: layout, local run, migrations, and deploy.

## Docs

| Document | What it is |
| --- | --- |
| [`docs/build-plan.md`](docs/build-plan.md) | Names, paths, packages, and the module layout this code follows |
| [`docs/sync-protocol.md`](docs/sync-protocol.md) | The phone ↔ server wire contract |
| [`docs/tool-results.md`](docs/tool-results.md) | The exact result of every MCP tool, which the widgets and the viewer are built against |
| `docs/research-verified-2026-10-20.md` | Verified facts about the MCP C# SDK, OAuth clients, and the stack |
| [`src/PebbleAudio.Server/Auth/README.md`](src/PebbleAudio.Server/Auth/README.md) | Admin sign-in, bearer tokens, and the OAuth 2.1 authorization server |

## Current state

Built:

- The data model for the whole sync protocol (`Data/`), with the initial migration: user-scoped tables for
  conversations, transcripts, recaps, briefs, follow-ups, notes, people, coverage days, the sync ledger,
  devices and link codes, phone requests and clips, the job queue, API tokens, the AI-read log, and settings.
  Full-text search is two generated `tsvector` columns with GIN indexes (conversation title, tags, and
  summary; transcript text).
- The MCP server on the official SDK, stateless, at `/mcp` (`Mcp/`, results shaped as
  [`docs/tool-results.md`](docs/tool-results.md)): `get_status`, `list_days`, `get_day`, `get_brief`,
  `list_conversations`, `get_conversation`, `search` and `fetch` (ChatGPT's shapes, Postgres full-text with
  `ts_headline` snippets), `list_follow_ups`, `get_people`, `get_tags`, `get_audio` (through
  `PhoneRequestService`), and the write tools `create_follow_up`, `update_follow_up`, and `create_note` (the
  `archive:write` scope and the phone's `edits` permission). Resources `conversation://{id}` and `day://{date}`,
  two prompts, and `instructions` that teach the method of the plugin's `SKILL.md`. Every result is capped by the
  settings and says how to continue; every call is in the AI-read log. All reads go through `ArchiveReader`, which
  applies the sharing scope.
- Bearer tokens (`pat_…`) for `/mcp`, created and revoked in the admin area; an unauthenticated request gets
  a 401 with `WWW-Authenticate: Bearer resource_metadata="…"`.
- The OAuth 2.1 authorization server (`Auth/`, see its README) for ChatGPT, Claude, and Claude Code: metadata,
  authorize with a consent page behind the passkey sign-in, token with PKCE and refresh rotation, dynamic
  registration, client metadata documents, and revocation. `oat_…` access tokens open `/mcp` alongside `pat_…`.
- MCP Events (`Events/`): `events/list`, `events/subscribe` (verified with a signed challenge), and
  `events/unsubscribe`, with `day_recap.ready` and `followup.created` delivered as Standard Webhooks from the job
  queue. Other modules call `IEventPublisher`.
- The admin area at `/admin`, passkey-only, one user: status, linked phones, connected apps and event
  subscriptions, tokens, passkeys, and settings.
- The Postgres-backed job queue (`Jobs/`) with a `noop` handler and `clip.transcode`.
- Typed settings with defaults, editable at `/admin/settings` (`Settings/`).
- The sync half (`Sync/`, the whole of [`docs/sync-protocol.md`](docs/sync-protocol.md)): linking a phone at
  `/admin/phones` (one-time code and QR code), device tokens (`pad_…`, their own scheme, `/link` and `/sync/*`
  only), `PUT /sync/batch`, the request channel and clip uploads, the ffmpeg transcode to m4a, signed clip
  links at `/clips/{id}.m4a`, wipe, status with the assistants that have access, and the phone's preferences.
  Other modules reach the phone through `PhoneRequestService` (`RequestClipAsync`, `CreateFollowUpAsync`,
  `UpdateFollowUpAsync`, `CreateNoteAsync`), which honors those preferences and answers with typed outcomes.
  OAuth grants join the phone's access list by registering an `IConnectedAssistantSource`.
- The sharing scope (`Sync/SharingScope.cs`, `Sync/ScopeSweep.cs`): stored with the preferences, applied to every
  tool query and every batch (items outside are ignored as `outsideScope`), and enforced by a deletion at 03:30
  in the account's time zone (the zone of its latest conversation) and at once when the phone narrows it.
  `DELETE /link` deletes the account's archive and ends every assistant's access with the device's;
  `?keepData=true` only revokes the device.
- Batches announce a recap whose text changed and a follow-up the phone added (recent ones only) through
  `IEventPublisher`.
- CI and deploy workflows, mirroring Situ.

The import from a Desktop backup is a Mac tool beside the app, [`ios/Tools/ArchiveImport`](../ios/Tools/ArchiveImport):
it links like a phone and sends the phone's own payloads.

Not built yet: the MCP Apps widgets and the conversation viewer (tool results and event payloads already link to
its `/c/{id}?t=…`, `/d/{day}`, and `/b/week|month/…` pages).

## Layout

```text
server/
├── PebbleAudio.Server.slnx
├── .config/dotnet-tools.json      dotnet-ef, pinned
├── deploy/                        droplet setup, systemd units, nginx site, deploy and backup scripts
├── docs/
├── src/PebbleAudio.Server/
│   ├── Auth/                      Identity user, setup code, bearer tokens, the OAuth authorization server
│   ├── Data/                      ArchiveDbContext (also the Identity store), entities, Migrations/
│   ├── Events/                    MCP Events: events/* methods, webhook signing and delivery
│   ├── Jobs/                      IJobQueue, JobRunner, JobWorker, handlers
│   ├── Mcp/                       server instructions, tools, the AI-read log
│   ├── Pages/Admin/               Razor Pages for the admin area
│   ├── Settings/                  ArchiveSettings and SettingsService
│   ├── Sync/                      linking, device tokens, batches, requests, clips, wipe, status
│   ├── wwwroot/                   site.css, passkeys.js, admin.js (plain ES modules, no bundler)
│   └── Program.cs
└── tests/PebbleAudio.Server.Tests/
```

## Prerequisites

- .NET 10 SDK (`brew install dotnet`; the Mac has 10.0.302)
- PostgreSQL 16 running locally (Homebrew), with your OS user able to create databases

## Run it locally

```bash
cd server
createdb pebbleaudio            # once
dotnet tool restore             # once, for dotnet ef
dotnet run --project src/PebbleAudio.Server
```

It listens on `http://localhost:5090` and applies migrations on startup in Development
(`Database:MigrateOnStartup` in `appsettings.Development.json`, which also points at
`Host=localhost;Database=pebbleaudio;Username=roger`; change the user name if yours differs).

- `GET /healthz` answers `Healthy` when Postgres answers.
- `/admin` sends you to `/admin/setup` until the first passkey exists. The log prints a setup code at every
  start while none does:

  ```text
  warn: PebbleAudio.Server.Auth.SetupAnnouncer[0]
        No admin passkey exists yet. Open http://localhost:5090/admin/setup and enter the setup code K7QM-3XWD.
  ```

  `PebbleAudio__SetupCode` sets a fixed code as well. After setup, `/admin/setup` answers 404 and the admin
  area signs in with that passkey only. More passkeys can be added at `/admin/passkeys`.

To start over locally: `dropdb pebbleaudio && createdb pebbleaudio`.

## Connect an assistant

ChatGPT, Claude, and Claude Code sign in with OAuth: add `https://pebbleaudio.okgodoit.com/mcp` as a custom
connector (ChatGPT: chatgpt.com/plugins, **+**, Add custom MCP server, Authentication OAuth; Claude: Customize,
Connectors; Claude Code: `claude mcp add --transport http pebble-audio https://pebbleaudio.okgodoit.com/mcp`, then
`/mcp`). The app opens the consent page; sign in with the admin passkey and allow it. Connected apps are listed,
and disconnected, at `/admin/apps`.

For a tool without OAuth, create a token at `/admin/tokens`. The page shows it once, with the server URL and a
ready Claude Code command:

```bash
claude mcp add --transport http pebble-audio https://pebbleaudio.okgodoit.com/mcp \
  --header "Authorization: Bearer pat_…"
```

Revoking a token takes effect on the next request.

## Configuration

| Key (environment variable) | Development | Production |
| --- | --- | --- |
| `ConnectionStrings__DefaultConnection` | local Postgres | `/etc/pebbleaudio/pebbleaudio.env` |
| `PebbleAudio__PublicOrigin` | `http://localhost:5090` | `https://pebbleaudio.okgodoit.com`; the MCP resource, the metadata URL, and every absolute link derive from it, never from the request's host |
| `PebbleAudio__ClipsPath` | `App_Data/clips` | `/var/lib/pebbleaudio/clips` |
| `PebbleAudio__FfmpegPath` | unset (`ffmpeg` on the PATH) | unset; `setup-server.sh` installs Ubuntu's ffmpeg |
| `DataProtection__KeysPath` | `App_Data/data-protection-keys` | `/var/lib/pebbleaudio/data-protection-keys`; required outside Development |
| `PebbleAudio__SetupCode` | unset | optional fixed setup code |
| `ASPNETCORE_URLS` | `http://localhost:5090` (launch profile) | `http://127.0.0.1:5090` |

Business numbers (tool result caps, longest clip, request time to live, job attempts) are not
configuration: they live in the `Settings` table with defaults in `Settings/ArchiveSettings.cs` and are
edited at `/admin/settings`.

## Database and migrations

Migrations own all DDL, including the `pebble_tags_text` SQL function the search column needs. Nothing is
applied by hand.

```bash
cd server
dotnet ef migrations add YourChange \
  --project src/PebbleAudio.Server/PebbleAudio.Server.csproj \
  --startup-project src/PebbleAudio.Server/PebbleAudio.Server.csproj \
  --output-dir Data/Migrations

dotnet ef database update \
  --project src/PebbleAudio.Server/PebbleAudio.Server.csproj \
  --startup-project src/PebbleAudio.Server/PebbleAudio.Server.csproj
```

The EF tools build the model through `Data/ArchiveDbContextFactory.cs` and read
`ConnectionStrings__DefaultConnection` from the environment (default `Host=localhost;Database=pebbleaudio`).
CI fails when the model has changes without a migration (`dotnet ef migrations has-pending-model-changes`).
In production the deploy runs a migration bundle (`efbundle`) before it swaps the release in.

Conventions: every instant is `timestamptz` (a `DateTimeOffset` in UTC; Npgsql rejects other offsets),
durations are integer milliseconds, enums are stored by name and switched on exhaustively (a missed member is
a build error), and JSONB holds only the structured lists (pieces, gaps, people, items, spans, citations) and
the open payloads of phone requests and jobs.

## The job queue

`IJobQueue.EnqueueAsync(type, payload, runAfter)` adds a row to `Jobs`. `JobWorker` claims one due job at a
time with `UPDATE … WHERE "Id" = (SELECT … FOR UPDATE SKIP LOCKED) RETURNING *`, runs the handler registered
for its type, retries with backoff (30 s, doubling, at most an hour), and sets it aside (`DeadLettered`)
after the `JobMaxAttempts` setting. Register a handler with
`builder.Services.AddJobHandler<MyHandler>("my.type")`. Only one instance of the app runs, so at startup any
job still marked running is returned to the queue.

## Tests

```bash
cd server
dotnet test PebbleAudio.Server.slnx
```

The suite starts one test host on a real Postgres database it creates for the run and drops afterwards
(`pebbleaudio_test_<guid>`). It uses the local Postgres as your OS user; set `PEBBLEAUDIO_TEST_POSTGRES` to
another server's connection string (CI uses a `postgres:16` service container). Run the full suite before
every push.

## Deploy

Production is `https://pebbleaudio.okgodoit.com` on the shared DigitalOcean droplet: systemd unit
`pebbleaudio`, nginx in front, Postgres 16 on the same machine. Server setup is `deploy/scripts/setup-server.sh`
(idempotent, run as root).

- **CI**: `.github/workflows/server-ci.yml` builds and tests every push and pull request that touches
  `server/`. `.github/workflows/server-deploy.yml` deploys every push to `main` that touches `server/` (or a
  manual run): build, test, publish (Release, linux-x64, framework-dependent), migration bundle, package,
  `scp` to the droplet, then `sudo /opt/pebbleaudio/deploy-pebbleaudio.sh <sha> <artifact>`. The deploy
  script backs up the database, runs the bundle, swaps the `current` symlink, restarts the service, waits for
  `/healthz`, and rolls back if it never passes. The deploy steps need the repository secrets
  `PEBBLEAUDIO_DEPLOY_SSH_KEY` (the private half of the key whose public half `setup-server.sh <key.pub>` installs for
  `pebbleaudio-deploy`), `PEBBLEAUDIO_DEPLOY_HOST`, `PEBBLEAUDIO_DEPLOY_USER` (`pebbleaudio-deploy`),
  `PEBBLEAUDIO_DEPLOY_KNOWN_HOSTS` (the droplet's host keys as `known_hosts` lines, checked against
  `ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub` on the droplet; SSH then refuses any other key), and optionally
  `PEBBLEAUDIO_DEPLOY_PORT`; until the key is set, the workflow builds and tests only. Without the known hosts
  the run trusts whatever key the droplet answers with, and warns.
- **By hand**: `deploy/scripts/publish-local.sh` builds the same artifact on the Mac, runs the tests, and
  deploys it over SSH as root (`PEBBLEAUDIO_DEPLOY_TARGET`, default `root@pebbleaudio.okgodoit.com`).

Logs: `journalctl -u pebbleaudio -f`. The first start after a fresh database prints the setup code there.
