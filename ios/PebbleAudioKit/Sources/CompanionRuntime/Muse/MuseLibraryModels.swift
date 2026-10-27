import Foundation

public struct MuseRecordingSnapshot: Sendable, Equatable {
    public var intent: String
    public var connection: String
    /// Nil means available evidence cannot confirm capture either way.
    public var recording: Bool?
    public var watchState: String?
    public var pausedUntil: Date?
    public var lastAudioAt: Date?
    public var lastWatchReportAt: Date?
    public var observedAt: Date

    public init(intent: String, connection: String, recording: Bool?, watchState: String? = nil,
                pausedUntil: Date? = nil, lastAudioAt: Date? = nil, lastWatchReportAt: Date? = nil,
                observedAt: Date = Date()) {
        self.intent = intent; self.connection = connection; self.recording = recording
        self.watchState = watchState; self.pausedUntil = pausedUntil; self.lastAudioAt = lastAudioAt
        self.lastWatchReportAt = lastWatchReportAt; self.observedAt = observedAt
    }
}

public struct MuseMoment: Sendable, Equatable {
    public var id: String
    public var at: Date
    public var note: String
    public var wasRecording: Bool?
    public var contextStatus: String?
    public var quote: String?
    public var link: String

    public init(id: String, at: Date, note: String, wasRecording: Bool? = nil,
                contextStatus: String? = nil, quote: String? = nil, link: String = "companion://moments") {
        self.id = id; self.at = at; self.note = note; self.wasRecording = wasRecording
        self.contextStatus = contextStatus; self.quote = quote; self.link = link
    }
}

public extension MuseDataProvider {
    func recordingStatus() async -> MuseRecordingSnapshot? { nil }
    func saveMoment(_ note: String?) async -> MuseMoment? { nil }
    func moments(offset: Int, limit: Int) async -> [MuseMoment]? { nil }
    func moment(id: String, includeContext: Bool) async -> MuseMoment? { nil }
    func editMoment(id: String, note: String) async -> MuseMoment? { nil }
    func deleteMoment(id: String) async -> Bool { false }
}

public struct MuseConversationPage: Sendable, Equatable {
    public var items: [MuseConversationText]
    public var nextOffset: Int?
    public init(items: [MuseConversationText], nextOffset: Int?) { self.items = items; self.nextOffset = nextOffset }
}

public extension MuseDataProvider {
    func conversationPage(from: Date, to: Date, query: String?, offset: Int, limit: Int, characters: Int) async -> MuseConversationPage? {
        // Compatibility for providers without paging; the app implements real paging below.
        let items = await conversations(from: from, to: to, query: query, characters: characters)
        return MuseConversationPage(items: Array(items.dropFirst(offset).prefix(limit)), nextOffset: nil)
    }
    func conversation(id: String, textOffset: Int, characters: Int) async -> MuseConversationText? { nil }
}

public struct MuseFollowUpEdit: Sendable, Equatable {
    public var title: String?
    public var due: MuseEventKitSource.ReminderChange.Due?
    public var priority: Int?
    public var listID: String?
    public init(title: String? = nil, due: MuseEventKitSource.ReminderChange.Due? = nil,
                priority: Int? = nil, listID: String? = nil) {
        self.title = title; self.due = due; self.priority = priority; self.listID = listID
    }
}

public extension MuseDataProvider {
    func followUpPage(scope: String, offset: Int, limit: Int) async -> [MuseFollowUp]? {
        guard scope == "review" else { return nil }
        return Array(await followUpsToReview(limit: offset + limit).dropFirst(offset))
    }
    func changeFollowUp(id: String, action: String, edit: MuseFollowUpEdit) async -> MuseFollowUpDecision? {
        guard edit == MuseFollowUpEdit(), ["remind", "skip"].contains(action) else { return nil }
        return await decideFollowUp(id: id, remind: action == "remind")
    }
}
