# archive-import

Seeds the Pebble Audio server from one of the phone's Desktop backups with what the phone no longer
has. Every payload is built by the iOS app's own export code
(`PebbleAudioKit/Sources/CompanionRuntime/ArchiveSync`), so each item is exactly what the phone would
send for it on linking: the same enumeration
(`ArchiveOutbox.markEverything`), the same builders, the same envelopes, and the same batches
(200 items or 8 MB, `X-Sync-Protocol: 1`). The wire contract is
[`server/docs/sync-protocol.md`](../../../server/docs/sync-protocol.md).

## Build

```sh
cd ios/Tools/ArchiveImport
swift build -c release        # .build/release/archive-import
swift test                    # synthetic fixtures only
```

## Run

A backup is a copy of the app container's `Library/Application Support/audio-companion`
(`db/companion.sqlite` with its `-wal`, `segments/*.meta.json`, `transcription/transcripts/`), for
example `~/Desktop/PebbleAudioBackup/audio-companion-20261015-005220`.

```sh
# Build and check every payload against the contract; nothing is sent, no server needed.
.build/release/archive-import --backup ~/Desktop/PebbleAudioBackup/audio-companion-20261015-005220 --dry-run

# Send it. The code comes from the server's admin page: Phones › Show a code.
.build/release/archive-import --backup <dir> --server https://pebbleaudio.okgodoit.com --code K7QM-3XWD

# Later runs from Terminal reuse the link saved in the Keychain.
.build/release/archive-import --backup <dir> --server https://pebbleaudio.okgodoit.com
```

| Option | What it does |
| --- | --- |
| `--scope all` | Everything (the default when the server holds no sharing scope). |
| `--scope since:2026-10-01` | Only what is dated from that day on (the app's day, from 5 AM, in this Mac's zone). An RFC 3339 time works too. |
| `--scope last:90` | Only the last 90 days. |
| `--before 2026-09-01` | Only what is dated before that day (or RFC 3339 time), instead of before where the phone's own archive begins. Nothing deleted is held back then. |
| `--before all` | Everything in the backup, whatever the phone has sent or the person deleted. |
| `--dry-run` | Builds and checks every payload, prints counts per kind and the first item that fails the check. |
| `--limit N` | Sends at most N items after the scope, in kind order (conversations first). |

By default the import adds only what the phone no longer has. The server says where the phone's own
archive on it begins (`phoneSince` in `GET /sync/status`, the earliest conversation a phone sent) and
when the archive was last deleted (`wipedAt`, by Delete All or unlinking); the import sends what is
dated before the first and not before the second. Without that boundary a conversation the phone has
since re-cut (a segmenter change gives it a new id) would stay on the server next to the new cut, and
what the person deleted would come back; the phone never deletes ids it does not hold, so both would
stay for good. With no phone synced yet it stops and says so: link the phone first. People go only
with something that mentions them. `--before` chooses the boundary by hand.

Without `--scope`, the import uses the sharing scope stored on the server (`GET /sync/preferences`)
when the server has one. Dating follows §5 of the contract: a conversation and its transcript by when
it started, a note by its conversation, a follow-up by when it was said (else when it was written), a
recap and a day's coverage by their day, and a brief by its last day. A day is in scope when it is
the day the cutoff falls in or later. People always go.

It prints one line per batch and a summary per kind: accepted, already held (the server ignored a
version it had), rejected with the server's reason, out of scope, and skipped. The payload digest
at the end is a hash of every item sent; the same backup always gives the same digest. The exit
status is 0 when nothing was rejected or failed the check.

## What it never does

- **Change the backup.** The database is copied to a temporary directory (without its `-shm`), and
  opening the copy replays the WAL into it and runs the app's own migrations. The import's writes
  (the migrations, the audio-content mask load, the outbox it enumerates through) all go into that
  copy, which is removed at the end and on Ctrl-C. Sidecars and transcripts are read in place
  through the app's read-only paths.
- **Touch the phone, or delete anything on the server.** It sends upserts only. Something the phone
  would turn into a delete (a row that vanished) is counted as skipped.
- **Print the device token.** It lives in memory and in the login Keychain (service
  `dev.audiocompanion.archive-import`, one item per server). A run with no terminal (a script, an
  agent) neither reads nor saves it: the Keychain asks on screen before a rebuilt binary uses the
  item, so such a run needs a fresh `--code` each time. After a rebuild, the first run from Terminal
  asks once; choose Always Allow.

## Versions and replays

Every item is sent at one version: the newest change the backup's database records (the latest of
its created, updated, edited, and similar times, read before anything writes to the copy), never the
files' modification dates, which a copy without timestamps moves later. Running the same backup
again sends the same versions, and the server answers them as already held. A newer backup supersedes an older one,
and the phone's own sync, whose versions are the times of each change, supersedes both. The device
shows up on the admin page as "Backup import on <this Mac>". Each `--code` links a new one; it can be
unlinked there once the import is done.

What the phone would mark provisional (a boundary the segmenter may still move) is decided by a live
grouping pass and is not stored, so a backup's closed conversations are sent as not provisional. The
conversation that was recording when the backup was taken is sent as live and provisional, as the
phone sends it.

## Trying it against a local server

```sh
createdb pebbleaudio_import_test
cd server
ConnectionStrings__DefaultConnection="Host=localhost;Database=pebbleaudio_import_test;Username=$USER" \
  PebbleAudio__PublicOrigin=http://localhost:5197 \
  dotnet run --project src/PebbleAudio.Server --urls http://localhost:5197
```

The admin page needs a passkey. To skip it on a scratch database, mint a code straight into it:

```sh
ios/Tools/ArchiveImport/mint-local-link-code.sh pebbleaudio_import_test   # prints a code, valid ten minutes
```

It talks to the local Postgres over its socket only, and creates an `admin` account with no passkey
when the database has none, which makes that database a scratch one. `dropdb pebbleaudio_import_test`
when done.
