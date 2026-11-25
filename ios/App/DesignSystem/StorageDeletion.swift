import Foundation
import StatusUI

/// The question a deleting choice asks first, and nil when it would delete nothing that is here.
/// Deleting starts on the next pass after the choice and cannot be undone, and a choice is one
/// tap in a list.
struct StorageDeletion: Equatable {
    var title: String
    var message: String
    var confirm: String

    private typealias C = Copy.Settings.Storage

    /// `count` is how many recordings are past the age now. Only a shorter age than the one in
    /// force can take any.
    static func age(_ days: Int, current: Int, count: Int, cloud: Bool) -> StorageDeletion? {
        guard days < current, count > 0 else { return nil }
        return StorageDeletion(
            title: C.deleteTitle(count: count),
            message: C.deleteAgeMessage(age: C.ageLabel(days), cloud: cloud),
            confirm: C.deleteConfirm(count: count))
    }

    /// `used` is what the recordings take on this phone now. 0 is no limit.
    static func limit(_ bytes: Int64, current: Int64, used: Int64) -> StorageDeletion? {
        guard bytes > 0, bytes != current, used > bytes else { return nil }
        let size = Formatting.storageSize(used - bytes)
        return StorageDeletion(
            title: C.deleteTitle(size: size), message: C.deleteLimitMessage,
            confirm: C.deleteConfirm(size: size))
    }
}
