import AppDB
import Foundation
import Transcription

// Method 2 of the audio-content classification: an AI reading of what a segment's words ARE.
//
// The word-rate rules (method 1) cannot tell lyrics, a TV show or a station announcement from
// talk: they arrive at talking speed. Only the words can. Measured on the phone through the
// app's own OpenAI key (the `AnalysisJobRunner` channel), one call per segment with its minutes
// numbered, GPT-5.6 Luna, against 250 hand-labelled minutes (see the design doc):
//
// - music 12/12, tvOrVideo 2/2, announcement 4/4, loop 3/3 correct — 22/22, and an independent
//   listening model (gpt-audio-1.5) agreed with every lyric, TV and announcement label;
// - "gibberish" is not separable: on minutes the prompt had never seen, it called most of them
//   conversation, and once called garbled real dictation gibberish;
// - "fewWords" it applies to pauses inside conversations; method 1 handles those better.
//
// A second round checked 142 more minutes it would act on, labelled blind from the transcripts:
// lyrics 58/60 right (the other two unclear, never talk), TV 36/40, announcements 12/12, but
// "loop" only 22/30, with 4 real conversations among the misses. So music, TV and announcements
// at 0.9 or more change a verdict, and only lyrics are named ("music"): TV misses the 95% bar
// and announcements have too few examples. `AudioContentMethod` holds the numbers.

public enum AudioContentJudge {
    /// Bump when the prompt or the reading of its answer changes; every stored judgement is
    /// then asked again.
    public static let promptVersion = 1

    // Which judged kinds act, at what confidence, is `AudioContentMethod.judgeActionableKinds`
    // (the classifier applies them). The prompt still asks for every kind: what is not acted on
    // is kept with the judgement, so a later method can use it without asking again.

    /// Minute text is capped so one looping minute cannot swamp a call.
    static let maxMinuteChars = 2_500

    public static let template = AiPromptTemplate(
        id: "audio-content-judge",
        title: "What the audio is",
        systemPrompt: """
            You read the transcript of one recording (up to about 15 minutes) from a microphone \
            worn on a person's wrist all day (the wearer). It transcribes everything it hears: \
            the wearer's conversations, dictation to a phone or AI assistant, calls, talking to \
            children or staff, but also TV, films and videos, songs, public announcements, other \
            people nearby, and transcription errors (the same few words repeated over quiet \
            audio). Transcription is automatic and imperfect; words are often misheard and the \
            text may be in any language.

            Lines are grouped by minute: [m0], [m1], ... Speaker labels (S1, S2) are guesses. For \
            EVERY minute listed, say what that minute mostly is:
            - conversation: the wearer or people present talking, including dictation, calls, \
            talking to a child or to staff, even if brief or garbled.
            - music: song lyrics or singing.
            - tvOrVideo: TV, film, video, podcast, radio, an advert: scripted or broadcast speech \
            not addressed to the people present.
            - announcement: public-address speech (transit stops, flight safety, gate calls).
            - performance: a live show, an MC or a speech to an audience the wearer is part of.
            - loop: the transcriber repeating the same few words many times; not real speech.
            - gibberish: disconnected fragments that never add up to sentences or an exchange, \
            typically quiet or distant speech misheard.
            - fewWords: only a word or two, not an exchange and not dictation.
            - unclear: you cannot tell.
            Use the minutes around each one as context. If a conversation happens over music or \
            TV, answer conversation. A back-and-forth that is badly transcribed is still \
            conversation. Prefer unclear to a guess.
            Reply with JSON only: {"minutes":[{"m":<minute number>,"kind":"<label>","confidence":<0 to 1>}, ...]}
            """,
        userPrompt: "Classify every minute.")

    /// What a stored judgement answered: the transcript version and the prompt version.
    public static func inputKey(transcriptVersion: String) -> String {
        "p\(promptVersion)|\(transcriptVersion)"
    }

    /// The segment's turns grouped by minute of stored audio, as the model reads them. Nil when
    /// there are no words to judge.
    public static func input(turns: [TranscriptSegment]) -> String? {
        var byMinute: [Int: [String]] = [:]
        for turn in turns {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let middle = turn.startMs + max(turn.endMs - turn.startMs, 0) / 2
            let minute = Int(max(middle, 0) / 60_000)
            let speaker = turn.speaker.map { "S\($0): " } ?? ""
            byMinute[minute, default: []].append(speaker + text)
        }
        guard !byMinute.isEmpty else { return nil }
        return byMinute.keys.sorted().map { minute in
            var text = byMinute[minute, default: []].joined(separator: "\n")
            if text.count > maxMinuteChars { text = String(text.prefix(maxMinuteChars)) + " …" }
            return "[m\(minute)]\n\(text)"
        }.joined(separator: "\n\n")
    }

    /// The minutes in a reply, leniently: the first JSON object in the text, unknown fields
    /// ignored, malformed entries dropped. Nil when there is no usable answer at all.
    public static func parse(_ reply: String) -> [JudgedMinute]? {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"),
            open < close
        else { return nil }
        struct Reply: Decodable {
            struct Minute: Decodable {
                var m: Int?
                var kind: String?
                var confidence: Double?
            }
            var minutes: [Minute]?
        }
        guard let decoded = try? JSONDecoder().decode(
            Reply.self, from: Data(reply[open...close].utf8))
        else { return nil }
        let minutes = (decoded.minutes ?? []).compactMap { minute -> JudgedMinute? in
            guard let m = minute.m, let kind = minute.kind, m >= 0 else { return nil }
            return JudgedMinute(m: m, kind: kind, confidence: min(max(minute.confidence ?? 0, 0), 1))
        }
        return minutes
    }
}
