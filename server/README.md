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
| `docs/research-verified-2026-10-20.md` | Verified facts about the MCP C# SDK, OAuth clients, and the stack |
| [`src/PebbleAudio.Server/Auth/README.md`](src/PebbleAudio.Server/Auth/README.md) | Admin sign-in, bearer tokens, and the OAuth server still to build |

## Current state

Built:

- The data model for the whole sync protocol (`Data/`), with the initial migration: user-scoped tables for
  conversations, transcripts, recaps, briefs, follow-ups, notes, people, coverage days, the sync ledger,
  devices and link codes, phone requests and clips, the job queue, API tokens, the AI-read log, and settings.
  Full-text search is two generated `tsvector` columns with GIN indexes (conversation title, tags, and
  summary; transcript text).
- The MCP server on the official SDK, stateless, at `/mcp`, with one tool: `get_status`.
- Bearer tokens (`pat_…`) for `/mcp`, created and revoked in the admin area; an unauthenticated request gets
  a 401 with `WWW-Authenticate: Bearer resource_metadata="…"`.
- The admin area at `/admin`, passkey-only, one user: status, tokens, passkeys, and settings.
- The Postgres-backed job queue (`Jobs/`) with one `noop` handler.
- Typed settings with defaults, editable at `/admin/settings` (`Settings/`).
- CI and deploy workflows, mirroring Situ.

Not built yet: the sync endpoints (`Sync/`), the OAuth authorization server (`Auth/`), the archive tools,
MCP Events, clips, the import from a Desktop backup, and the conversation viewer.

## Layout

```text
server/
├── PebbleAudio.Server.slnx
├── .config/dotnet-tools.json      dotnet-ef, pinned
├── deploy/                        droplet setup, systemd units, nginx site, deploy and backup scripts
├── docs/
├── src/PebbleAudio.Server/
│   ├── Auth/                      Identity user, setup code, bearer tokens
│   ├── Data/                      ArchiveDbContext (also the Identity store), entities, Migrations/
│   ├── Jobs/                      IJobQueue, JobRunner, JobWorker, handlers
│   ├── Mcp/                       server instructions, tools, the AI-read log
│   ├── Pages/Admin/               Razor Pages for the admin area
│   ├── Settings/                  ArchiveSettings and SettingsService
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

Create a token at `/admin/tokens`. The page shows it once, with the server URL and a ready Claude Code
command:

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
  `/healthz`, and rolls back if it never passes.
- **By hand**: `deploy/scripts/publish-local.sh` builds the same artifact on the Mac, runs the tests, and
  deploys it over SSH as root (`PEBBLEAUDIO_DEPLOY_TARGET`, default `root@pebbleaudio.okgodoit.com`).

Logs: `journalctl -u pebbleaudio -f`. The first start after a fresh database prints the setup code there.
