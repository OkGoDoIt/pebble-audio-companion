import CompanionRuntime
import Foundation
import SearchKit

// The privacy model (`docs/privacy-model.md`) as one pure derivation: `PrivacyInputs` in, every
// sentence the Privacy screen, the Settings root, and each setup print out. The stance card's
// headline and line, the flow tree, "Where it goes", "Who can read your archive", and the
// commitments are all built from the same destination list here, so they can never say
// different things in different words. `PrivacyModelTests` pins every combination of the
// destinations.
//
// Rules this is written to:
// - Only destinations that are on are listed, in the model's order (D1, D2, D3, D5, D7). The
//   assistants reading the server (D6) hang off the server and count in the headline's N.
// - Never "Nothing else leaves this phone": the bundled third-party speech engine carries its
//   own network stack, so that blanket claim cannot be verified from source.
// - A paused server is still a destination: it holds text, and assistants can still read it.
// - Receivers by name; "text", "audio", "a clip", "your questions" — never a mechanism.

// MARK: - Inputs (privacy-model.md §2)

struct PrivacyInputs: Equatable {
    /// D1: who transcribes recorded audio; nil when transcription stays on this phone.
    var transcriptionDestination: String?
    /// D1 in Local first: the provider gets only what the on-device engine cannot finish.
    var transcriptionFallbackOnly = false
    /// D2: who writes summaries from transcript text and About You; nil when local only.
    var aiDestination: String?
    /// D2 in Local first.
    var aiFallbackOnly = false
    /// D3: audio older than this many days moves to the person's iCloud Drive; nil when off.
    var iCloudAgeDays: Int?
    /// D4: what the on-device search index may see. Nothing leaves.
    var systemSearch: SystemSearchVisibility = .summaries
    /// D5: nil only when no server is linked and set up (paused is a state, not nil).
    var server: ServerState?
    /// D7: nil when Muse is not paired. Supplied by the Muse feature.
    var museState: MuseState?

    struct ServerState: Equatable {
        var host: String
        /// Sync off: the server keeps what it has, and assistants can still read it.
        var paused: Bool
        var scope: ArchiveSharingScope
        /// D5a.
        var clipsAllowed: Bool
        /// D5b.
        var editsAllowed: Bool
        /// D6, from `GET /sync/status` `access`.
        var assistants: [Assistant]
        /// When the list was fetched, and whether the last fetch failed (then it says "As of").
        var assistantsFetchedAtMs: Int64?
        var assistantsStale = false
    }

    struct Assistant: Equatable, Hashable {
        var name: String
        /// The server lets it write (`archive:write`).
        var canWrite: Bool
        var lastUsedAtMs: Int64?
    }

    struct MuseState: Equatable {
        /// Push-to-talk shipped and on (`MuseGadgetService.asksFromWatch`): D7 names spoken
        /// questions too.
        var spokenQuestions: Bool
        /// D7b: the actions Muse may take on the watch. Only an outcome goes back (and, for
        /// music, what is playing).
        var watchActions: Set<MuseWatchAction>
        /// D7a, D7c–D7e: what Muse may read while answering. A missing key reads as `.off`.
        var dataSources: [MuseDataSource: MuseAccess]

        func access(_ source: MuseDataSource) -> MuseAccess { dataSources[source] ?? .off }
    }
}

// The Muse types the derivation owns, so main builds without the Muse feature; the Muse branch
// maps its own settings onto them (privacy-model.md §2).

/// D7b: what Muse may do on the watch while a question you asked is open.
enum MuseWatchAction: CaseIterable, Hashable {
    case timer, alarm, choice, music, quietTime, openApp, findWatch, recording
}

/// D7a, D7c–D7e, in this order everywhere a list names them.
enum MuseDataSource: CaseIterable, Hashable {
    case conversations, health, calendar, reminders, followUps

    /// How a sentence names it ("your health data").
    var readName: String {
        switch self {
        case .conversations: return "your conversations"
        case .health: return "your health data"
        case .calendar: return "your calendar"
        case .reminders: return "your reminders"
        case .followUps: return "your follow-ups"
        }
    }

    /// What Muse can add to it, when it can ("events").
    var addName: String? {
        switch self {
        case .calendar: return "events"
        case .reminders: return "reminders"
        case .followUps: return "follow-ups"
        case .conversations, .health: return nil
        }
    }

