import AppDB
import Foundation
import SearchKit

// The recovery path for the search index (Settings → Diagnostics → Rebuild Search Index).
//
// `TranscriptIndex.removeAll` and `SpotlightService.resetWatermark` both existed and neither had
// a caller, which meant a stale or corrupted index — a donation pass that died halfway, a
// restore that landed content the watermark had already skipped past — could not be repaired
// short of reinstalling the app.
//
// The index is DERIVED data: everything in it is rewritten from the database, so throwing it
// away costs the time to write it again and nothing else. That is what the row's wording has to
// say, because a button named "rebuild" sitting near "Delete All Data" otherwise reads as
// something that destroys recordings.
@MainActor
struct SearchIndexRebuilder {
    let composition: AppComposition

    /// Empties both search backends and writes them again from the database. Returns the number
    /// of conversations indexed, which is what the result line reports.
    ///
    /// The conversation half deliberately goes through `EnrichmentService.donate` — the SAME
    /// donation the pipeline uses — rather than the lighter one the incremental foreground pass
    /// performs, because only that path carries the transcript text (D7). A rebuild that quietly
    /// produced a title-only index would be a downgrade dressed as a repair.
    func run() async throws -> Int {
        let donator = composition.donator

        // 1. Throw the derived index away: FTS and Core Spotlight together, so a document
        //    cannot survive in one backend and vanish from the other.
        try await donator.removeAll()

        // 2. Forget the incremental watermark. Without this the next foreground pass would
        //    compare against the old high-water mark, conclude nothing had changed, and leave
        //    the index it was meant to refill empty.
        composition.nativeSurfaces?.resetSpotlightWatermark()

        // 3. Conversations (with transcripts) and their follow-ups. Live conversations are
        //    still growing; they land when they end, exactly as the incremental pass has it.
        let rows = try await composition.runtime.library.library()
            .flatMap(\.rows)
            .filter { !$0.isLive }
        let environment = await composition.runtime.environment
        await environment.enrichment.donate(conversationIds: rows.map(\.id))

        // 4. Notes, which belong to a conversation and are not part of the enrichment pass.
        for row in rows {
            for note in try await composition.notes.list(conversationId: row.id) {
                try? await donator.donateNote(
                    id: note.id,
                    title: note.title,
                    body: note.body,
                    createdAtMs: note.createdAtMs
                )
            }
        }

        // 5. Day recaps, whose only other writer is the recap generator — without this they
        //    would stay missing until each day happened to be regenerated.
        for recap in try await composition.recapStore.list() {
            try? await donator.donateRecap(
                dateKey: recap.dateKey,
                text: recap.text,
                createdAtMs: recap.updatedAtMs
            )
        }

        return rows.count
    }
}
