# Pebble Audio server: build plan and conventions

The architecture and the decisions are in the workspace report
`AI_AGENT_ARCHIVE_ACCESS_RESEARCH.md` (also a shared doc). The engineering baseline is
`WEB_PROJECT_DEFAULTS.md`. The verified technical facts are `research-verified-2026-10-20.md`
beside this file. The phone ↔ server wire contract is `sync-protocol.md`. Everything below is
the concrete shape this code takes.

## Names and places

| What | Value |
| --- | --- |
| Product name (assistants, Connect screen, OAuth consent) | **Pebble Audio** |
| Hostname | `pebbleaudio.okgodoit.com` (DigitalOcean DNS, A 134.209.0.150 and AAAA) |
| Repo location | `pebble-audio-companion/server/` (this directory), same repo as the app |
| Solution / project | `server/PebbleAudio.Server.slnx`, `server/src/PebbleAudio.Server/` (namespace `PebbleAudio.Server`), tests in `server/tests/PebbleAudio.Server.Tests/` |
| CI | `.github/workflows/server-ci.yml` and `server-deploy.yml`, both filtered to `server/**` |
| Linux users | app `pebbleaudio` (system, no shell), deploy `pebbleaudio-deploy` (key from GitHub Actions, sudo limited to the deploy script) |
| Paths on the droplet | `/opt/pebbleaudio/{releases,current}`, `/etc/pebbleaudio/pebbleaudio.env`, `/var/lib/pebbleaudio/{clips,data-protection-keys}`, `/var/backups/pebbleaudio` |
| Kestrel | `http://127.0.0.1:5090` behind nginx (Situ is on 5080) |
| Database | PostgreSQL 16, database `pebbleaudio`, role `pebbleaudio`, local scram auth |
| Runtime | .NET 10 LTS, framework-dependent `linux-x64` publish against the droplet's `aspnetcore-runtime-10.0` |
| Packages | `ModelContextProtocol.AspNetCore` 2.2.0 and `ModelContextProtocol.Extensions.Apps` 2.2.0 (Apache-2.0), `Npgsql.EntityFrameworkCore.PostgreSQL` 10.x, `Microsoft.AspNetCore.Identity.EntityFrameworkCore` 10.x (passkeys), `Microsoft.EntityFrameworkCore.Tools`, `Microsoft.Extensions.Hosting.Systemd`. Nothing else without a reason written in the commit. |
| Indentation | tabs (Situ's `.editorconfig`, copied to `server/.editorconfig`) |
| Tone of user-facing copy | a touch friendly, never jokey; Oxford comma; American spelling |

## Modules (each a folder under `src/PebbleAudio.Server/`)

| Module | Owns | Notes |
| --- | --- | --- |
| `Data/` | `ArchiveDbContext`, entities, EF Core migrations, the `tsvector` generated column and GIN index, the task-queue table | `timestamptz` everywhere; integer ms for durations; JSONB only for `pieces`, `gaps`, `items`, `spans`, `citations` |
| `Sync/` | `/link`, `/sync/batch`, `/sync/requests`, `/sync/clips/{id}`, `/sync/wipe`, `/sync/status`; device tokens | Minimal APIs; one transaction per batch; versions per `sync-protocol.md` |
| `Mcp/` | the MCP server on the official SDK, stateless 2026-07-28; tools, resources, prompts, `instructions`; `search`/`fetch`; the write tools; `ui://` widget resources | Tool results: `structuredContent` plus the same text in `content`; caps with truncation reporting; `readOnlyHint`/`openWorldHint` on reads; every result carries a viewer link |
| `Auth/` | Identity with passkeys (one user, more later), the OAuth 2.1 authorization server (metadata, authorize, token, register, CIMD), bearer tokens for CLI agents and Muse, the 401 challenge on `/mcp` | Opaque tokens hashed at rest; refresh rotation; `resource` into `aud` |
| `Events/` | MCP Events (`events/list|subscribe|unsubscribe`), subscription store, Standard Webhooks delivery from the queue | `day_recap.ready`, `followup.created` |
| `Clips/` | clip requests, ffmpeg transcode job, signed short-lived links | ffmpeg is a system binary; jobs run on the queue |
| `Jobs/` | the Postgres-backed task queue (`FOR UPDATE SKIP LOCKED`) and `BackgroundService` workers | retries with backoff; dead-letter after N |
| `Import/` | seeds from a Desktop backup directory (DB + transcript JSON + sidecars); ports the piece cut and wall-clock mapping exactly | same code path as sync, fed from files |
| `Pages/Admin/` | Razor Pages: passkey login, devices and link codes, tokens, OAuth clients, event subscriptions, requests, sync status, AI-read log, settings | nothing that needs SSH |
| `Pages/View/` | the conversation viewer `/c/{id}?t=…` and `/d/{day}`; `/.well-known/apple-app-site-association` | plain CSS, ES modules, web components; design candidates first |
| `wwwroot/widgets/` | the MCP Apps widgets (conversation card, day timeline, clip player) | plain HTML + ES modules; served as `ui://` resources |
| `Settings/` | typed settings editable in admin with defaults (caps, TTLs, limits) | business numbers never hard-coded |

## Deploy (mirrors Situ exactly)

GitHub Actions on push to `main` touching `server/**`: restore, build, test, `dotnet publish`
(Release, linux-x64, framework-dependent), `dotnet ef migrations bundle`, package
`app/`, `efbundle`, `nginx/pebbleaudio.conf` and `REVISION` into a tar.gz, `scp` it to
`pebbleaudio-deploy@134.209.0.150:/tmp/`, then `ssh … sudo /opt/pebbleaudio/deploy-pebbleaudio.sh <sha> <tar>`.
The deploy script (in `deploy/scripts/`) unpacks into `releases/<sha>`, dumps the database,
runs the migration bundle, swaps the `current` symlink, restarts the service, waits for
`/healthz`, prunes to the last five releases, and rolls the symlink back on failure. The same
script can be run by hand with an artifact built on the Mac (`deploy/scripts/publish-local.sh`).

Server setup is `deploy/scripts/setup-server.sh` (idempotent, run as root once, and again after
any change to the unit, nginx site or scripts).

## Validation that counts as done

The report's list: seeded from the backup and queried through ChatGPT on the phone with the Mac
off, Claude on web and iOS, Codex and Claude Code; sync end to end on the phone; OAuth sign-in
and refresh with ChatGPT and Claude; bearer with the CLIs; Muse's connector; the battery gate.
Tests are few and broad: sync idempotency and tombstones, OAuth flows replayed from recorded
ChatGPT and Claude requests, the piece cut and wall-clock mapping against fixtures from the
backup, tool caps, webhook signatures.