    /// Its chip on the Meta row, when Allowed.
    var chip: PrivacyChip {
        switch self {
        case .conversations: return PrivacyChip(icon: .text, label: "Conversations")
        case .health: return PrivacyChip(icon: .heart, label: "Health")
        case .calendar: return PrivacyChip(icon: .calendar, label: "Calendar")
        case .reminders: return PrivacyChip(icon: .checklist, label: "Reminders")
        case .followUps: return PrivacyChip(icon: .checklist, label: "Follow-ups")
        }
    }
}

/// "What Muse can see": Ask first (the default once paired), Allowed, or Off.
enum MuseAccess: Hashable {
    case ask, allowed, off
}

// MARK: - Output

struct PrivacyChip: Hashable {
    enum Icon: Hashable { case audio, text, read, question, heart, calendar, checklist }
    var icon: Icon
    var label: String
}

/// One place the PHONE sends to: a branch of the flow tree and a "Where it goes" row.
struct PrivacyDestination: Identifiable, Hashable {
    enum Kind: Hashable { case transcription, ai, transcriptionAndAI, iCloud, server, muse }
    /// The screen that controls it (the row's chevron).
    enum Control: Hashable { case transcription, storage, assistants, muse }

    var kind: Kind
    var name: String
    var why: String
    var chips: [PrivacyChip]
    /// The server's last line: "host · scope".
    var meta: String?
    /// The server while sync is paused: a dashed branch that says so.
    var paused = false
    var mark: BrandMark?
    var control: Control

    var id: Kind { kind }
}

/// Assistants that may do the same things, drawn together under the server.
struct PrivacyAssistantGroup: Hashable {
    var names: [String]
    var marks: [BrandMark]
    var chip: PrivacyChip
}

struct PrivacyAssistantRow: Hashable {
    var name: String
    var mark: BrandMark
    var lastRead: String
    var chip: PrivacyChip
}

struct PrivacyPresentation: Equatable {
    enum Dot { case good, neutral }

    var dot: Dot
    var headline: String
    var line: String
    /// Every destination, assistants included: the headline's N.
    var placeCount: Int
    /// The branches from This iPhone, and the "Where it goes" rows, in the model's order.
    var destinations: [PrivacyDestination]
    /// Under the server's branch. Empty with a server: the hollow "None yet" tile.
    var assistantGroups: [PrivacyAssistantGroup]
    /// Under "Where it goes": the rolling-window rule and Muse's sentence, word for word.
    var whereItGoesFooters: [String]
    /// "Who can read your archive", only with a server.
    var whoCanRead: [PrivacyAssistantRow]?
    var whoCanReadFooter: String?
    var commitments: [String]

    var hasFlow: Bool { !destinations.isEmpty }
}

// MARK: - Derivation

enum PrivacyModel {
    // The fixed commitments, each checked against the code (see `Copy+PrivacyStance.swift`).
    static let pebbleAppLine = "The official Pebble app never receives your audio."
    static let diagnosticsLine =
        "Diagnostic logs stay on this phone. They hold no audio and no transcript text, and are "
        + "only ever shared if you send them yourself from Diagnostics."
    static let storageLine =
        "Recordings, transcripts, and notes are stored in this app on your iPhone, and are "
        + "included in the iPhone's usual backups."
    static let spotlightLine =
        "Spotlight's index of your recordings is kept on this iPhone by iOS. What goes into "
        + "it — nothing, titles and summaries, or everything — is your choice on this screen."

    /// D7, word for word (privacy-model.md §3.1), with and without spoken questions.
    static let museSentence =
        "The questions you ask Muse go to Meta: typed ones as text, spoken ones as a short "
        + "recording. Its answers come back as text. Nothing goes while you aren't asking."
    static let museSentenceTyped =
        "The questions you ask Muse go to Meta as text. Its answers come back as text. Nothing "
        + "goes while you aren't asking."
    static let museTrainingLine =
        "Meta may use your questions to improve its AI. You can turn that off in the Muse app."

    static let serverName = "Your server"
    static let iCloudName = "iCloud Drive"
    static let metaName = "Meta"

