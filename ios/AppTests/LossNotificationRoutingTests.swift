import CompanionRuntime
import Foundation
import Testing
import UserNotifications

// Where a loss notification lands, and what it carries. The notifier used to send every tap
// to Today; it now resolves the gap's segment to its conversation when it can, and hands the
// scheduler that id so the iOS 27 notification can carry the entity.

private actor FakeScheduler: LossNotificationScheduling {
    struct Call: Equatable {
        var title: String
        var body: String
        var userInfo: [String: String]
        var conversationId: String?
    }

    private(set) var calls: [Call] = []

    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization() async -> Bool { true }
    func schedule(
        title: String, body: String, userInfo: [String: String], conversationId: String?
    ) async {
        calls.append(
            Call(title: title, body: body, userInfo: userInfo, conversationId: conversationId))
    }
}

@Suite("loss notification routing")
struct LossNotificationRoutingTests {
    private func makeNotifier(
        scheduler: FakeScheduler,
        resolve: @escaping @Sendable (String) async -> String?
    ) -> UserNotificationLossNotifier {
        let suite = "loss-routing-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        // The alert is opt-in; the tests are about routing, so it is on.
        defaults.set(true, forKey: "loss_alerts_enabled")
        return UserNotificationLossNotifier(
            scheduler: scheduler,
            defaults: defaults,
            now: { 1_000_000 },
            conversationId: resolve
        )
    }

    private static func loss(segmentId: String) -> LossEvent {
        LossEvent(segmentId: segmentId, cause: .interruption, durationMs: 90_000, detectedAtMs: 500)
    }

    /// A gap whose segment has been grouped opens that conversation, and the scheduler is
    /// told which one so the notification can carry the entity.
    @Test func aResolvedSegmentRoutesToItsConversation() async throws {
        let scheduler = FakeScheduler()
        let notifier = makeNotifier(scheduler: scheduler) { $0 == "seg-1" ? "conv-1" : nil }

        await notifier.notifyAudioMissed(Self.loss(segmentId: "seg-1"))

        let call = try #require(await scheduler.calls.first)
        #expect(call.conversationId == "conv-1")
        #expect(call.userInfo["route"] == "companion://conversation/conv-1")
        // Through the same parser a tap goes through.
        #expect(
            LossNotificationRouter.route(for: call.userInfo)
                == .conversation(id: "conv-1", atMs: nil, focus: nil))
    }

    /// An unresolved segment (still open, or no runtime up) keeps the historical tap target:
    /// Today, where the coverage strip shows the gap.
    @Test func anUnresolvedSegmentStillRoutesToToday() async throws {
        let scheduler = FakeScheduler()
        let notifier = makeNotifier(scheduler: scheduler) { _ in nil }

        await notifier.notifyAudioMissed(Self.loss(segmentId: "seg-9"))

        let call = try #require(await scheduler.calls.first)
        #expect(call.conversationId == nil)
        #expect(call.userInfo["route"] == "companion://today")
        #expect(LossNotificationRouter.route(for: call.userInfo) == .today(date: nil))
    }

    /// The watch-off notice is about the watch, not a conversation: Today, no entity.
    @Test func theWatchOffNoticeCarriesNoConversation() async throws {
        let scheduler = FakeScheduler()
        let notifier = makeNotifier(scheduler: scheduler) { _ in "conv-should-not-be-asked" }

        await notifier.notifyCaptureStoppedOnWatch()

        let call = try #require(await scheduler.calls.first)
        #expect(call.conversationId == nil)
        #expect(call.userInfo["route"] == "companion://today")
    }

    /// The pure half, for the record.
    @Test func routeStringsAreTheRouterSpelling() {
        #expect(UserNotificationLossNotifier.routeURLString(conversationId: nil) == "companion://today")
        #expect(
            UserNotificationLossNotifier.routeURLString(conversationId: "conv-abc")
                == "companion://conversation/conv-abc")
    }
}
