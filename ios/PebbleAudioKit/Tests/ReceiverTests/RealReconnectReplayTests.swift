import Foundation
import Receiver
import SegmentStore
import Testing
import WireProtocol

// The reconnects in a real backup, replayed through the real receiver and the real store.
//
// WHY THIS EXISTS. On 2026-09-29 a read-only pass over the phone's 858 sidecars found audio that
// was lost at link drops and recorded NOWHERE: the watch recycles its oldest 4 KB spool chunk
// when it cannot grow (`spool.c` `prv_drop_oldest_chunk`) and records a gap only for frames it
// had not yet sent, so frames it had sent into a dying link vanish without a record — the
// firmware leaves them to "the receiver's own sequence check". The receiver could not make that
// check: a RESUME re-announcement started its stream context with no sequence base and adopted
// the first notice's sequence, so the hole between the last frame it stored and the watch's
// first overflow gap was never compared against anything. Today and Live painted those holes as
// recorded; the widget painted them as quiet.
//
// The backup cannot give us the wire traffic, but it gives us every piece that matters for one
// reconnect: the last frame stored before the drop, the gap records the watch reported at the
// reconnect, and the first frame stored after it. This suite rebuilds that exchange —
// STREAM_START(RESUME) → the watch's held gap notices → the buffered audio — for every reconnect
// the backup shows with that shape, runs it through `AudioReceiverSession` + `SegmentStore`, and
// counts how much of the hole ended up with a loss record.
//
// Event selection is the investigation's rule, so the numbers line up with its report: an
// overflow gap whose preceding sequence is neither stored nor covered by any record, within 60 s
// of a link drop in the flight recorder (`diagnostics/companion*.log`). Relies on the firmware
// invariant `sampleIndex == sequence × frameSamples`, which holds for all 28.7 M frames in the
// 2026-09-29 backup.
//
// Measured 2026-09-30 against `audio-companion-20260929-230453`: 32 reconnects (29 continuing
// their segment, 3 opening a new one), 115,905 frames of hole between them. Through the receiver
// and store as they were, 14,423 of those frames (288.5 s) ended up with no record at all; with
// the resume seeded from the store and the store merging in sequence order, none.
//
// Gated: set PEBBLE_GAP_BACKUP to a backup root (the directory holding `segments/` and
// `diagnostics/`). It reads ~1 GB of frame-log headers, so it never runs by default.

private let backupRoot: String? = ProcessInfo.processInfo.environment["PEBBLE_GAP_BACKUP"]

private var backupAvailable: Bool {
    guard let backupRoot else { return false }
    return FileManager.default.fileExists(atPath: backupRoot + "/segments")
}

// MARK: - reading the backup

/// Sequence numbers in one frame log, header-only (payloads are skipped, not copied).
private func storedSequences(_ url: URL) -> [UInt32] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    var result: [UInt32] = []
    data.withUnsafeBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        var offset = 0
        while offset + 14 <= bytes.count {
            let seq =
                UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            let len = Int(bytes[offset + 12]) | Int(bytes[offset + 13]) << 8
            if offset + 14 + len > bytes.count { break }
            result.append(seq)
            offset += 14 + len
        }
    }
    return result
}

/// Wall-clock ms of every moment the flight recorder saw a stream end or begin on the phone.
private func linkEvents(_ root: String) -> [(down: Int64, up: Int64)] {
    let dir = URL(fileURLWithPath: root + "/diagnostics")
    let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasPrefix("companion") && $0.pathExtension == "log" }
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
    var lines: [String] = []
    for file in files {
        lines += ((try? String(contentsOf: file, encoding: .utf8)) ?? "").components(separatedBy: "\n")
    }
    func stamp(_ line: String) -> Int64? {
        guard line.count >= 28, let date = parser.date(from: String(line.prefix(28))) else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
    var events: [(down: Int64, up: Int64)] = []
    var open: Int64?
    for line in lines.sorted() {
        if line.contains("session streaming("), line.contains(") -> "), let t = stamp(line) {
            if let down = open { events.append((down, down)) }
            open = t
        } else if line.contains("-> streaming("), let down = open, let t = stamp(line) {
            events.append((down, t))
            open = nil
        }
    }
    if let down = open { events.append((down, down)) }
    return events
}

private struct ReconnectEvent {
    let streamId: UInt32
    /// Last sequence stored before the drop.
    let lastStored: UInt32
    /// First sequence stored after it.
    let firstAfter: UInt32
    /// The watch's gap records inside the hole, in sequence order: what it re-sent on reattach.
    let watchGaps: [GapMeta]
    /// True when the backup put the audio on both sides of the hole in ONE segment (the RESUME
    /// continued it); false when the reconnect opened a new segment.
    let sameSegment: Bool
    let template: SegmentMeta
    /// Frames of the hole the backup has no record for — the investigation's number.
    let unrecordedInBackup: Int
}