    static func derive(_ inputs: PrivacyInputs, nowMs: Int64, zone: TimeZone = .current) -> PrivacyPresentation {
        let destinations = self.destinations(inputs, nowMs: nowMs, zone: zone)
        let assistants = inputs.server?.assistants ?? []
        let placeCount = destinations.count + assistants.count

        let (dot, headline, line) = stance(inputs, destinations: destinations, placeCount: placeCount)

        var footers: [String] = []
        if let server = inputs.server, case .lastDays(let days) = server.scope {
            footers.append(Copy.AssistantAccess.rollingLine(days))
        }
        if let muse = inputs.museState {
            footers.append(museLines(muse).joined(separator: " "))
        }

        var whoCanRead: [PrivacyAssistantRow]?
        var whoFooter: String?
        if let server = inputs.server {
            whoCanRead = assistants.map { assistant in
                PrivacyAssistantRow(
                    name: assistant.name, mark: BrandMark.forAssistant(named: assistant.name),
                    lastRead: assistant.lastUsedAtMs.map {
                        "Last read \(AssistantTime.ago($0, nowMs: nowMs, zone: zone))"
                    } ?? Copy.AssistantAccess.notReadYet,
                    chip: PrivacyChip(
                        icon: .read,
                        label: Copy.AssistantAccess.mayDo(
                            clips: server.clipsAllowed, add: server.editsAllowed && assistant.canWrite)))
            }
            var parts: [String] = []
            if server.assistantsStale, let at = server.assistantsFetchedAtMs {
                parts.append(Copy.AssistantAccess.asOf(at, zone: zone))
            }
            if !assistants.isEmpty { parts.append(Copy.AssistantAccess.whatTheyReadLine) }
            whoFooter = parts.isEmpty ? nil : parts.joined(separator: " ")
        }

        return PrivacyPresentation(
            dot: dot, headline: headline, line: line, placeCount: placeCount,
            destinations: destinations, assistantGroups: groups(inputs.server),
            whereItGoesFooters: footers, whoCanRead: whoCanRead, whoCanReadFooter: whoFooter,
            commitments: commitments(inputs, placeCount: placeCount))
    }

    /// One entry per destination the phone sends to, in the model's table order. A provider
    /// that both transcribes and writes is one place, with both chips.
    static func destinations(_ inputs: PrivacyInputs, nowMs: Int64, zone: TimeZone) -> [PrivacyDestination] {
        var out: [PrivacyDestination] = []
        let stt = inputs.transcriptionDestination
        let ai = inputs.aiDestination
        let transcribes = inputs.transcriptionFallbackOnly
            ? "Transcribes what this iPhone can't" : "Transcribes your recordings"
        let writes = inputs.aiFallbackOnly ? "Writes what this iPhone can't" : "Writes summaries"
        if let stt, let ai, stt == ai {
            out.append(
                PrivacyDestination(
                    kind: .transcriptionAndAI, name: stt,
                    why: inputs.transcriptionFallbackOnly || inputs.aiFallbackOnly
                        ? "\(transcribes), and \(writes.lowercasedFirst)"
                        : "Transcribes your recordings and writes summaries",
                    chips: [.init(icon: .audio, label: "Audio"), .init(icon: .text, label: "Text")],
                    mark: BrandMark.forProvider(named: stt), control: .transcription))
        } else {
            if let stt {
                out.append(
                    PrivacyDestination(
                        kind: .transcription, name: stt, why: transcribes,
                        chips: [.init(icon: .audio, label: "Audio")],
                        mark: BrandMark.forProvider(named: stt), control: .transcription))
            }
            if let ai {
                out.append(
                    PrivacyDestination(
                        kind: .ai, name: ai, why: writes, chips: [.init(icon: .text, label: "Text")],
                        mark: BrandMark.forProvider(named: ai), control: .transcription))
            }
        }
        if let days = inputs.iCloudAgeDays {
            out.append(
                PrivacyDestination(
                    kind: .iCloud, name: iCloudName,
                    why: "Keeps audio older than \(Copy.count(days, "day"))",
                    chips: [.init(icon: .audio, label: "Older audio")], mark: .icloud,
                    control: .storage))
        }
        if let server = inputs.server {
            let meta = "\(server.host) · \(Copy.AssistantAccess.scopeLabel(server.scope, zone: zone))"
            if server.paused {
                out.append(
                    PrivacyDestination(
                        kind: .server, name: serverName, why: Copy.AssistantAccess.pausedHeading,
                        chips: [], meta: meta, paused: true, control: .assistants))
            } else {
                var chips = [PrivacyChip(icon: .text, label: "Text")]
                if server.clipsAllowed { chips.append(.init(icon: .audio, label: "Clips when asked")) }
                out.append(
                    PrivacyDestination(
                        kind: .server, name: serverName, why: "So your assistants can read it",
                        chips: chips, meta: meta, control: .assistants))
            }
        }
        if let muse = inputs.museState {
            // One chip per source Muse may read without asking; Ask first and Off get none.
            let chips = [PrivacyChip(icon: .question, label: "Your questions")]
                + MuseDataSource.allCases.filter { muse.access($0) == .allowed }.map(\.chip)
            out.append(
                PrivacyDestination(
                    kind: .muse, name: metaName, why: "Answers your questions", chips: chips,
                    mark: .meta, control: .muse))
        }
        return out
    }

