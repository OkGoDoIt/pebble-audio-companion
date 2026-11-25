import CompanionRuntime
import Foundation
import Testing

/// The path on the Storage screen: which stops are used, when each is reached, what runs between
/// them, and what is said when something is in the way.
@MainActor
@Suite struct StoragePathTests {
    private static let GB: Int64 = 1 << 30

    private func overview(
        phone: Int64 = 6, cloud: Int64 = 0, uploading: Int64 = 0, available: Bool = true,
        error: String? = nil, full: Bool = false, restoring: ColdAudioTier.Summary.Restore? = nil
    ) -> StorageOverview {
        StorageOverview(
            recordingCount: 10, audioOnPhoneBytes: phone * Self.GB, audioInCloudBytes: cloud * Self.GB,
            audioInCloudCount: Int(cloud), uploadingBytes: uploading * Self.GB,
            uploadingCount: Int(uploading), textBytes: 0, modelBytes: 0, temporaryBytes: 0,
            freeBytes: 100 * Self.GB, capacityBytes: 512 * Self.GB, cloudAvailable: available,
            restoring: restoring, cloudError: error, cloudIsFull: full)
    }

    private func path(
        keep: Int = AppSettings.keepForever, deleteLimit: Int64 = 0, cloudAge: Int? = nil,
        cloudLimit: Int64 = 0, chosen: Int? = nil, inert: Bool = false, toMove: Int64 = 0,
        _ overview: StorageOverview?
    ) -> StoragePath {
        let rule = CloudAudioRule(ageDays: cloudAge, maxBytes: cloudLimit * Self.GB)
        return StoragePath(
            .init(
                retentionDays: keep, retentionMaxBytes: deleteLimit * Self.GB,
                cloudEnabled: rule != nil || inert, cloudChosenDays: chosen ?? cloudAge ?? 60,
                cloudRule: rule, toMoveBytes: toMove * Self.GB, overview: overview))
    }

    @Test func nothingChosenKeepsEverythingHere() {
        let p = path(overview())
        #expect(!p.cloud.isUsed && p.cloud.when == "Never" && p.cloud.size == nil && p.cloud.note == nil)
        #expect(!p.deleted.isUsed && p.deleted.when == "Never")
        #expect(p.toCloud == .nothing && p.toDeleted == .nothing)
        #expect(p.phoneLine == "Every new recording" && p.room == nil)
        #expect(p.footer == "Everything is kept on this phone.")
    }