private func reconnectEvents(_ root: String) -> [ReconnectEvent] {
    let reader = SegmentFileReader(root: URL(fileURLWithPath: root))
    let metas = reader.listSegments()
    struct Stored { var seq: UInt32; var segment: String }
    var framesByStream: [UInt32: [Stored]] = [:]
    var gapsByStream: [UInt32: [(gap: GapMeta, segment: String)]] = [:]
    var metaById: [String: SegmentMeta] = [:]
    for meta in metas {
        metaById[meta.segmentId] = meta
        let log = URL(fileURLWithPath: root + "/segments/" + meta.segmentId + SegmentStore.logSuffix)
        framesByStream[meta.streamId, default: []] +=
            storedSequences(log).map { Stored(seq: $0, segment: meta.segmentId) }
        gapsByStream[meta.streamId, default: []] += meta.gaps.map { ($0, meta.segmentId) }
    }
    let drops = linkEvents(root)

    var events: [ReconnectEvent] = []
    for (streamId, unsorted) in framesByStream {
        var frames = unsorted.sorted { $0.seq < $1.seq }
        frames = frames.enumerated().filter { $0.offset == 0 || frames[$0.offset - 1].seq != $0.element.seq }
            .map(\.element)
        let seqs = frames.map(\.seq)
        let gaps = (gapsByStream[streamId] ?? []).filter { $0.gap.missingFrameCount > 0 }
        func covered(_ x: UInt32) -> Bool {
            gaps.contains { UInt64($0.gap.firstMissingSequence) <= UInt64(x) && UInt64(x) < UInt64($0.gap.firstMissingSequence) + UInt64($0.gap.missingFrameCount) }
        }
        func lowerBound(_ x: UInt32) -> Int {
            var lo = 0
            var hi = seqs.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if seqs[mid] < x { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        var firstGapForRun: [UInt32: UInt32] = [:]  // run start -> earliest overflow gap start
        for (gap, _) in gaps
        where gap.origin == GapMeta.originWatch && gap.reasonRaw == Int(GapReason.spoolOverflow.rawValue) {
            let g0 = gap.firstMissingSequence
            guard g0 > 0 else { continue }
            let i = lowerBound(g0 - 1)
            if i < seqs.count, seqs[i] == g0 - 1 { continue }
            if covered(g0 - 1) { continue }
            guard i > 0 else { continue }
            let lo = seqs[i - 1] + 1
            firstGapForRun[lo] = min(firstGapForRun[lo] ?? g0, g0)
        }
        for (lo, g0) in firstGapForRun {
            let prevIndex = lowerBound(lo) - 1
            let nextIndex = lowerBound(g0)
            guard prevIndex >= 0, nextIndex < frames.count else { continue }
            let prev = frames[prevIndex]
            let next = frames[nextIndex]
            guard let meta = metaById[prev.segment] else { continue }
            // Phone time of the last stored frame, through its own segment's watch→phone offset.
            let rate = Int64(meta.sampleRateHz)
            let firstSample = Int64(meta.firstSampleIndex ?? 0)
            let offset = meta.receivedAtMs - (Int64(meta.startTimeMs) + firstSample * 1000 / rate)
            let phone =
                Int64(meta.startTimeMs) + Int64(prev.seq) * Int64(meta.frameSamples) * 1000 / rate + offset
            let near = drops.contains { abs(phone - $0.down) <= 60_000 || abs(phone - $0.up) <= 60_000 }
            guard near else { continue }
            let hole = gaps.map(\.gap)
                .filter { $0.firstMissingSequence >= lo && $0.firstMissingSequence < next.seq }
                .sorted { $0.firstMissingSequence < $1.firstMissingSequence }
            let unrecorded = (lo..<g0).filter { !covered($0) }.count
            events.append(
                ReconnectEvent(
                    streamId: streamId, lastStored: prev.seq, firstAfter: next.seq,
                    watchGaps: hole.filter { $0.origin == GapMeta.originWatch },
                    sameSegment: prev.segment == next.segment, template: meta,
                    unrecordedInBackup: unrecorded))
        }
    }
    return events.sorted { ($0.streamId, $0.lastStored) < ($1.streamId, $1.lastStored) }
}

// MARK: - the replay

private struct ReplayOutcome {
    var holeFrames = 0
    var recordedLoss = 0
    var phantomLoss = 0
}

private func replay(_ event: ReconnectEvent) async throws -> ReplayOutcome {
    let harness = try StoreBackedSession()
    let template = event.template
    func start() -> StreamStart {
        StreamStart(
            protocolVersion: 1, streamId: event.streamId, codecIdRaw: template.codecIdRaw,
            channels: template.channels, frameSamples: template.frameSamples,
            sampleRateHz: template.sampleRateHz, bitRateBps: template.bitRateBps,
            frameDurationMs: template.frameDurationMs, startTimeMs: template.startTimeMs,
            startMonotonicMs: template.startMonotonicMs, flags: ProtocolConstants.streamStartFlagResume)
    }
    let frameSamples = UInt64(template.frameSamples)
    func data(_ first: UInt32, _ count: Int) -> StreamData {
        StreamData(
            streamId: event.streamId, firstSequence: first,
            firstSampleIndex: UInt64(first) * frameSamples, flags: 0,
            frames: (0..<count).map { _ in [UInt8](repeating: 0x5A, count: 20) })
    }

    // 1. The stream as it stood before the drop: audio stored through `lastStored`.
    try await harness.connectAndAuthorize()
    harness.link.pushData(start())
    try await harness.push(data(event.lastStored - 7, 8))

    // 2. The drop, and the time the phone spent away.
    try await harness.disconnect()
    await harness.clock.advance(by: event.sameSegment ? 5_000 : 11 * 60_000)

    // 3. The reattach: the watch drains its pending gap table (these reach the phone before the
    //    re-announced STREAM_START — 30-150 ms ahead on 2026-09-09), re-announces the stream,
    //    and sends the audio it buffered.
    try await harness.connectAndAuthorize()
    for gap in event.watchGaps {
        harness.link.pushData(
            StreamGap(
                streamId: event.streamId, firstMissingSequence: gap.firstMissingSequence,
                missingFrameCount: gap.missingFrameCount,
                firstMissingSampleIndex: UInt64(gap.firstMissingSequence) * frameSamples,
                reasonRaw: UInt8(clamping: gap.reasonRaw ?? 0),
                watchDropCounter: gap.watchDropCounter ?? 0))
    }
    harness.link.pushData(start())
    try await harness.push(data(event.firstAfter, 8))
    try await harness.disconnect()

    // 4. What the store now says about the hole.
    let hole = UInt64(event.lastStored) + 1..<UInt64(event.firstAfter)
    var loss: [Range<UInt64>] = []
    for meta in await harness.segments() {
        for gap in meta.gaps where gap.missingFrameCount > 0 {
            if let raw = gap.reasonRaw, UInt8(exactly: raw).flatMap(GapReason.init(rawValue:))?.isSilence == true {
                continue
            }
            let lower = UInt64(gap.firstMissingSequence)
            loss.append(lower..<(lower + UInt64(gap.missingFrameCount)))
        }
    }
    loss.sort { $0.lowerBound < $1.lowerBound }
    var merged: [Range<UInt64>] = []
    for range in loss {
        if let last = merged.last, range.lowerBound <= last.upperBound {
            merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
        } else {
            merged.append(range)
        }
    }
    var outcome = ReplayOutcome()
    outcome.holeFrames = hole.count
    let storedRange = UInt64(event.lastStored - 7)..<UInt64(event.lastStored) + 1
    for range in merged {
        outcome.recordedLoss += max(0, Int(min(range.upperBound, hole.upperBound)) - Int(max(range.lowerBound, hole.lowerBound)))
        outcome.phantomLoss += max(
            0, Int(min(range.upperBound, storedRange.upperBound)) - Int(max(range.lowerBound, storedRange.lowerBound)))
    }
    return outcome
}

// MARK: - the measurement

@Suite(
    "Reconnect loss replayed from a real backup",
    .enabled(if: backupAvailable, "set PEBBLE_GAP_BACKUP to a backup root"),
    .serialized
)
struct RealReconnectReplayTests {
    @Test("every frame of a reconnect hole ends up inside a loss record")
    func reconnectHolesAreRecordedAsLoss() async throws {
        let events = reconnectEvents(backupRoot!)
        try #require(!events.isEmpty, "no reconnect events found in the backup")
        var total = ReplayOutcome()
        var unrecordedInBackup = 0
        var same = 0
        for event in events {
            let outcome = try await replay(event)
            total.holeFrames += outcome.holeFrames
            total.recordedLoss += outcome.recordedLoss
            total.phantomLoss += outcome.phantomLoss
            unrecordedInBackup += event.unrecordedInBackup
            if event.sameSegment { same += 1 }
            let missing = outcome.holeFrames - outcome.recordedLoss
            print(
                "gap-replay: stream \(event.streamId) hole [\(event.lastStored + 1), \(event.firstAfter)) "
                    + "\(outcome.holeFrames) frames, \(event.watchGaps.count) watch record(s), "
                    + (event.sameSegment ? "same segment" : "new segment")
                    + ": recorded \(outcome.recordedLoss), unrecorded \(missing)"
                    + " (backup: \(event.unrecordedInBackup) unrecorded before the first overflow record)")
        }
        let unrecorded = total.holeFrames - total.recordedLoss
        print(
            "gap-replay: \(events.count) reconnects (\(same) same-segment), \(total.holeFrames) hole frames; "
                + "recorded as loss \(total.recordedLoss), unrecorded \(unrecorded) "
                + "(\(String(format: "%.1f", Double(unrecorded) * 0.02)) s); phantom loss over stored audio "
                + "\(total.phantomLoss); backup had \(unrecordedInBackup) unrecorded before the first overflow record")
        #expect(unrecorded == 0, "loss at a reconnect must always be recorded")
        #expect(total.phantomLoss == 0, "audio that was stored must never be recorded as lost")
    }
}
