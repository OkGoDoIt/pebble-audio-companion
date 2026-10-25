import Foundation
import Synchronization

/// Original decoded watch/phone audio, already split at every capture discontinuity.
/// Unlike enrollment evidence, this input makes no claim that speech or one speaker is present.
public struct SpeakerAnalysisAudio: Sendable {
    public let pcm16LE: Data
    public let sourceID: String
    public let sourceRevision: String
    public let sessionID: String
    public let sourceStartSample: Int
    public init(pcm16LE: Data, sourceID: String, sourceRevision: String,
                sessionID: String, sourceStartSample: Int) {
        self.pcm16LE = pcm16LE; self.sourceID = sourceID; self.sourceRevision = sourceRevision
        self.sessionID = sessionID; self.sourceStartSample = sourceStartSample
    }
}

public struct SpeakerTurn: Codable, Sendable, Equatable {
    /// Absolute sample coordinates in the input source (16 samples per millisecond).
    public let startSample: Int
    public let endSample: Int
    /// Anonymous within this analysis only. Never a named/person identity.
    public let clusterID: String?
    /// Extracted from THIS clean interval, never borrowed from a neighboring turn.
    public let embedding: SpeakerEmbedding?
    public let overlap: Bool
    public let speechConfidence: Double
    public init(startSample: Int, endSample: Int, clusterID: String?, embedding: SpeakerEmbedding?,
                overlap: Bool, speechConfidence: Double) {
        self.startSample = startSample; self.endSample = endSample; self.clusterID = clusterID
        self.embedding = embedding; self.overlap = overlap; self.speechConfidence = speechConfidence
    }
}