    /// D7 and "What Muse can see" (privacy-model.md §3.1), word for word, each line only when its
    /// list is not empty, lists in `MuseDataSource` order with the Oxford comma.
    static func museLines(_ muse: PrivacyInputs.MuseState) -> [String] {
        var lines = [muse.spokenQuestions ? museSentence : museSentenceTyped]
        let allowed = MuseDataSource.allCases.filter { muse.access($0) == .allowed }
        let askFirst = MuseDataSource.allCases.filter { muse.access($0) == .ask }
        let readable = MuseDataSource.allCases.filter { muse.access($0) != .off }
        if !allowed.isEmpty {
            lines.append(
                "When you ask, Muse can also read \(Copy.list(allowed.map(\.readName))) to answer. "
                    + "What it reads goes to Meta.")
        }
        if !askFirst.isEmpty {
            lines.append("Muse asks on your watch before it reads \(Copy.list(askFirst.map(\.readName))).")
        }
        if readable.contains(.conversations) {
            lines.append("Your conversations can include what other people said.")
        }
        let adds = readable.compactMap(\.addName)
        if !adds.isEmpty {
            lines.append("Muse can add \(Copy.list(adds)) you ask for. It never deletes them.")
        }
        if muse.watchActions.contains(.music) {
            lines.append("When you ask what's playing, the song's title and artist go to Meta.")
        }
        return lines
    }

    /// Assistants that may do the same things share one node; different permissions get their
    /// own, so a chip never claims more for one assistant than it may do.
    static func groups(_ server: PrivacyInputs.ServerState?) -> [PrivacyAssistantGroup] {
        guard let server, !server.assistants.isEmpty else { return [] }
        var order: [String] = []
        var byLabel: [String: [PrivacyInputs.Assistant]] = [:]
        for assistant in server.assistants {
            let label = Copy.AssistantAccess.mayDo(
                clips: server.clipsAllowed, add: server.editsAllowed && assistant.canWrite)
            if byLabel[label] == nil { order.append(label) }
            byLabel[label, default: []].append(assistant)
        }
        return order.map { label in
            let members = byLabel[label] ?? []
            return PrivacyAssistantGroup(
                names: members.map(\.name),
                marks: members.map { BrandMark.forAssistant(named: $0.name) },
                chip: PrivacyChip(icon: .read, label: label))
        }
    }

    static func stance(
        _ inputs: PrivacyInputs, destinations: [PrivacyDestination], placeCount: Int
    ) -> (PrivacyPresentation.Dot, String, String) {
        if placeCount == 0 {
            return (
                .good, "Everything stays on this phone",
                "Transcription and AI both run on this iPhone. No recording, transcript, or note is "
                    + "sent to any service."
            )
        }
        guard placeCount == 1, let only = destinations.first else {
            return (.neutral, "Your data goes to \(Copy.countWord(placeCount)) places you chose", "Each is listed below.")
        }
        switch only.kind {
        case .transcription:
            return (
                .neutral, "Audio goes to \(only.name)",
                "Recordings are sent to \(only.name) to be transcribed. Summaries and notes are "
                    + "written on this iPhone."
            )
        case .ai:
            return (
                .neutral, "Text goes to \(only.name)",
                "Transcripts and About You go to \(only.name) to write summaries and notes. Audio "
                    + "stays on this phone."
            )
        case .transcriptionAndAI:
            return (
                .neutral, "Audio and text go to \(only.name)",
                "Recordings go to \(only.name) to be transcribed, then the transcripts and About "
                    + "You to write summaries and notes."
            )
        case .iCloud:
            return (
                .neutral, "Older audio goes to iCloud Drive",
                "Audio older than \(Copy.count(inputs.iCloudAgeDays ?? 0, "day")) moves to your own "
                    + "iCloud Drive. Transcripts stay on this phone."
            )
        case .server:
            let server = inputs.server
            if only.paused {
                return (.neutral, "Your server keeps your text", "Sync is paused.")
            }
            return (
                .neutral, "Text syncs to \(server?.host ?? "your server")",
                server?.clipsAllowed == true
                    ? "Your conversations' text goes to your own server, and a clip only when an "
                        + "assistant asks."
                    : "Your conversations' text goes to your own server. Audio stays on this phone."
            )
        case .muse:
            return (.neutral, "Your questions to Muse go to Meta", "Nothing goes while you aren't asking.")
        }
    }

