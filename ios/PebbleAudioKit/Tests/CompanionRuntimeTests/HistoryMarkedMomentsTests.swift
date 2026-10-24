import AppDB
import Foundation
import Intelligence
import Testing
import Transcription
@testable import CompanionRuntime

@Suite struct HistoryMarkedMomentsTests {
    @Test func marksSurviveWithoutRecordingsAndRespectTheFiveAMDayBoundary() async throws {
        let db = try AppDatabase.inMemory()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcripts = FileTranscriptStore(root: folder, nowMs: { 0 })
        let reader = HistoryReader(sources: .init(database: db, recaps: DailyRecapStore(db: db),
            audioContent: AudioContentStore(db: db), speechRuns: HistorySpeechRunCache(transcripts: transcripts),
            transcripts: transcripts, segments: { [] }, currentZoneID: { "UTC" }))
        func ms(_ value: String) -> Int64 {
            Int64(ISO8601DateFormatter().date(from: value)!.timeIntervalSince1970 * 1_000)
        }
        let store = MomentStore(db: db)
        for (id, time) in [("before", "2026-10-24T04:59:59Z"), ("after", "2026-10-24T05:00:00Z")] {
            try await store.add(Moment(id: id, wallMs: ms(time), onAudioClock: false,
                                      createdAtMs: ms(time), wasRecording: false))
        }
        let now = ms("2026-10-25T12:00:00Z")
        let library = await reader.library()
        let first = try await reader.day("2026-10-23", library, nowMs: now, isToday: false, isLive: false)
        let second = try await reader.day("2026-10-24", library, nowMs: now, isToday: false, isLive: false)
        #expect(!first.day.hasRecordings)
        #expect(first.moments.map(\.id) == ["before"])
        #expect(second.moments.map(\.id) == ["after"])
        let week = try await reader.week(firstDateKey: "2026-10-19", lastDateKey: "2026-10-25",
                                         library, nowMs: now, isLive: false)
        #expect(week.rows.first { $0.dateKey == "2026-10-23" }?.momentCount == 1)
        #expect(week.rows.first { $0.dateKey == "2026-10-24" }?.momentCount == 1)
        let month = try await reader.month(containing: "2026-10-24", firstWeekday: 2,
                                           library, nowMs: now, isLive: false)
        #expect(month.rows.reduce(0) { $0 + $1.momentCount } == 2)
        let bounds = await reader.bounds(nowMs: now)
        #expect(bounds.firstDateKey == "2026-10-23")
        #expect(bounds.recordedDays == ["2026-10-23", "2026-10-24"])
        try await store.delete(id: "before")
        #expect(await reader.bounds(nowMs: now).firstDateKey == "2026-10-24")
        let updated = try await reader.day("2026-10-23", library, nowMs: now, isToday: false, isLive: false)
        #expect(updated.moments.isEmpty)
    }
}
