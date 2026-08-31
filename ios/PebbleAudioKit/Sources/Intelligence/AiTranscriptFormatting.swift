import Foundation

// Port of `core/ai/.../AiTranscriptFormatting.kt`.

/// Builds the user-message body for an `AiRunRequest`: the prompt's user instruction followed
/// by each transcript segment, bounded to `maxInputChars` (always-on recorder transcripts can
/// be very large). Shared by the cloud and on-device providers so they format identical input.
enum AiTranscriptFormatting {
    static func buildUserContent(_ request: AiRunRequest, maxInputChars: Int) -> String {
        var content = ""
        content += request.prompt.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        content += "\n\n"
        for transcript in request.transcripts {
            // A citing template addresses its sources by number: the raw id is what models
            // copy into the prose as "seg-01H..." or an invented markdown link. Numbered input
            // is also a STRETCH of a recording rather than a whole one, so it is named as such.
            if let number = transcript.citationNumber {
                content += "--- Transcript excerpt [\(number)]"
            } else {
                content += "--- Transcript segment \(transcript.segmentId)"
            }
            if let timeLabel = transcript.timeLabel {
                content += " (starts \(timeLabel))"
            } else if let startTimeMs = transcript.startTimeMs {
                content += " (starts at epoch ms \(startTimeMs))"
            }
            content += " ---\n"
            content += transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            content += "\n\n"
        }
        if content.count <= maxInputChars { return content }
        return String(content.prefix(maxInputChars)) + "\n[transcript truncated for length]"
    }
}
