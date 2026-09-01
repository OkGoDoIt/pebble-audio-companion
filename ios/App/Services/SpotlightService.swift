import AppDB
import CoreSpotlight
import Foundation
import SearchKit

// System search (plan 6.8: "Spotlight donation ported — persistent index this time, old D7").
// The kit owns the mapping (`SpotlightDonator`), the FTS index (`TranscriptIndex`), and the
// Core Spotlight backend (`CoreSpotlightIndexer`). This file is the app-side driver: WHEN the
// donation pass runs, WHAT it feeds in, and where a tapped result goes.
//
// The pass is incremental on purpose (anti-B17): a foreground donation of the whole library on
// every activation would be a disk-read storm. Only conversations that ended after the last
// pass — and their notes — are re-donated; a first run (or a Spotlight reset) does one full
// build and records the watermark.

/// Drives Spotlight donation from the app lifecycle and resolves tapped results to routes.
@MainActor
final class SpotlightService {
    private static let watermarkKey = "spotlight_last_donation_ms"

    private let database: AppDatabase
    private let donator: SpotlightDonator
    private let defaults: UserDefaults
    /// A conversation's full transcript, for the index body.
    ///
    /// This pass used to donate `title + summary` and nothing else. Because a donation REPLACES
    /// the document (delete-then-insert), every foreground pass quietly overwrote the
    /// transcript-bearing document that enrichment had written with a summary-only one — so the
    /// searchable text of a conversation decayed to a sentence shortly after it was recorded.
    /// Searching for a phrase somebody actually said then found nothing.
    private let transcript: @Sendable (String) async -> String?
    /// One pass at a time; a re-entrant foreground (app switcher scrubbing) is a no-op.
    private var isDonating = false

    init(
        database: AppDatabase,
        donator: SpotlightDonator? = nil,
        defaults: UserDefaults = SharedAppGroup.defaults,
        transcript: @escaping @Sendable (String) async -> String? = { _ in nil }
    ) {
        self.database = database
        self.transcript = transcript
        self.donator =
            donator
            ?? SpotlightDonator(
                index: TranscriptIndex(database: database),
                spotlight: CoreSpotlightIndexer()
            )
        self.defaults = defaults
    }

    /// Called when the app becomes active. Never throws into the caller — a failed donation
    /// costs search freshness, nothing else, and must not disturb the capture pipeline.
    func donateOnForeground() async {
        guard !isDonating else { return }
        isDonating = true
        defer { isDonating = false }

        let watermark = (defaults.object(forKey: Self.watermarkKey) as? NSNumber)?.int64Value ?? 0
        do {
            let donatedThrough = try await donateChanged(since: watermark)
            if donatedThrough > watermark {
                defaults.set(NSNumber(value: donatedThrough), forKey: Self.watermarkKey)
            }
        } catch {
            // Search staleness is recoverable on the next activation; log-and-continue.
            #if DEBUG
                print("[spotlight] donation pass failed: \(error)")
            #endif
        }
    }

    /// Donates every conversation that changed after `watermark`, plus that conversation's
    /// notes. Returns the newest timestamp seen, which becomes the next watermark.
    @discardableResult
    private func donateChanged(since watermark: Int64) async throws -> Int64 {
        let sections = try await ConversationQueries(db: database).library()
        let notes = NotesStore(db: database)
        var newest = watermark

        for section in sections {
            for row in section.rows {
                // Live conversations are still growing; donating them mid-flight would index a
                // partial transcript and then have to correct itself. They land when they end.
                guard !row.isLive else { continue }
                let changedAtMs = max(row.endMs, row.startMs)
                newest = max(newest, changedAtMs)
                guard changedAtMs > watermark else { continue }

                try await donator.donateConversation(
                    conversationId: row.id,
                    title: row.title,
                    summary: row.summary,
                    tags: row.tags,
                    fullTranscript: await transcript(row.id),
                    startDateMs: row.startMs,
                    createdAtMs: row.startMs
                )

                for note in try await notes.list(conversationId: row.id) {
                    let noteChangedAt = note.editedAtMs ?? note.createdAtMs
                    newest = max(newest, noteChangedAt)
                    try await donator.donateNote(
                        id: note.id,
                        title: note.title,
                        body: note.body,
                        createdAtMs: note.createdAtMs
                    )
                }
            }
        }
        return newest
    }

    /// Forces the next pass to rebuild everything (used after a "clear index" / restore).
    func resetWatermark() {
        defaults.removeObject(forKey: Self.watermarkKey)
    }

    // MARK: - Tapped results

    /// Resolves a Spotlight continuation activity to a `companion://` route.
    ///
    /// Pure and static so the app can call it straight from `.onContinueUserActivity` — the
    /// route then goes through the same `router.navigate(to:)` as every other entry point.
    nonisolated static func route(for activity: NSUserActivity) -> Route? {
        guard activity.activityType == CSSearchableItemActionType,
            let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
            let parsed = SpotlightDonation.parse(uniqueIdentifier: identifier)
        else { return nil }
        let link = SpotlightDonator.deepLink(kind: parsed.kind, entityId: parsed.entityId)
        return URL(string: link).flatMap(Route.parse)
    }
}
