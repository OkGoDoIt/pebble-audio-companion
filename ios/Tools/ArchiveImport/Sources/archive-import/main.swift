import ArchiveImportCore
import Foundation

// archive-import seeds the Pebble Audio server from one of the phone's Desktop backups, with the
// phone's own export code. See README.md beside Package.swift.

let usage = """
    Usage: archive-import --backup <dir> --server <url> [--code <link code>]
                          [--scope all|since:<date>|last:<days>] [--before <date>|all]
                          [--dry-run] [--limit N]

      --backup   a copy of the app's audio-companion folder (db/, segments/, transcription/)
      --server   the Pebble Audio server, for example https://pebbleaudio.okgodoit.com
      --code     a link code from the server's admin page (Phones › Show a code); later runs
                 reuse the link saved in the Keychain
      --scope    what to send: everything (all), from a date or time on (since:2026-10-01),
                 or the last N days (last:90). Without it, the sharing scope stored on the
                 server, else everything.
      --before   send only what is dated before this date or time; all sends everything.
                 Without it, only what the phone no longer has: what is dated before the
                 phone's own archive on the server begins, and nothing from before the
                 archive was last deleted.
      --dry-run  build and check every payload against the contract, and send nothing
      --limit    send at most N items (after the scope)
    """

func fail(_ message: String, status: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

var backup: String?
var server: String?
var code: String?
var scope: ImportScope?
var before: ImportBoundary?
var dryRun = false
var limit: Int?

var arguments = Array(CommandLine.arguments.dropFirst())[...]
@MainActor func value(_ flag: String) -> String {
    guard let next = arguments.popFirst(), !next.hasPrefix("--") else {
        fail("\(flag) needs a value.\n\n\(usage)")
    }
    return next
}
while let argument = arguments.popFirst() {
    switch argument {
    case "--backup": backup = value(argument)
    case "--server": server = value(argument)
    case "--code": code = value(argument)
    case "--scope":
        let text = value(argument)
        guard let parsed = ImportScope.parse(text) else {
            fail("--scope is all, since:<YYYY-MM-DD or RFC 3339 time>, or last:<days>, not '\(text)'.")
        }
        scope = parsed
    case "--before":
        let text = value(argument)
        guard let parsed = ImportBoundary.parse(text) else {
            fail("--before is a YYYY-MM-DD date, an RFC 3339 time, or all, not '\(text)'.")
        }
        before = parsed
    case "--dry-run": dryRun = true
    case "--limit":
        let text = value(argument)
        guard let n = Int(text), n > 0 else { fail("--limit is a positive number, not '\(text)'.") }
        limit = n
    case "--help", "-h":
        print(usage)
        exit(0)
    default:
        fail("Unknown argument '\(argument)'.\n\n\(usage)")
    }
}
guard let backup else { fail(usage) }
if !dryRun, server == nil {
    fail("Name the server with --server, or check the backup with --dry-run.\n\n\(usage)")
}
let backupURL = URL(fileURLWithPath: (backup as NSString).expandingTildeInPath, isDirectory: true)

ScratchCleanup.shared.installSignalHandlers()
let options = ImportOptions(
    backup: backupURL, server: server, code: code, scope: scope, before: before, dryRun: dryRun,
    limit: limit)
Task {
    do {
        let status = try await ImportRun(options: options).run()
        exit(status)
    } catch {
        ScratchCleanup.shared.removeAll()
        fail("\(error)", status: 1)
    }
}
dispatchMain()
