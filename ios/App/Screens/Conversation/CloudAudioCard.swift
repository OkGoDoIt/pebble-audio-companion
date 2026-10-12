import CompanionRuntime
import SwiftUI

/// Stands where the player stands when the conversation's audio is in iCloud: a cloud glyph
/// in the play button's place, one line saying where the audio is, one saying what the button
/// does, and the button. The same height as the player card so the swap does not move the
/// transcript under the reader's eye.
///
/// Two states besides the ordinary one. Fetching: the button becomes a spinner and the line
/// says so; nothing else changes, because nothing else has. Unreachable: there is no button,
/// because there is nothing a tap could do — the line says what would make it reachable.
struct CloudAudioCard: View {
    let availability: AudioAvailability
    let fetching: Bool
    let error: String?
    let onFetch: () -> Void

    private var reachable: Bool { availability == .inCloud }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Tokens.tintFill12)
                Image(systemName: fetching ? "icloud.and.arrow.down" : "icloud")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Tokens.tint)
                    .symbolEffect(.pulse, isActive: fetching)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(AppFont.cardHead)
                    .foregroundStyle(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(line)
                    .font(AppFont.footnote)
                    .foregroundStyle(error == nil ? Tokens.meta : Tokens.secondaryBody)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)

            if reachable {
                Button(action: onFetch) {
                    if fetching {
                        ProgressView().controlSize(.small)
                            .frame(minWidth: 44)
                    } else {
                        Text(Copy.Conversation.fetchAudio)
                            .frame(minWidth: 44)
                    }
                }
                .buttonStyle(.smallBordered)
                .disabled(fetching)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Tokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        reachable ? Copy.Conversation.audioInCloud : Copy.Conversation.audioInCloudUnreachable
    }

    private var line: String {
        if let error { return error }
        if fetching { return Copy.Conversation.fetchingAudio }
        return reachable
            ? Copy.Conversation.audioInCloudLine : Copy.Conversation.audioInCloudUnreachableLine
    }
}

#Preview("Cloud audio") {
    VStack(spacing: 12) {
        CloudAudioCard(availability: .inCloud, fetching: false, error: nil) {}
        CloudAudioCard(availability: .inCloud, fetching: true, error: nil) {}
        CloudAudioCard(availability: .inCloud, fetching: false, error: "iCloud is taking too long. Check the connection and try again.") {}
        CloudAudioCard(availability: .inCloudUnreachable, fetching: false, error: nil) {}
    }
    .padding()
    .background(Tokens.ground)
}
