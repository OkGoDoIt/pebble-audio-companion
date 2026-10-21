import CompanionRuntime
import Foundation
import SearchKit
import Transcription

/// The round-3 states for previews and the review screenshots, with the mockups' synthetic
/// people and numbers (Sam's kitchen, Priya's launch, Leo's dentist; 412 conversations back to
/// March 4). Nothing here is anyone's real data.
///
/// DEBUG builds read `-assistantsDemo <state>` (the mockup's file stem: `02`, `03a`, … `09e`)
/// together with `-demo-data`, so every mockup state can be rendered without a server.
@MainActor
enum AssistantsDemo {
    static let host = "pebbleaudio.okgodoit.com"
    static let origin = "https://pebbleaudio.okgodoit.com"

    /// The state asked for on the command line, if any.
    static var state: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-assistantsDemo"), index + 1 < args.count {
            return args[index + 1]
        }
        #endif
        return nil
    }

    /// The mockups' "now": Wednesday, October 21, 2026, 10:30 AM here.
    static var nowMs: Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 10, minute: 30))!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    static func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    /// 412 conversations back to March 4: 3 today, 14 in a week, 57 in 30 days, 168 in 90, 287
    /// in 180 — the mockups' numbers for every choice.
    static func counts(nowMs: Int64) -> ArchiveScopeCounts {
        let day: Int64 = 86_400_000
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        let todayStart = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: now).map { Int64($0.timeIntervalSince1970 * 1000) } ?? nowMs
        let oldest = at(3, 4, 9, 0)
        func spread(_ n: Int, from low: Int64, to high: Int64) -> [Int64] {
            guard n > 0 else { return [] }
            let step = (high - low) / Int64(n + 1)
            return (1...n).map { low + Int64($0) * step }
        }
        var starts: [Int64] = []
        starts += spread(3, from: todayStart, to: nowMs)
        starts += spread(11, from: nowMs - 7 * day, to: todayStart)
        starts += spread(43, from: nowMs - 30 * day, to: nowMs - 7 * day)
        starts += spread(111, from: nowMs - 90 * day, to: nowMs - 30 * day)
        starts += spread(119, from: nowMs - 180 * day, to: nowMs - 90 * day)
        starts += [oldest] + spread(124, from: oldest, to: nowMs - 180 * day)
        return ArchiveScopeCounts(startsMs: starts)
    }

    static let chatGPT = ArchiveServerStatus.Access(
        kind: "oauth", id: "client-chatgpt", name: "ChatGPT", scopes: ["archive:read"],
        connectedAtMs: at(10, 12, 18, 20), lastUsedAtMs: at(10, 21, 9, 30))
    static let claude = ArchiveServerStatus.Access(
        kind: "oauth", id: "client-claude", name: "Claude", scopes: ["archive:read"],
        connectedAtMs: at(10, 14, 11, 5), lastUsedAtMs: at(10, 20, 16, 40))
    static let codex = ArchiveServerStatus.Access(
        kind: "token", id: "token-codex", name: "Codex on Mac", scopes: ["archive:read"],
        connectedAtMs: at(10, 18, 14, 0), lastUsedAtMs: at(10, 18, 15, 12))

    /// What ChatGPT read (08): Monday's recap, Sam's kitchen, a search, Priya's launch, Leo's
    /// dentist. The server's log carries the tool and ids, never the words searched for.
    static let reads: [ArchiveServerStatus.AiRead] = [
        .init(atMs: at(10, 21, 9, 42), client: "ChatGPT", tool: "get_day", ids: ["2026-10-19"]),
        .init(atMs: at(10, 21, 9, 41), client: "ChatGPT", tool: "get_conversation", ids: ["conv-demo-kitchen"]),
        .init(atMs: at(10, 21, 9, 40), client: "ChatGPT", tool: "search", ids: ["conv-demo-kitchen"]),
        .init(atMs: at(10, 20, 16, 12), client: "ChatGPT", tool: "get_conversation", ids: ["conv-demo-launch"]),
        .init(atMs: at(10, 20, 16, 11), client: "ChatGPT", tool: "search", ids: ["conv-demo-launch"]),
        .init(atMs: at(10, 20, 10, 5), client: "ChatGPT", tool: "fetch", ids: ["conv-demo-dentist"]),
        .init(atMs: at(10, 20, 16, 30), client: "Claude", tool: "search", ids: []),
    ]

    static let titles = [
        "conv-demo-kitchen": "Kitchen renovation with Sam",
        "conv-demo-launch": "Product launch plan with Priya",
        "conv-demo-dentist": "Leo's dentist appointment",
    ]

    /// The source every screen reads: the live one replaces it outside the demo.
    static func makeSource() -> MockAssistantsSource {
        let source = MockAssistantsSource(nowMs: state == nil ? Int64(Date().timeIntervalSince1970 * 1000) : nowMs)
        source.knownTitles = titles
        if let state { seed(source, state) }
        return source
    }

    static func linked(_ source: MockAssistantsSource, scope: ArchiveSharingScope, enabled: Bool = true,
                       access: [ArchiveServerStatus.Access]) {
        source.sync = ArchiveSyncSettings(
            origin: origin, deviceId: "demo-phone", enabled: enabled,
            preferences: ArchivePreferences(scope: scope), setupComplete: true)
        source.status.link = .linked(host: host)
        source.status.enabled = enabled
        source.status.lastBatchAtMs = source.nowMs - 2 * 60_000
        source.status.server = ArchiveServerStatus(
            lastBatchAtMs: source.nowMs - 2 * 60_000, pendingRequests: 0, aiReads: reads,
            access: access, counts: ["conversation": 168, "transcript": 168])
        source.status.serverStatusAtMs = source.nowMs
    }

    static func seed(_ source: MockAssistantsSource, _ state: String) {
        let flow = source.flow
        let now = source.nowMs
        func connecting(_ access: [ArchiveServerStatus.Access], open: ConnectCard) {
            source.sync = ArchiveSyncSettings(
                origin: origin, deviceId: "demo-phone", enabled: true,
                preferences: ArchivePreferences(), setupComplete: true)
            source.status.link = .linked(host: host)
            source.status.enabled = true
            source.status.server = ArchiveServerStatus(
                lastBatchAtMs: now, pendingRequests: 0, aiReads: [], access: access)
            flow.showChooseDirect = true
            flow.showConnect = true
            flow.demoOpenCard = open
        }
        switch state {
        case "03a":
            flow.showLink = true
        case "03b":
            flow.serverText = host
            flow.codeText = "K7QM2XPA"
            source.linkFailure = .expired(code: "K7QM2XPA")
            flow.showLink = true
        case "04a", "04b":
            source.sync = ArchiveSyncSettings(
                origin: origin, deviceId: "demo-phone", enabled: false,
                preferences: ArchivePreferences(scope: state == "04b" ? .lastDays(90) : .all),
                setupComplete: false)
            source.status.link = .linked(host: host)
            flow.showChooseDirect = true
        case "05a":
            connecting([], open: .chatGPT)
        case "05b":
            var gpt = chatGPT
            gpt.connectedAtMs = now - 20_000
            connecting([gpt], open: .claude)
        case "05c", "05e":
            var gpt = chatGPT
            gpt.connectedAtMs = now - 20_000
            var cl = claude
            cl.connectedAtMs = now - 2 * 60_000
            connecting([gpt, cl], open: .mac)
            flow.demoMacTool = state == "05e" ? .cursor : .codex
        case "05d":
            connecting([chatGPT, claude, codex], open: .other)
        case "07a", "07b", "07c", "07d", "07e", "08":
            linked(source, scope: .lastDays(90), enabled: state != "07e", access: [chatGPT, claude, codex])
            switch state {
            case "07b":
                flow.showScope = true
                flow.demoScopeDraft = .lastDays(30)
            case "07d":
                flow.showScope = true
                flow.demoScopeDraft = .since(ms: AssistantTime.logicalDayStart(now))
            case "07c":
                flow.demoConfirmUnlink = true
            case "08":
                flow.detailAccessId = chatGPT.id
            default:
                break
            }
        default:
            break
        }
    }

    /// The Privacy states (09a–09e), as inputs. The Muse row in (d) is the model's D7, filled
    /// here the way the Muse feature will fill it.
    static var privacyInputs: PrivacyInputs? {
        guard let state, state.hasPrefix("09") else { return nil }
        let now = nowMs
        func assistants(_ list: [ArchiveServerStatus.Access]) -> [PrivacyInputs.Assistant] {
            list.map { .init(name: $0.name, canWrite: $0.canWrite, lastUsedAtMs: $0.lastUsedAtMs) }
        }
        var gpt = chatGPT
        gpt.lastUsedAtMs = now - 3_600_000
        var inputs = PrivacyInputs(systemSearch: .summaries)
        switch state {
        case "09b":
            inputs.server = .init(
                host: host, paused: false, scope: .all, clipsAllowed: false, editsAllowed: false,
                assistants: [])
        case "09c":
            inputs.server = .init(
                host: host, paused: false, scope: .lastDays(90), clipsAllowed: false,
                editsAllowed: false, assistants: assistants([gpt, claude]))
        case "09d":
            inputs.transcriptionDestination = "Soniox"
            inputs.server = .init(
                host: host, paused: false, scope: .all, clipsAllowed: true, editsAllowed: false,
                assistants: assistants([gpt, claude, codex]))
            inputs.museState = .init(spokenQuestions: true, watchActions: [], dataSources: [:])
        case "09f":
            // Muse with two sources allowed on the watch: their chips join Your questions.
            inputs.museState = .init(
                spokenQuestions: true, watchActions: [],
                dataSources: [.conversations: .allowed, .health: .allowed, .calendar: .ask])
        case "09e":
            inputs.aiDestination = "OpenAI"
            inputs.iCloudAgeDays = 60
            inputs.server = .init(
                host: host, paused: true, scope: .lastDays(90), clipsAllowed: false,
                editsAllowed: false, assistants: assistants([gpt, claude]))
        default:
            break
        }
        return inputs
    }

    /// The demo's settings (`-demo-data -assistantsDemo …`): both modes local, as the mockups'
    /// Settings root shows them.
    static func apply(to settings: AppSettings) {
        guard state != nil else { return }
        settings.transcriptionMode = .localOnly
        settings.aiMode = .localOnly
        settings.systemSearchVisibility = .summaries
        settings.coldStorageEnabled = false
    }
}

/// The cards on Connect.
enum ConnectCard: Hashable {
    case chatGPT, claude, mac, other
}

/// The Mac tools, as the Connect card's tabs and the server's `/connect/{tool}` pages.
enum MacTool: String, CaseIterable, Hashable {
    case codex, claudeCode = "claude-code", cursor

    var name: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        }
    }

    var mark: BrandMark {
        switch self {
        case .codex: return .codex
        case .claudeCode: return .claudeCode
        case .cursor: return .cursor
        }
    }
}

extension AssistantTime {
    /// When the person's logical day began (5 AM here): "From today on" starts here.
    static func logicalDayStart(_ nowMs: Int64, zone: TimeZone = .current) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        var start = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: now) ?? now
        if start > now { start = calendar.date(byAdding: .day, value: -1, to: start) ?? start }
        return Int64(start.timeIntervalSince1970 * 1000)
    }
}
