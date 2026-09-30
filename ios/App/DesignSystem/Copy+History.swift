import AppDB
import Foundation
import SegmentStore
import StatusUI
import WireProtocol

// Every word the History tab shows (plan 5). The read side hands the screen facts — kinds,
// causes, counts, times — and this file is the only place they become words, so the tab cannot
// say something its data does not support.
//
// Vocabulary rules for this area:
// - "Quiet" is only ever time the watch was listening and heard nothing. Time nobody was
//   listening is "Not recording" (in the day) or "Nothing recorded" (at its ends).
// - Loss is "Audio missing", calm and explicit, with a cause only when one was recorded — and
//   that cause reads exactly as it does everywhere else in the app (`gapDescription`).
// - "Follow-ups", never "Actions" (Copy.Tabs rule).
//
// Kept out of `Copy.swift` because that file is the shared catalog the widget also compiles.

extension Copy {
    enum History {

        // MARK: Tab and levels

        static let tab = "History"
        static let day = "Day"
        static let week = "Week"
        static let month = "Month"
        static let levelControl = "Zoom"
        static let today = "Today"
        static let jumpToDate = "Jump to date"
        static let search = "Search"

        // MARK: The in-brief card (5.2)

        static let dayInBrief = "The day in brief"
        static let weekInBrief = "The week in brief"
        static let monthInBrief = "The month in brief"
        static let todaySoFar = "Today so far"
        /// The card's one gray line when there is no brief yet (5.8).
        static let noSummaryYet = "No summary yet"
        static let waitingToTranscribe = "Waiting to transcribe"
        /// Under the brief while the day is drawn from conversations and chapters are coming.
        static let topicsPreparing = "Topics are being prepared"

        /// The card's footer: "4 follow-ups · 2 open", "1 follow-up · open",
        /// "6 follow-ups · all done". Every count is true; nothing is rounded into a word.
        static func followUpCount(total: Int, open: Int) -> String {
            guard total > 0 else { return "No follow-ups" }
            let noun = total == 1 ? "1 follow-up" : "\(total) follow-ups"
            if open == 0 { return total == 1 ? "\(noun) · done" : "\(noun) · all done" }
            if total == 1 { return "\(noun) · open" }
            return "\(noun) · \(open) open"
        }

        /// Appended on today: " · updated 11:15 AM".
        static func updated(_ time: String) -> String { "updated \(time)" }

        /// A month's tag pill: "apartment 14" (days the tag appears on).
        static func tagCount(_ name: String, days: Int) -> String { "\(name) \(days)" }

        // MARK: The ends of the day (5.3)

        static func quietUntil(_ time: String) -> String { "Quiet until \(time)" }
        static func quietAfter(_ time: String) -> String { "Quiet after \(time)" }
        /// `.notListening` edges: nobody was listening, so it must not be called quiet.
        static func nothingRecordedUntil(_ time: String) -> String { "Nothing recorded until \(time)" }
        static func nothingRecordedAfter(_ time: String) -> String { "Nothing recorded after \(time)" }

        static func edge(_ kind: HistoryEdge.Kind, leading: Bool, time: String) -> String {
            switch (kind, leading) {
            case (.quiet, true): return quietUntil(time)
            case (.quiet, false): return quietAfter(time)
            case (.notListening, true): return nothingRecordedUntil(time)
            case (.notListening, false): return nothingRecordedAfter(time)
            }
        }

        // MARK: Gaps (5.3 "Gap kinds")

        static let quiet = "Quiet"
        static let paused = "Paused"
        static let audioMissing = "Audio missing"
        static let notRecording = "Not recording"
        static let noConversation = "No conversation"
        /// A no-conversation gap whose audio classifier supplied an accurate descriptor.
        static let backgroundAudio = "Background audio"
        static let notTranscribedYet = "Not transcribed yet"
        static let couldNotBeTranscribed = "Could not be transcribed"
        static let deletedByYou = "Deleted by you"
        static let removedToSaveSpace = "Removed to save space"

        /// The gap's name, before its duration.
        static func gapName(_ gap: HistoryGap) -> String {
            switch gap.kind {
            case .quiet: return quiet
            case .paused: return paused
            case .audioMissing: return audioMissing
            case .notRecording: return notRecording
            case .noConversation: return gap.descriptor == nil ? noConversation : backgroundAudio
            case .notTranscribedYet: return notTranscribedYet
            case .transcriptionFailed: return couldNotBeTranscribed
            case .deleted: return gap.deletedBy == .retention ? removedToSaveSpace : deletedByYou
            }
        }

        /// "Quiet · 1 hr 5 min".
        static func gapLabel(_ name: String, duration: String) -> String { "\(name) · \(duration)" }

        /// An open-ended gap at the end of today: "Paused since 2:30 PM".
        static func since(_ name: String, time: String) -> String { "\(name) since \(time)" }

        /// Who paused capture, as the second line says it.
        static func pauseActor(_ actor: HistoryPauseActor) -> String {
            switch actor {
            case .you: return "you paused capture"
            case .timed: return "timed pause"
            case .watchPowerSave: return watchGapDescription(for: .powerSave)
            case .other: return "capture was paused"
            }
        }

