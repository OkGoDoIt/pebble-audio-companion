import AudioCompanionApp
import Contacts
import EventKit
import Foundation

enum PersonalContextImportBridgeRegistrar {
    static func register() {
        IosPersonalContextImportRegistry.shared.bridge = SwiftPersonalContextImportBridge()
    }
}

final class SwiftPersonalContextImportBridge: NSObject, IosPersonalContextImportBridge {
    private let contactStore = CNContactStore()
    private let eventStore = EKEventStore()

    func importContacts(callback: @escaping ([String], [String], String?) -> Void) {
        contactStore.requestAccess(for: .contacts) { granted, error in
            guard granted else {
                callback([], [], error?.localizedDescription ?? "Contacts permission was not granted.")
                return
            }
            do {
                let keys: [CNKeyDescriptor] = [
                    CNContactGivenNameKey as CNKeyDescriptor,
                    CNContactFamilyNameKey as CNKeyDescriptor,
                    CNContactOrganizationNameKey as CNKeyDescriptor,
                ]
                let request = CNContactFetchRequest(keysToFetch: keys)
                var names: [String] = []
                var orgs = Set<String>()
                try self.contactStore.enumerateContacts(with: request) { contact, stop in
                    let name = [contact.givenName, contact.familyName]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    if !name.isEmpty { names.append(name) }
                    let org = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !org.isEmpty { orgs.insert(org) }
                    if names.count >= 500 { stop.pointee = true }
                }
                callback(Array(names.prefix(500)), Array(orgs).sorted(), nil)
            } catch {
                callback([], [], error.localizedDescription)
            }
        }
    }

    func importCalendar(callback: @escaping ([String], [String], String?) -> Void) {
        let finish: (Bool, Error?) -> Void = { granted, error in
            guard granted else {
                callback([], [], error?.localizedDescription ?? "Calendar permission was not granted.")
                return
            }
            let now = Date()
            let start = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
            let end = Calendar.current.date(byAdding: .day, value: 60, to: now) ?? now
            let predicate = self.eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = self.eventStore.events(matching: predicate).prefix(120)
            var titles: [String] = []
            var attendees = Set<String>()
            for event in events {
                let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { titles.append(title) }
                event.attendees?.forEach { attendee in
                    let name = attendee.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !name.isEmpty { attendees.insert(name) }
                }
            }
            callback(titles, Array(attendees).sorted(), nil)
        }

        if #available(iOS 17.0, *) {
            eventStore.requestFullAccessToEvents(completion: finish)
        } else {
            eventStore.requestAccess(to: .event, completion: finish)
        }
    }
}
