import AppDB
import Foundation
import SearchKit
import Transcription

/// One precedence rule for the screen, search, archive and assistant transcript views.
/// A partial or explicitly unnamed correction blocks the older whole-speaker assignment.
public enum SpeakerAttribution {
    public static func person(
        segmentId: String, startMediaMs: Int64, endMediaMs: Int64, speaker: String?,
        identity: SpeakerIdentitySnapshot, legacyAssignments: [SpeakerAssignment]
    ) -> Person? {
        switch identity.resolve(
            segmentId: segmentId, startMediaMs: startMediaMs, endMediaMs: endMediaMs
        ) {
        case .named(let person): return person
        case .unnamed, .partial: return nil
        case nil:
            guard let speaker, !speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let assignment = SpeakerAssignment.match(
                    SpeakerKey(segmentId: segmentId, label: speaker), in: legacyAssignments)
            else { return nil }
            return Person(id: assignment.personId, name: assignment.personName,
                          isCurrentUser: assignment.personId == identity.currentUserPersonId)
        }
    }

    public static func name(
        segmentId: String, startMediaMs: Int64, endMediaMs: Int64, speaker: String?,
        identity: SpeakerIdentitySnapshot, legacyNames: [String: String]
    ) -> String? {
        switch identity.resolve(
            segmentId: segmentId, startMediaMs: startMediaMs, endMediaMs: endMediaMs
        ) {
        case .named(let person): return person.name
        case .unnamed, .partial: return nil
        case nil:
            guard let speaker, !speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return SpeakerKey(segmentId: segmentId, label: speaker).name(in: legacyNames)
        }
    }

    /// External and indexed text uses the person's stored name, not the viewer-relative You.
    /// A local ASR turn may have a human name despite having no provider speaker label.
    public static func line(text: String, speaker: String?, name: String?) -> String {
        if let name, !name.isEmpty { return "\(name): \(text)" }
        guard let speaker, !speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return text }
        return "\(speakerLabel(speaker)): \(text)"
    }

    /// People actually named in this piece. Corrections also name audio with no transcript.
    /// Legacy metadata without turns is retained only when no range correction disputes it.
    public static func people(
        in member: ConversationMember, transcript: SegmentTranscript?,
        identity: SpeakerIdentitySnapshot, legacyAssignments: [SpeakerAssignment]
    ) -> [Person] {
        let turns = transcript?.piece(member).segments ?? []
        var people = turns.compactMap { turn in
            person(segmentId: member.segmentId, startMediaMs: turn.startMs,
                   endMediaMs: turn.endMs, speaker: turn.speaker, identity: identity,
                   legacyAssignments: legacyAssignments)
        }
        let lower = member.startMediaMs ?? 0
        let upper = member.endMediaMs ?? Int64.max
        let corrections = identity.corrections.filter {
            $0.segmentId == member.segmentId && $0.startMediaMs < upper && $0.endMediaMs > lower
        }
        people += corrections.compactMap(\.person).map { person in
            var person = person
            person.isCurrentUser = person.id == identity.currentUserPersonId
            return person
        }
        if turns.isEmpty && corrections.isEmpty {
            people += legacyAssignments.compactMap { assignment in
                if let key = SpeakerKey(stored: assignment.label), key.segmentId != member.segmentId {
                    return nil
                }
                return Person(id: assignment.personId, name: assignment.personName,
                              isCurrentUser: assignment.personId == identity.currentUserPersonId)
            }
        }
        var seen = Set<String>()
        return people.filter { seen.insert($0.id).inserted }
    }
}
