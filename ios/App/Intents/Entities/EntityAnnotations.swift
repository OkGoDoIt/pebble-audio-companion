import AppIntents
import SwiftUI

// On-screen awareness (iOS 27): Siri asked about "this conversation" while one is open, or
// "the second one" while the Library is showing, needs the screen to say which entities it is
// showing. Two modifiers, both no-ops below iOS 27 so the screens are byte-for-byte what they
// were: the open conversation is published as the scene's user activity with the entity id
// on it, and each Library row is annotated with its entity.
//
// The activity is not eligible for search, hand-off or prediction — it exists only to tell
// the system what is on screen. Spotlight already holds the conversation through the
// donation; a second, activity-shaped copy of it would be a second result.

struct ConversationEntityAwareness: ViewModifier {
    static let activityType = "dev.audiocompanion.app.viewing-conversation"

    let conversationId: String

    func body(content: Content) -> some View {
        if #available(iOS 27, *) {
            content.userActivity(Self.activityType) { activity in
                activity.appEntityIdentifier = EntityIdentifier(
                    for: ConversationEntity.self, identifier: conversationId)
                activity.isEligibleForSearch = false
                activity.isEligibleForHandoff = false
                activity.isEligibleForPrediction = false
            }
        } else {
            content
        }
    }
}

struct ConversationRowEntityAnnotation: ViewModifier {
    let conversationId: String

    func body(content: Content) -> some View {
        if #available(iOS 27, *) {
            content.appEntityIdentifier(
                EntityIdentifier(for: ConversationEntity.self, identifier: conversationId))
        } else {
            content
        }
    }
}

extension View {
    /// `ConversationScreen`: the one open conversation, as the scene's current activity.
    func conversationEntityAwareness(id: String) -> some View {
        modifier(ConversationEntityAwareness(conversationId: id))
    }

    /// A Library row: this view shows that conversation.
    func conversationRowEntity(id: String) -> some View {
        modifier(ConversationRowEntityAnnotation(conversationId: id))
    }
}