public struct SpeakerAnalysis: Codable, Sendable {
    public let turns: [SpeakerTurn]
    public let recipeID: String
    public let elapsedMilliseconds: Double
    public init(turns: [SpeakerTurn], recipeID: String, elapsedMilliseconds: Double) {
        self.turns = turns; self.recipeID = recipeID; self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public protocol SpeakerSpeechAnalyzing: Sendable {
    func setEnabled(_ enabled: Bool) async
    func analyze(_ audio: SpeakerAnalysisAudio) async throws -> SpeakerAnalysis
    func release() async
}

/// Optional local segmentation + embedding clustering, independent of the transcription provider.
/// Handles are lazy and local; model installation is a separate explicit action.
public final class LocalSpeakerDiarizer: SpeakerSpeechAnalyzing {
    private struct Authorization: Sendable { var enabled = false; var generation: UInt64 = 0 }
    private let authorization = Mutex(Authorization())
    private let segmentation: any SpeakerSegmentationEngine
    private let embedding: CactusSpeakerEmbeddingProvider
    private let model: CoreMLSegmentationModel
    public static let recipeID = "coreml-community1-" + CoreMLSegmentationModel.revision
        + "-single-window-10s-powerset-0.55-overlap-0.35-cluster-0.55-margin-0.10-subwindows-v2"

    public init(embeddingModelDirectory: URL, segmentationModelDirectory: URL) {
        embedding = CactusSpeakerEmbeddingProvider(model: CactusSpeakerModel(directory: embeddingModelDirectory))
        segmentation = CoreMLSegmentationEngine()
        model = CoreMLSegmentationModel(directory: segmentationModelDirectory)
    }

    init(embedding: CactusSpeakerEmbeddingProvider, segmentation: any SpeakerSegmentationEngine,
         model: CoreMLSegmentationModel) {
        self.embedding = embedding; self.segmentation = segmentation; self.model = model
    }

    public func setEnabled(_ enabled: Bool) async {
        authorization.withLock {
            if $0.enabled != enabled { $0.enabled = enabled; $0.generation &+= 1 }
        }
        await embedding.setEnabled(enabled)
        if !enabled { await segmentation.release() }
    }

    public func release() async {
        await embedding.releaseModel()
        await segmentation.release()
    }

    public func analyze(_ audio: SpeakerAnalysisAudio) async throws -> SpeakerAnalysis {
        let generation = try authorization.withLock {
            guard $0.enabled else { throw SpeakerRecognitionError.disabled }
            return $0.generation
        }
        guard audio.pcm16LE.count.isMultiple(of: 2), (3_200...960_000).contains(audio.pcm16LE.count),
              audio.sourceStartSample >= 0,
              !audio.sourceStartSample.addingReportingOverflow(audio.pcm16LE.count / 2).overflow,
              !audio.sourceID.isEmpty, !audio.sourceRevision.isEmpty, !audio.sessionID.isEmpty else {
            throw SpeakerRecognitionError.invalidAudio("Analyze 0.1–30 seconds of gap-free 16 kHz mono PCM16LE with source provenance")
        }
        let cancelled = Mutex(false)
        let check: @Sendable () throws -> Void = { [self] in
            if cancelled.withLock({ $0 }) { throw CancellationError() }
            try authorization.withLock {
                guard $0.enabled, $0.generation == generation else { throw SpeakerRecognitionError.disabled }
            }
        }
        return try await withTaskCancellationHandler {
            try await run(audio, authorize: check)
        } onCancel: { cancelled.withLock { $0 = true } }
    }

    private struct Interval { var start: Int; var end: Int; let kind: Int; var confidence: Double }
    private struct Cluster { let id: String; var examples: [SpeakerEmbedding] }

    private func run(_ audio: SpeakerAnalysisAudio,
                     authorize: @escaping @Sendable () throws -> Void) async throws -> SpeakerAnalysis {
        try Task.checkCancellation()
        let started = Date()
        var turns: [SpeakerTurn] = []
        var clusters: [Cluster] = []
        let sampleCount = audio.pcm16LE.count / 2
        for offset in stride(from: 0, to: sampleCount, by: 160_000) {
            try authorize(); try Task.checkCancellation()
            let windowEnd = min(offset + 160_000, sampleCount)
            let pcm = audio.pcm16LE.subdata(in: (offset * 2)..<(windowEnd * 2))
            let scores = try await segmentation.scores(pcm16LE: pcm, model: model, authorize: authorize)
            try authorize()
            let intervals = Self.splitForEmbeddings(Self.intervals(scores, sampleCount: windowEnd - offset))
            var embeddings: [Int: SpeakerEmbedding] = [:]
            for (index, interval) in intervals.enumerated() where (1...3).contains(interval.kind) {
                // Short turns are represented but cannot become biometric enrollment evidence.
                guard interval.end - interval.start >= 32_000 else { continue }
                let start = offset + interval.start
                let end = offset + interval.end
                let evidence = SpeakerAudioEvidence(sourceID: audio.sourceID, sourceRevision: audio.sourceRevision,
                    sessionID: audio.sessionID, startSample: audio.sourceStartSample + start,
                    endSample: audio.sourceStartSample + end, speechOnly: true,
                    singleSpeaker: true, containsDiscontinuity: false)
                do {
                    let result = try await embedding.embedding(for: SpeakerAudioSample(
                        pcm16LE: audio.pcm16LE.subdata(in: (start * 2)..<(end * 2)), evidence: evidence))
                    embeddings[index] = result.embedding
                } catch SpeakerRecognitionError.invalidAudio { continue }
                try authorize()
            }
            // A local segmentation slot can miss a voice change. Compare each bounded
            // subwindow independently; never average all audio assigned to that slot.
            var intervalClusters: [Int: String] = [:]
            var clusterSlots: [String: Int] = [:]
            for (index, interval) in intervals.enumerated() where (1...3).contains(interval.kind) {
                guard let value = embeddings[index] else { continue }
                let ranked = try clusters.indices.filter {
                    clusterSlots[clusters[$0].id] == nil || clusterSlots[clusters[$0].id] == interval.kind
                }.compactMap { candidate -> (Int, Double)? in
                    guard let mean = try Self.centroid(clusters[candidate].examples) else { return nil }
                    return (candidate, try value.cosineSimilarity(to: mean))
                }.sorted { $0.1 > $1.1 }
                let chosen: Int
                if let best = ranked.first, best.1 >= 0.55,
                   ranked.count == 1 || best.1 - ranked[1].1 >= 0.10 {
                    chosen = best.0
                    clusters[chosen].examples.append(value)
                } else {
                    chosen = clusters.count
                    clusters.append(Cluster(id: "\(audio.sourceID):\(audio.sourceStartSample):speaker-\(chosen + 1)", examples: [value]))
                }
                intervalClusters[index] = clusters[chosen].id
                clusterSlots[clusters[chosen].id] = interval.kind
            }
            var shortSlotClusters: [Int: String] = [:]
            for (index, interval) in intervals.enumerated() {
                var clusterID = intervalClusters[index]
                if clusterID == nil, (1...3).contains(interval.kind) {
                    let candidates = Set(intervals.indices.filter { intervals[$0].kind == interval.kind }
                        .compactMap { intervalClusters[$0] })
                    if candidates.count == 1 { clusterID = candidates.first }
                    else {
                        if shortSlotClusters[interval.kind] == nil {
                            let id = "\(audio.sourceID):\(audio.sourceStartSample):speaker-\(clusters.count + 1)"
                            clusters.append(Cluster(id: id, examples: [])); shortSlotClusters[interval.kind] = id
                        }
                        clusterID = shortSlotClusters[interval.kind]
                    }
                }
                turns.append(SpeakerTurn(startSample: audio.sourceStartSample + offset + interval.start,
                    endSample: audio.sourceStartSample + offset + interval.end,
                    clusterID: clusterID, embedding: embeddings[index],
                    overlap: interval.kind == 4, speechConfidence: interval.confidence))
            }
        }
        try authorize(); try Task.checkCancellation()
        return SpeakerAnalysis(turns: turns, recipeID: Self.recipeID,
            elapsedMilliseconds: Date().timeIntervalSince(started) * 1_000)
    }

    /// Split a >=4s clean span into disjoint 2–3.34s observations. This provides multiple
    /// independent exemplars during guided enrollment and bounds missed-change contamination.
    private static func splitForEmbeddings(_ intervals: [Interval]) -> [Interval] {
        intervals.flatMap { interval in
            let length = interval.end - interval.start
            guard (1...3).contains(interval.kind), length >= 64_000 else { return [interval] }
            let count = max(2, (length + 47_999) / 48_000)
            return (0..<count).map { index in
                Interval(start: interval.start + index * length / count,
                    end: interval.start + (index + 1) * length / count,
                    kind: interval.kind, confidence: interval.confidence)
            }
        }
    }

    private static func centroid(_ embeddings: [SpeakerEmbedding]) throws -> SpeakerEmbedding? {
        guard let first = embeddings.first else { return nil }
        var sum = [Float](repeating: 0, count: first.values.count)
        for embedding in embeddings {
            guard embedding.recipe == first.recipe else { throw SpeakerRecognitionError.incompatibleRecipe }
            for index in sum.indices { sum[index] += embedding.values[index] }
        }
        return try SpeakerEmbedding(recipe: first.recipe, values: sum)
    }

    /// The model's 589 frames span a padded 10 seconds, even for a shorter final window.
    /// Powerset 0=silence, 1/2/3=one local slot, 4/5/6=two overlapping local slots.
    private static func intervals(_ scores: [Float], sampleCount: Int) -> [Interval] {
        var result: [Interval] = []
        for frame in 0..<589 {
            let start = frame * 160_000 / 589
            guard start < sampleCount else { break }
            let end = min((frame + 1) * 160_000 / 589, sampleCount)
            let p = Array(scores[(frame * 7)..<(frame * 7 + 7)])
            let best = p.indices.max { p[$0] < p[$1] } ?? 0
            let overlapping = p[4] + p[5] + p[6]
            let kind: Int
            if overlapping >= 0.35 || best >= 4 { kind = 4 }
            else if (1...3).contains(best), p[best] >= 0.55 { kind = best }
            else if 1 - p[0] >= 0.65 { kind = 5 } // Speech, identity uncertain.
            else { kind = 0 }
            guard kind != 0 else { continue }
            let confidence = Double(1 - p[0])
            if let last = result.last, last.kind == kind, start - last.end <= 2_400 {
                result[result.count - 1].confidence = min(last.confidence, confidence)
                result[result.count - 1].end = end
            } else { result.append(Interval(start: start, end: end, kind: kind, confidence: confidence)) }
        }
        return result.filter { $0.end - $0.start >= 1_600 } // Preserve turns >=100 ms, including overlap.
    }
}