    /// The vendors whose own keeping is theirs to govern: D1, D2, each assistant (D6), and Meta
    /// (D7). Not iCloud Drive: that is the person's own account.
    static func vendors(_ inputs: PrivacyInputs) -> [String] {
        var names: [String] = []
        if let stt = inputs.transcriptionDestination { names.append(stt) }
        if let ai = inputs.aiDestination { names.append(ai) }
        for assistant in inputs.server?.assistants ?? [] {
            names.append(BrandMark.vendorName(ofAssistant: assistant.name))
        }
        if inputs.museState != nil { names.append(metaName) }
        return Copy.uniqueNames(names)
    }

    static func commitments(_ inputs: PrivacyInputs, placeCount: Int) -> [String] {
        var out: [String] = []
        if placeCount == 0 {
            out.append(
                "This app has no account and no server of its own. Nothing you record, transcribe, "
                    + "or write is sent to its developer, and none of it is used for training, "
                    + "advertising, or profiling.")
            out.append(
                "Your recordings and transcripts are never sold or shared. They go only where this "
                    + "screen says they go.")
        } else {
            var first =
                "This app has no account of its own. Nothing you record, transcribe, or write is "
                + "sent to its developer, and this app uses none of it for training, advertising, "
                + "or profiling."
            if inputs.server != nil {
                first += " Your server holds a copy of the text because you linked it."
            }
            out.append(first)
            out.append(
                "Your recordings and transcripts are never sold. They go only where this screen "
                    + "says they go.")
        }
        let vendors = self.vendors(inputs)
        if vendors.count == 1 {
            out.append("What \(vendors[0]) keeps is governed by \(vendors[0]), not by this app.")
        } else if vendors.count > 1 {
            out.append("What \(Copy.list(vendors)) keep is governed by them, not by this app.")
        }
        if inputs.museState != nil { out.append(museTrainingLine) }
        out += [pebbleAppLine, diagnosticsLine, storageLine, spotlightLine]
        return out
    }

    // MARK: - The short forms elsewhere

    /// The Settings root's Privacy row value.
    static func rowValue(_ inputs: PrivacyInputs, nowMs: Int64) -> String {
        let presentation = derive(inputs, nowMs: nowMs)
        guard presentation.placeCount > 0 else { return Copy.Settings.Root.privacyLocal }
        let names = presentation.destinations.map { $0.kind == .server ? "your server" : $0.name }
        if presentation.placeCount == names.count, names.count <= 2 {
            return Copy.list(names).capitalizedFirst
        }
        return "\(presentation.placeCount.formatted()) places"
    }

    /// The Settings root's footer: where recordings and their text go, in one or two sentences.
    static func rootFooter(_ inputs: PrivacyInputs) -> String {
        var parts: [String] = []
        if inputs.transcriptionDestination != nil || inputs.aiDestination != nil {
            parts.append(
                Copy.Privacy.dataFlow(
                    transcription: inputs.transcriptionDestination, ai: inputs.aiDestination))
        }
        if let server = inputs.server {
            parts.append(
                server.paused
                    ? "Your server keeps a copy of their text."
                    : "Conversation text syncs to your server.")
        }
        if inputs.iCloudAgeDays != nil { parts.append("Older audio moves to your iCloud Drive.") }
        if parts.isEmpty { return Copy.Privacy.dataFlow(transcription: nil, ai: nil) }
        if parts.count == 1, inputs.server != nil, inputs.transcriptionDestination == nil,
            inputs.aiDestination == nil
        {
            return "Recordings stay on this phone. " + parts[0]
        }
        return parts.joined(separator: " ")
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
