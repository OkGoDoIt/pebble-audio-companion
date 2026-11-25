import Foundation

/// What moves audio to the person's iCloud Drive: an age, how much this phone holds, or both.
/// Every surface that says it (Storage, Privacy, onboarding) says it from here.
struct CloudAudioRule: Equatable {
    var ageDays: Int?
    /// 0 is no limit.
    var maxBytes: Int64 = 0

    init?(ageDays: Int?, maxBytes: Int64) {
        guard ageDays != nil || maxBytes > 0 else { return nil }
        self.ageDays = ageDays
        self.maxBytes = maxBytes
    }

    private var limit: String? {
        maxBytes > 0 ? AppSettings.retentionLimitLabel(maxBytes) : nil
    }

    /// The audio it moves, to open a sentence: "Audio older than 2 months" · "The oldest audio,
    /// past 5 GB on this phone," · "Audio older than 2 months, and the oldest past 5 GB on this
    /// phone,".
    var audio: String {
        switch (ageDays.map(Copy.Settings.Storage.ageLabel), limit) {
        case (let age?, let limit?):
            return "Audio older than \(age), and the oldest past \(limit) on this phone,"
        case (nil, let limit?): return "The oldest audio, past \(limit) on this phone,"
        case (let age?, nil): return "Audio older than \(age)"
        case (nil, nil): return "Older audio"
        }
    }

    /// The same audio inside a sentence: "audio older than 2 months and the oldest past 5 GB".
    var audioInSentence: String {
        switch (ageDays.map(Copy.Settings.Storage.ageLabel), limit) {
        case (let age?, let limit?): return "audio older than \(age) and the oldest past \(limit)"
        case (nil, let limit?): return "the oldest audio past \(limit)"
        case (let age?, nil): return "audio older than \(age)"
        case (nil, nil): return "older audio"
        }
    }
}
