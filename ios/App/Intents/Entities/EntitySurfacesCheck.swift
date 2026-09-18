#if DEBUG
    import AppIntents
    import CoreSpotlight
    import Foundation
    import SearchKit

    // A DEBUG-only self-check for the Spotlight ↔ entity association, run with the launch
    // argument `-entity-surfaces-check` on a simulator. It donates one synthetic conversation
    // through the real donator (gate + association included), then asks Core Spotlight for it
    // the way Siri does — `CSUserQuery`, semantic ranking on — and prints what came back,
    // including whether the item the INDEX returns carries the entity.
    //
    // Output goes to stdout with an `[entity-check]` prefix so `xcrun simctl launch
    // --console-pty` shows it. Nothing here runs in a release build or without the argument.
    //
    // Result on the ios27-wsA simulator, 2026-09-18: the lexical query finds the item on the
    // first attempt and it comes back with `TypeIdentifier=ConversationEntity
    // InstanceIdentifier=conv-entitycheck Schema=notes.note`; the paraphrase query returns
    // nothing, because the simulator has no on-device embedding assets — that half needs the
    // phone. The entity keys were found by diffing the keyed archive of an item before and
    // after `associateAppEntity`; they are not KVC-compliant, only `value(forCustomKey:)`
    // reads them.
    @available(iOS 27, *)
    enum EntitySurfacesCheck {
        static let launchArgument = "-entity-surfaces-check"
        static let conversationId = "conv-entitycheck"

        static var isRequested: Bool {
            ProcessInfo.processInfo.arguments.contains(launchArgument)
        }

        @MainActor
        static func run(donator: SpotlightDonator) async {
            func say(_ line: String) { print("[entity-check] \(line)") }

            say("visibility=\(EntityVisibility.current().rawValue)")
            say("indexing available=\(CSSearchableIndex.isIndexingAvailable())")

            // 1. Donate one conversation about a topic no other item mentions.
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            do {
                try await donator.donateConversation(
                    conversationId: conversationId,
                    title: "Ferry timetable with Marta",
                    summary: "Agreed to take the 8:40 boat on Saturday and bring the bikes.",
                    tags: ["travel"],
                    fullTranscript:
                        "So the ferry leaves at eight forty on Saturday morning. We should bring "
                        + "the bikes and book the return for Sunday evening.",
                    startDateMs: now - 600_000,
                    createdAtMs: now
                )
                say("donated id=\(conversationId)")
            } catch {
                say("donation failed: \(error)")
                return
            }

            // 2. Show what the association put on the item, by archiving one built the same way.
            let probe = CSSearchableItem(
                uniqueIdentifier: SpotlightDonation.uniqueIdentifier(
                    kind: .conversation, entityId: conversationId),
                domainIdentifier: CoreSpotlightIndexer.domainIdentifier,
                attributeSet: CSSearchableItemAttributeSet(contentType: .text)
            )
            let donation = SpotlightDonation(
                entityId: conversationId, kind: .conversation, title: "Ferry timetable with Marta",
                contentDescription: "Agreed to take the 8:40 boat on Saturday and bring the bikes.",
                textContent: "So the ferry leaves at eight forty on Saturday morning.",
                keywords: ["travel"],
                deepLinkURL: SpotlightDonator.deepLink(kind: .conversation, entityId: conversationId),
                contentCreationDateMs: now, startDateMs: now - 600_000
            )
            let before = archivedStrings(of: probe)
            EntityAssociation.associate(probe, donation: donation)
            let after = archivedStrings(of: probe)
            say("probe archive strings added by association=\(after.subtracting(before).sorted())")
            for key in entityKeys {
                say("probe \(key)=\(entityValue(key, in: probe.attributeSet))")
            }

            // 3. Give the index a moment, then ask the way Siri asks: once with a word that is
            //    in the text (lexical), once with a paraphrase (semantic). Spotlight indexes
            //    asynchronously, so each is retried for a while before it counts as absent.
            CSUserQuery.prepare()
            for (label, text) in [
                ("lexical", "ferry timetable"),
                ("semantic", "boat trip on the weekend with bicycles"),
            ] {
                var hits: [String] = []
                for attempt in 1...6 {
                    try? await Task.sleep(for: .seconds(2))
                    hits = await userQuery(text)
                    if !hits.isEmpty {
                        say("\(label) query found after attempt=\(attempt)")
                        break
                    }
                }
                say("\(label) query hits=\(hits.count) \(hits)")
            }

            // 4. And through the entity model: a real conversation must resolve to an entity
            //    with its title, and the check id (not in the database) must not.
            let real = await EntityDataSources.current.conversations(
                scope: .everything, tag: nil, limit: 1)
            let ids = real.map(\.id) + [conversationId]
            let entities = (try? await ConversationEntityQuery().entities(for: ids)) ?? []
            say(
                "entity query asked=\(ids.count) resolved=\(entities.count) "
                    + "titles=\(entities.map { String($0.name.characters) })"
            )

            // 5. Clean up the synthetic document.
            try? await donator.remove(id: conversationId, kind: .conversation)
            say("removed id=\(conversationId)")
        }

        private static let entityKeys = [
            "_kMDItemAppEntityTypeIdentifier", "_kMDItemAppEntityInstanceIdentifier",
            "_kMDItemAppEntitySchema", "kMDItemAppEntityTitle",
        ]

        /// The entity keys are not KVC-compliant on the attribute set; the custom-key accessor
        /// is the only public way to read a raw attribute back.
        private static func entityValue(_ key: String, in attributes: CSSearchableItemAttributeSet)
            -> String
        {
            guard let custom = CSCustomAttributeKey(keyName: key) else { return "(no key)" }
            return attributes.value(forCustomKey: custom).map { String(describing: $0) } ?? "-"
        }

        /// One `CSUserQuery`, semantic ranking on, over our domain; the hit lines it produces.
        private static func userQuery(_ text: String) async -> [String] {
            let context = CSUserQueryContext()
            context.maxRankedResultCount = 5
            context.maxResultCount = 10
            context.disableSemanticSearch = false
            // The entity keys are what `associateAppEntity` writes (found by archiving an
            // associated item); asking for them back is the proof the INDEX holds them.
            context.fetchAttributes = ["title", "contentDescription", "domainIdentifier"] + entityKeys
            let query = CSUserQuery(userQueryString: text, userQueryContext: context)
            var lines: [String] = []
            do {
                for try await response in query.responses {
                    guard case .item(let hit) = response else { continue }
                    let item = hit.item
                    let entity = entityKeys.map { key in
                        "\(key.replacingOccurrences(of: "_kMDItemAppEntity", with: "").replacingOccurrences(of: "kMDItemAppEntity", with: ""))=\(entityValue(key, in: item.attributeSet))"
                    }
                    lines.append(
                        "id=\(item.uniqueIdentifier) domain=\(item.domainIdentifier ?? "-") "
                            + "title=\(item.attributeSet.title ?? "-") "
                            + "entity{\(entity.joined(separator: " "))}"
                    )
                }
            } catch {
                lines.append("query failed: \(error)")
            }
            return lines
        }

        /// Every printable run of 4+ ASCII characters in the keyed archive of an item — the
        /// attribute names and values it carries, wherever the archive nests them.
        private static func archivedStrings(of item: CSSearchableItem) -> Set<String> {
            guard
                let data = try? NSKeyedArchiver.archivedData(
                    withRootObject: item, requiringSecureCoding: true)
            else { return [] }
            var out = Set<String>()
            var run: [UInt8] = []
            for byte in data {
                if (0x20...0x7E).contains(byte) {
                    run.append(byte)
                } else {
                    if run.count >= 4 { out.insert(String(decoding: run, as: UTF8.self)) }
                    run.removeAll()
                }
            }
            if run.count >= 4 { out.insert(String(decoding: run, as: UTF8.self)) }
            return out
        }
    }
#endif
