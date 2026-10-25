import Foundation

public struct ResolvedSpeakerIdentity: Equatable, Sendable {
    public var person: Person
    public var isVoiceMatch: Bool
}

extension SpeakerIdentitySnapshot {
    /// Word-level alignment tolerates small acoustic/ASR boundary differences. Never use this
    /// on a whole sentence: an unrecognized word and any competing recognized voice abstain.
    public func resolvedWordIdentity(segmentId: String, startMediaMs: Int64, endMediaMs: Int64,
                                     speaker: String?, legacyAssignments: [SpeakerAssignment]) -> ResolvedSpeakerIdentity? {
        if let exact = resolvedIdentity(segmentId: segmentId, startMediaMs: startMediaMs,
            endMediaMs: endMediaMs, speaker: speaker, legacyAssignments: legacyAssignments) { return exact }
        guard endMediaMs > startMediaMs,
              resolve(segmentId: segmentId, startMediaMs: startMediaMs, endMediaMs: endMediaMs) == nil else { return nil }
        let rows = automaticAttributions.filter {
            $0.attribution.segmentId == segmentId && $0.attribution.disposition == .recognized
                && $0.attribution.startMediaMs < endMediaMs && $0.attribution.endMediaMs > startMediaMs
        }.sorted { $0.attribution.startMediaMs < $1.attribution.startMediaMs }
        guard var person = rows.first?.person, rows.allSatisfy({ $0.person.id == person.id }) else { return nil }
        var covered: Int64 = 0
        var through = startMediaMs
        for row in rows {
            let lower = max(through, startMediaMs, row.attribution.startMediaMs)
            let upper = min(endMediaMs, row.attribution.endMediaMs)
            covered += max(0, upper - lower)
            through = max(through, upper)
        }
        guard Double(covered) / Double(endMediaMs - startMediaMs) >= 0.8 else { return nil }
        person.isCurrentUser = person.id == currentUserPersonId
        return ResolvedSpeakerIdentity(person: person, isVoiceMatch: true)
    }

    /// Human interval decisions (including unnamed/partial locks), then older human label
    /// assignments, then a recognized voice match. Suggestions never become asserted names.
    public func resolvedIdentity(segmentId: String, startMediaMs: Int64, endMediaMs: Int64,
                                 speaker: String?, legacyAssignments: [SpeakerAssignment]) -> ResolvedSpeakerIdentity? {
        switch resolve(segmentId: segmentId, startMediaMs: startMediaMs, endMediaMs: endMediaMs) {
        case .named(let person): return ResolvedSpeakerIdentity(person: person, isVoiceMatch: false)
        case .unnamed, .partial: return nil
        case nil: break
        }
        if let speaker, !speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let assignment = SpeakerAssignment.match(SpeakerKey(segmentId: segmentId, label: speaker),
                                                    in: legacyAssignments) {
            return ResolvedSpeakerIdentity(person: Person(id: assignment.personId, name: assignment.personName,
                isCurrentUser: assignment.personId == currentUserPersonId), isVoiceMatch: false)
        }
        if case .named(let match) = resolveAutomatic(segmentId: segmentId,
            startMediaMs: startMediaMs, endMediaMs: endMediaMs) {
            return ResolvedSpeakerIdentity(person: match.person, isVoiceMatch: true)
        }
        return nil
    }
}