        /// A recorded cause of lost audio, worded exactly as `gapDescription` words the same
        /// record everywhere else in the app (the conversation's markers, the coverage sheet).
        /// Built by asking `gapDescription` itself, so the two can never drift apart.
        static func lossCause(_ cause: HistoryLossCause) -> String {
            switch cause {
            case .watchBufferFull: return watchGapDescription(for: .spoolOverflow)
            case .watchDictation: return watchGapDescription(for: .micConflict)
            case .stoppedOnWatch: return watchGapDescription(for: .userDisabled)
            case .watchBattery: return watchGapDescription(for: .lowBattery)
            case .watchAudioFault: return watchGapDescription(for: .codecError)
            case .connectionReset: return watchGapDescription(for: .transportReset)
            case .phoneMissedAudio:
                // A phone-side skip the length of a History gap is never "brief".
                return gapDescription(
                    GapMeta(
                        firstMissingSequence: 0, missingFrameCount: 0, firstMissingSampleIndex: 0,
                        origin: GapMeta.originSequenceSkip),
                    displayedDurationMs: 60 * 60_000)
            }
        }

        private static func watchGapDescription(for reason: GapReason) -> String {
            gapDescription(
                GapMeta(
                    firstMissingSequence: 0, missingFrameCount: 0, firstMissingSampleIndex: 0,
                    origin: GapMeta.originWatch, reasonRaw: Int(reason.rawValue)))
        }

        /// A no-conversation descriptor as its second line ends: "music, no conversation".
        static func descriptorLine(_ descriptor: String) -> String { "\(descriptor), no conversation" }

        /// The detail after a gap's time range, when the data holds one. Nil when nothing was
        /// recorded about why — the line is then just the time range.
        static func gapDetail(_ gap: HistoryGap) -> String? {
            switch gap.kind {
            case .paused: return gap.pausedBy.map(pauseActor)
            case .audioMissing: return gap.lossCauses.first.map(lossCause)
            case .noConversation: return gap.descriptor.map(descriptorLine)
            case .transcriptionFailed: return gap.failureReason
            case .quiet, .notRecording, .notTranscribedYet, .deleted: return nil
            }
        }

        /// "Times from here in Jakarta time".
        static func zoneChange(_ place: String) -> String { "Times from here in \(place) time" }

        /// A zone identifier as a place: "America/Los_Angeles" → "Los Angeles".
        static func place(ofZone zoneID: String) -> String {
            let city = zoneID.split(separator: "/").last.map(String.init) ?? zoneID
            return city.replacingOccurrences(of: "_", with: " ")
        }

        // MARK: Chapter cards (5.3 "Chapter card")

        /// The title of a card drawn from an untitled conversation stretch.
        static let conversation = "Conversation"
        /// "· 4 min missing" on a card's time line.
        static func missing(_ duration: String) -> String { "\(duration) missing" }
        /// The prefix for a time read from a recording whose clock is not exact.
        static func approximately(_ times: String) -> String { "about \(times)" }
        /// The card's long-press menu (5.3).
        static let open = "Open"
        static let shareSummary = "Share summary"
        static let copySummary = "Copy summary"
        /// Trailing a collapsed follow-up line, or under a week row's two: "3 more".
        static func more(_ count: Int) -> String { "\(count) more" }

        // MARK: Today (5.3 "Today")

        static let recordingNow = "Recording now"
        /// The live transcript's last line, as a fragment of something still being said.
        static func liveQuote(_ line: String) -> String { "“…\(line)…”" }
        /// "11:20 AM · 21 min so far".
        static func liveTime(start: String, soFar: String) -> String { "\(start) · \(soFar) so far" }

        // MARK: Durations

        static let underOneMinute = "under 1 min"
        static let underOneMinuteSpoken = "under a minute"

        // MARK: Week and month (5.4, 5.5)

        static let nothingRecorded = "Nothing recorded"
        /// "13 hr waiting to transcribe".
        static func waitingToTranscribe(_ duration: String) -> String {
            "\(duration) waiting to transcribe"
        }
        static let thisWeek = "This week"

        // MARK: States (5.8)

        static let nothingRecordedYet = "Nothing recorded yet"
        static let nothingRecordedYetLine =
            "Days you record appear here. Today shows whether the watch is recording."

        // MARK: Accessibility (5.9)

        enum A11y {
            /// "2 follow-ups, 1 open".
            static func followUps(total: Int, open: Int) -> String {
                guard total > 0 else { return "" }
                let noun = total == 1 ? "1 follow-up" : "\(total) follow-ups"
                if open == 0 { return total == 1 ? "\(noun), done" : "\(noun), all done" }
                return "\(noun), \(open) open"
            }
            static func topics(_ names: [String]) -> String {
                "topic\(names.count == 1 ? "" : "s"): " + names.joined(separator: ", ")
            }
            static func people(_ names: [String]) -> String { "with " + names.joined(separator: ", ") }
            static func missing(_ spokenDuration: String) -> String {
                "\(spokenDuration) of audio missing"
            }
            static func approximately(_ spokenRange: String) -> String { "about \(spokenRange)" }
            static func followUpAction(_ text: String) -> String { "Follow-up: \(text)" }
            static let openHint = "Opens the conversation at this point"
            static let openRecordingHint = "Opens the recording"
            static let openDayHint = "Opens this day"
            /// "apartment, on 14 days".
            static func tagDays(_ name: String, days: Int) -> String {
                "\(name), on \(days) day\(days == 1 ? "" : "s")"
            }
            static let titleHint = "Swipe up or down for the next or previous period"
            static let openWeekHint = "Opens this week"
            static let hourAxis = "Hour axis"
            static let now = "Now"
            static let followUpDone = "done"
        }
    }
}