    @Test func deletingAloneRunsPastAnUnusedICloud() {
        let p = path(keep: 365, overview())
        #expect(!p.cloud.isUsed && p.deleted.isUsed)
        #expect(p.deleted.when == "After 1 year")
        #expect(p.toCloud == .phone && p.toDeleted == .phone)
        #expect(p.footer == "Deleting a recording deletes its transcript too.")

        let byRoom = path(deleteLimit: 5, overview())
        #expect(byRoom.deleted.when == "Past 5 GB on this phone")
        #expect(byRoom.phoneLine == "Up to 5 GB")
        #expect(byRoom.room == .init(used: 6 * Self.GB, limit: 5 * Self.GB))
        #expect(path(keep: 30, deleteLimit: 5, overview()).deleted.when
            == "After 1 month, or past 5 GB on this phone")
    }

    @Test func movingAloneEndsInICloud() {
        let p = path(cloudAge: 30, overview(phone: 2, cloud: 3))
        #expect(p.cloud.isUsed && p.cloud.when == "After 1 month" && p.cloud.size == "3.0 GB")
        #expect(p.toCloud == .phone && p.toDeleted == .nothing)
        #expect(p.phoneSize == "2.0 GB")
        #expect(p.footer == "Transcripts stay on this phone, and audio in iCloud downloads when you play it.")
        #expect(path(cloudLimit: 5, overview()).cloud.when == "Past 5 GB on this phone")
        #expect(path(cloudAge: 30, cloudLimit: 5, overview()).cloud.when
            == "After 1 month, or past 5 GB on this phone")
    }

    /// A limit belongs to the next stop: with iCloud on it moves, whatever else is stored.
    @Test func withICloudOnTheLimitIsNeverADeletingOne() {
        let p = path(deleteLimit: 2, cloudAge: 30, cloudLimit: 5, overview())
        #expect(!p.deleted.isUsed && p.deleted.when == "Never")
        #expect(p.phoneLine == "Up to 5 GB")
    }

    @Test func bothStops() {
        let p = path(keep: 365, cloudAge: 30, overview(phone: 2, cloud: 3))
        #expect(p.toCloud == .phone && p.toDeleted == .cloud)
        #expect(p.cloud.isUsed && p.deleted.isUsed)
    }

    /// The deleting age comes first: the move happens sooner, or never, and the path says which.
    @Test func aDeletingAgeInFrontOfTheMoveIsSaid() {
        let sooner = path(keep: 30, cloudAge: 14, chosen: 60, overview())
        #expect(sooner.cloud.when == "After 2 weeks")
        #expect(sooner.footer == "Recordings are deleted after 1 month, so audio moves after 2 weeks instead of 2 months.")

        let never = path(keep: 14, inert: true, overview())
        #expect(!never.cloud.isUsed && never.cloud.when == "Never")
        #expect(never.cloud.note?.text == "Recordings are deleted first, after 2 weeks")
        #expect(never.toDeleted == .phone)
    }

    /// Off, with audio still there: the stop is drawn as holding it, and it can be deleted from.
    @Test func turnedOffWithAudioStillInICloud() {
        let p = path(overview(cloud: 3))
        #expect(p.cloud.isUsed && p.cloud.when == "Never" && p.cloud.size == "3.0 GB")
        #expect(p.toCloud == .phone)
        #expect(path(keep: 365, overview(cloud: 3)).toDeleted == .cloud)
        let back = path(overview(cloud: 3, restoring: .init(done: 12, total: 988)))
        #expect(back.cloud.note?.text == "Bringing back 12 of 988…")
    }

    @Test func whatIsInTheWayIsSaidOnceAndInOrder() {
        func note(_ o: StorageOverview, toMove: Int64 = 0) -> StoragePath.Note? {
            path(cloudAge: 30, toMove: toMove, o).cloud.note
        }
        #expect(note(overview()) == nil)
        #expect(note(overview(uploading: 1), toMove: 2) == .init(text: "3.0 GB on its way"))
        #expect(note(overview(uploading: 1, error: "seg-1: quota", full: true))
            == .init(text: "iCloud is full, so audio is staying here", needsAttention: true))
        let refused = note(overview(error: "upload seg-1: failed"))
        #expect(refused?.needsAttention == true)
        #expect(refused?.text.contains("seg-1") == false, "an identifier is not an explanation")
        #expect(note(overview(available: false, error: "x"))
            == .init(text: "iCloud Drive is off, so nothing is moving", needsAttention: true))
        // Off and unreachable: a fact, unless there is audio it makes unplayable.
        #expect(path(overview(available: false)).cloud.note == .init(text: "iCloud Drive is off on this phone"))
        #expect(path(overview(cloud: 3, available: false)).cloud.note
            == .init(text: "iCloud Drive is off, so this audio can’t play", needsAttention: true))
    }

    @Test func beforeAnythingIsReadTheRulesAreStillThere() {
        let p = path(keep: 365, cloudAge: 30, cloudLimit: 5, nil)
        #expect(p.phoneSize == nil && p.cloud.size == nil && p.room == nil && p.cloud.note == nil)
        #expect(p.cloud.when == "After 1 month, or past 5 GB on this phone")
        #expect(p.deleted.when == "After 1 year")
    }

    // MARK: - The settings behind it

    private func settings(_ defaults: UserDefaults) -> AppSettings {
        AppSettings(defaults: defaults, keychain: KeychainStore(service: "tests.unused"))
    }

    private func suite() -> (UserDefaults, String) {
        let name = "storage-path-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name) ?? .standard, name)
    }

    /// Turning iCloud on takes the deleting limit over; turning it off drops it. At no point in
    /// either does running out of room delete anything.
    @Test func theLimitChangesHandsWithoutEverDeleting() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let s = settings(defaults)
        s.retentionDays = AppSettings.keepForever
        s.setDeleteLimit(5 * Self.GB)
        #expect(s.runtimeSettings.retentionConfig.maxTotalBytes == 5 * Self.GB)

        var seen: [Int64] = []
        s.onRuntimeSettingsChanged = { [box = s.runtimeSettings] in
            MainActor.assumeIsolated { seen.append(box.retentionConfig.maxTotalBytes) }
        }
        s.setCloudRule(ageDays: 30, maxBytes: 0)
        #expect(s.coldStorageMaxBytes == 5 * Self.GB, "the limit moved to the new next stop")
        #expect(s.retentionMaxBytes == 0)
        #expect(s.runtimeSettings.coldStoragePolicy
            == ColdStoragePolicy(enabled: true, minAgeMs: 30 * 86_400_000, maxPhoneBytes: 5 * Self.GB))

        seen = []
        s.setCloudRule(ageDays: nil, maxBytes: 0)
        #expect(s.cloudRule == nil && s.coldStorageMaxBytes == 0 && s.retentionMaxBytes == 0)
        #expect(seen.allSatisfy { $0 == .max }, "no state on the way out deletes for room")
    }

    @Test func roomAloneSurvivesARelaunch() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        settings(defaults).setCloudRule(ageDays: nil, maxBytes: 10 * Self.GB)
        // A build that knows only the old keys sees no deleting limit here.
        #expect(defaults.integer(forKey: "retention_max_bytes") == 0)
        let again = settings(defaults)
        #expect(again.cloudRule == CloudAudioRule(ageDays: nil, maxBytes: 10 * Self.GB))
        again.reloadFromDefaults()
        #expect(again.cloudRule == CloudAudioRule(ageDays: nil, maxBytes: 10 * Self.GB))
        // And it needs no age, however short the deleting one is.
        again.retentionDays = 7
        #expect(again.coldStorageAgeChoices.isEmpty)
        #expect(again.runtimeSettings.coldStoragePolicy.enabled)
    }

    /// Chosen under the old screen, where a limit deleted even with iCloud on.
    @Test func bothLimitsFromAnOlderBuildBecomeOneThatMoves() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "cold_storage_enabled")
        defaults.set(60, forKey: "cold_storage_min_age_days")
        defaults.set(365, forKey: "retention_days")
        defaults.set(Int(5 * Self.GB), forKey: "retention_max_bytes")
        let s = settings(defaults)
        #expect(s.cloudRule == CloudAudioRule(ageDays: 60, maxBytes: 5 * Self.GB))
        #expect(s.retentionMaxBytes == 0)
        #expect(s.runtimeSettings.retentionConfig.maxTotalBytes == .max)
        #expect(defaults.integer(forKey: "retention_max_bytes") == 0)
    }

    /// A rule that can never act gives way to a deleting limit instead of silently blocking it.
    @Test func aDeletingLimitReplacesARuleThatCanNeverAct() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let s = settings(defaults)
        s.setCloudRule(ageDays: 60, maxBytes: 0)
        s.retentionDays = 14
        #expect(s.coldStorageEnabled && s.cloudRule == nil)
        s.setDeleteLimit(2 * Self.GB)
        #expect(!s.coldStorageEnabled)
        #expect(s.runtimeSettings.retentionConfig.maxTotalBytes == 2 * Self.GB)
    }

    // MARK: - Asking before deleting

    /// Every choice that would delete something already here asks, saying how much; no other does.
    @Test func onlyAChoiceThatDeletesSomethingAsks() {
        let forever = AppSettings.keepForever
        let age = StorageDeletion.age(90, current: forever, count: 239, cloud: false)
        #expect(age?.title == "Delete 239 recordings?")
        #expect(age?.confirm == "Delete 239 Recordings")
        #expect(age?.message == "Everything older than 3 months is deleted, with its transcript. This can’t be undone.")
        #expect(StorageDeletion.age(90, current: 365, count: 1, cloud: true)?.title == "Delete 1 recording?")
        #expect(StorageDeletion.age(90, current: 365, count: 1, cloud: true)?.message.contains("from iCloud too") == true)
        #expect(StorageDeletion.age(365, current: forever, count: 0, cloud: false) == nil)
        #expect(StorageDeletion.age(forever, current: 30, count: 0, cloud: false) == nil)
        #expect(StorageDeletion.age(30, current: 30, count: 5, cloud: false) == nil, "already in force")

        let limit = StorageDeletion.limit(5 * Self.GB, current: 0, used: 6 * Self.GB)
        #expect(limit?.title == "Delete 1.0 GB of recordings?")
        #expect(StorageDeletion.limit(10 * Self.GB, current: 0, used: 6 * Self.GB) == nil)
        #expect(StorageDeletion.limit(0, current: 5 * Self.GB, used: 6 * Self.GB) == nil, "no limit deletes nothing")
        #expect(StorageDeletion.limit(5 * Self.GB, current: 5 * Self.GB, used: 6 * Self.GB) == nil)
    }

    // MARK: - Privacy says the same

    @Test func privacyNamesICloudHoweverAudioGetsThereAndWhileItStays() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let s = settings(defaults)
        s.transcriptionMode = .localOnly
        s.aiMode = .localOnly
        s.retentionDays = AppSettings.keepForever
        #expect(s.privacyStance.isFullyLocal)

        s.setCloudRule(ageDays: nil, maxBytes: 5 * Self.GB)
        #expect(!s.privacyStance.isFullyLocal)
        #expect(s.privacyStance.qualifiers.contains { $0.hasPrefix("The oldest audio, past 5 GB on this phone, is kept") })
        s.setCloudRule(ageDays: 60, maxBytes: 5 * Self.GB)
        #expect(s.privacyStance.qualifiers.contains { $0.hasPrefix("Audio older than 2 months, and the oldest past 5 GB on this phone, is kept") })

        // Off, but what moved is still there.
        s.setCloudRule(ageDays: nil, maxBytes: 0)
        s.cloudHoldsAudio = true
        #expect(!s.privacyStance.isFullyLocal)
        #expect(s.privacyStance.headline == "Some audio is in your iCloud Drive")
        let model = PrivacyModel.derive(PrivacyInputs(iCloudHoldsAudio: true), nowMs: 0)
        #expect(model.destinations.map(\.name) == ["iCloud Drive"])
        #expect(model.destinations.first?.why == "Still holds older audio")
        s.cloudHoldsAudio = false
        #expect(s.privacyStance.isFullyLocal)
    }
}
