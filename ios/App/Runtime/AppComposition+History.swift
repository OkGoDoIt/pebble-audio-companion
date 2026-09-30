import AppDB
import CompanionRuntime
import Foundation
import Transcription

// The History tab's live source, built from the graph (`install` calls this for the live world;
// `-demo-data` keeps `MockHistory`).

extension AppComposition {
    func makeHistory(today: LiveTodayDataSource) -> LiveHistory {
        let store = self.store
        let runtime = self.runtime
        let reader = HistoryReader(
            sources: HistoryReader.Sources(
                database: database, recaps: recapStore, audioContent: audioContentStore,
                speechRuns: HistorySpeechRunCache(transcripts: transcripts), transcripts: transcripts,
                segments: { await store.listSegments() },
                hiddenConversationIds: { await runtime.environment.deferredDeletes.hiddenConversationIds },
                currentZoneID: { TimeZone.current.identifier }))
        let clock = self.clock
        return LiveHistory(
            backend: ReaderHistoryBackend(reader: reader, database: database),
            now: { clock.nowMs },
            // Today's live snapshot — the one Today and the Live screen already keep — never a
            // second walk of the live transcript.
            liveState: { Self.historyLiveState(today.liveSnapshot()) },
            liveStates: {
                let updates = today.liveUpdates()
                return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                    let task = Task { @MainActor in
                        for await snapshot in updates { continuation.yield(Self.historyLiveState(snapshot)) }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            })
    }

    static func historyLiveState(_ snapshot: LiveSnapshot) -> HistoryLiveState {
        HistoryLiveState(isLive: snapshot.isLive, line: LiveTodayDataSource.liveSnippet(snapshot))
    }
}
