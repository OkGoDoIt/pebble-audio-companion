import CompanionRuntime
import Foundation
import StatusUI

/// The life of a recording, as the Storage screen draws it: this phone, then iCloud, then
/// deleted, each stop saying when it is reached. Pure over the settings and the overview, so
/// every state the two can be in has a test and the screen only draws.
struct StoragePath: Equatable {
    struct Inputs: Equatable {
        var retentionDays: Int
        var retentionMaxBytes: Int64
        var cloudEnabled: Bool
        /// The chosen move age, and the one that takes effect under `retentionDays`.
        var cloudChosenDays: Int
        var cloudRule: CloudAudioRule?
        /// What the rule has yet to move, on top of what is uploading.
        var toMoveBytes: Int64 = 0
        /// Nil until the recordings have been read.
        var overview: StorageOverview?
    }

    /// A line under a stop's "when": something true right now.
    struct Note: Equatable {
        var text: String
        /// Something is stopping the stop from doing its job.
        var needsAttention = false
    }

    struct Stop: Equatable {
        /// Drawn filled; a stop nothing reaches is a dashed outline.
        var isUsed: Bool
        var when: String
        var size: String?
        var note: Note?
    }

    /// What runs down the line between two stops.
    enum Rail: Equatable { case phone, cloud, nothing }

    struct Room: Equatable {
        var used: Int64
        var limit: Int64
    }

    var phoneLine: String
    var phoneSize: String?
    /// How much of this phone's limit is used; nil without one.
    var room: Room?
    var cloud: Stop
    var deleted: Stop
    var toCloud: Rail
    var toDeleted: Rail
    var footer: String

    init(_ inputs: Inputs) {
        typealias C = Copy.Settings.Storage
        let overview = inputs.overview
        let holds = (overview?.audioInCloudBytes ?? 0) > 0
        let ruleOn = inputs.cloudRule != nil
        let cloudUsed = ruleOn || holds
        let deleteLimit = inputs.cloudEnabled ? 0 : inputs.retentionMaxBytes
        let deletes = inputs.retentionDays != AppSettings.keepForever || deleteLimit > 0
        let limit = inputs.cloudRule?.maxBytes ?? deleteLimit

        phoneLine = limit > 0 ? C.upTo(AppSettings.retentionLimitLabel(limit)) : C.everyNewRecording
        phoneSize = overview.map { Formatting.storageSize($0.audioOnPhoneBytes) }
        room = limit > 0 ? overview.map { Room(used: $0.audioOnPhoneBytes, limit: limit) } : nil

        cloud = Stop(
            isUsed: cloudUsed,
            when: inputs.cloudRule.map { C.when(ageDays: $0.ageDays, maxBytes: $0.maxBytes) } ?? C.never,
            size: holds ? overview.map { Formatting.storageSize($0.audioInCloudBytes) } : nil,
            note: Self.cloudNote(inputs, holds: holds))
        deleted = Stop(
            isUsed: deletes,
            when: deletes
                ? C.when(
                    ageDays: inputs.retentionDays == AppSettings.keepForever
                        ? nil : inputs.retentionDays,
                    maxBytes: deleteLimit)
                : C.never)

        toCloud = cloudUsed || deletes ? .phone : .nothing
        // Off, with audio still there: what reaches Deleted leaves from both, and the stop it
        // passes last is iCloud.
        toDeleted = deletes ? (cloudUsed ? .cloud : .phone) : .nothing

        if let effective = inputs.cloudRule?.ageDays, effective != inputs.cloudChosenDays {
            footer = C.movesSooner(
                effectiveDays: effective, chosenDays: inputs.cloudChosenDays,
                keepDays: inputs.retentionDays)
        } else if deletes {
            footer = C.deletingFooter
        } else if cloudUsed {
            footer = C.cloudFooter
        } else {
            footer = C.keptFooter
        }
    }

    private static func cloudNote(_ inputs: Inputs, holds: Bool) -> Note? {
        typealias C = Copy.Settings.Storage
        // On, but every recording is deleted before it is old enough to move.
        if inputs.cloudEnabled, inputs.cloudRule == nil {
            return Note(text: C.deletedFirst(keepDays: inputs.retentionDays))
        }
        guard let overview = inputs.overview else { return nil }
        if !overview.cloudAvailable {
            if inputs.cloudRule != nil { return Note(text: C.cloudOffMovesNothing, needsAttention: true) }
            return Note(text: holds ? C.cloudOffCannotPlay : C.cloudOffOnThisPhone, needsAttention: holds)
        }
        if let restoring = overview.restoring {
            return Note(text: C.bringingBack(done: restoring.done, total: restoring.total))
        }
        guard inputs.cloudRule != nil else { return nil }
        if overview.cloudIsFull { return Note(text: C.cloudFull, needsAttention: true) }
        if overview.cloudError != nil { return Note(text: C.cloudRefused, needsAttention: true) }
        let moving = overview.uploadingBytes + inputs.toMoveBytes
        return moving > 0 ? Note(text: C.onItsWay(Formatting.storageSize(moving))) : nil
    }
}
