import AppIntents
import SwiftUI

// The card Siri shows under an Ask My Archive answer. It is the Ask screen's answer in small:
// the scope pill, the answer, Ask's partial-coverage line when part of the period was not read,
// and the conversations it came from in Ask's source-row style, each opening at the cited
// moment. One button: Open in Ask (the thread, to follow up) or, when there is no answer,
// Ask in Pebble Audio.
//
// Built only from system-rendered pieces — `Text`, stacks, SF Symbols, `Button(intent:)` — and
// no custom layout or gesture: Siri renders a snippet outside the app, and anything that needs
// the app's own run loop does not survive the trip.

struct AskArchiveSnippetView: View {
    let card: AskArchiveCard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            periodPill

            if let body = card.body {
                Text(body)
                    .font(AppFont.subBody)
                    .foregroundStyle(card.isAnswer ? Tokens.label : Tokens.secondaryBody)
                    .lineSpacing(4)
                    .lineLimit(10)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = card.partialNote {
                Text(note)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !card.sources.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(card.sources) { source in
                        Rectangle().fill(Tokens.hairline).frame(height: 0.5)
                        Button(intent: OpenAppLinkIntent(link: source.link)) {
                            sourceRow(source)
                        }
                        .buttonStyle(.plain)
                    }
                    if card.moreSources > 0 {
                        Text(Copy.Siri.moreSources(card.moreSources))
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.meta)
                            .padding(.top, 2)
                    }
                }
            }

            if let action = card.action {
                Button(intent: OpenAppLinkIntent(link: action.link)) {
                    Text(action.label)
                        .font(AppFont.cardHead)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Tokens.tint)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var periodPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar")
            Text(card.periodLabel)
        }
        .font(AppFont.chip)
        .foregroundStyle(Tokens.tint)
        .padding(.vertical, 4)
        .padding(.horizontal, 11)
        .background(Capsule().fill(Tokens.tintFill10))
        .accessibilityElement(children: .combine)
    }

    private func sourceRow(_ source: AskArchiveCard.Source) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.tint)
            Text(source.title)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.tint)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let when = source.when {
                Text(when)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

#if DEBUG
    /// `-siri-snippet-preview`: the card on its own, with made-up content, for screenshots in
    /// light and dark. It shows the card as this app draws it, not inside Siri's own chrome.
    struct AskArchiveSnippetPreview: View {
        static let launchArgument = "-siri-snippet-preview"

        static var isRequested: Bool {
            ProcessInfo.processInfo.arguments.contains(launchArgument)
        }

        static let sampleOutcome: AskArchiveOutcome = {
            let link = Route.conversation(id: "conv-sample", atMs: nil).url
            return AskArchiveOutcome(
                full: "",
                supporting: Copy.Siri.supporting(read: 6, period: .yesterday),
                card: AskArchiveCard(
                    periodLabel: Copy.Siri.periodLabel(.yesterday),
                    body: "You agreed to send Sam the revised lease by Friday, and Sam will "
                        + "check with the landlord about moving the start date to the 1st. You "
                        + "both said the deposit stays as it is.",
                    isAnswer: true,
                    partialNote: nil,
                    sources: [
                        AskArchiveCard.Source(
                            id: "conv-a", title: "Lease call with Sam", when: "Yesterday · 4:12 PM",
                            link: link),
                        AskArchiveCard.Source(
                            id: "conv-b", title: "Walk to the station", when: "Yesterday · 6:40 PM",
                            link: link),
                    ],
                    moreSources: 0,
                    action: AskArchiveCard.Action(
                        label: Copy.Siri.openInAsk, link: Route.askThread(id: nil, question: nil).url)
                )
            )
        }()

        static let sampleNotice = AskArchiveAnswerer.notice(
            spoken: Copy.Siri.tookTooLong, heading: Copy.Siri.tookTooLongHeading,
            line: Copy.Siri.tookTooLongLine, period: .last7Days,
            action: AskArchiveCard.Action(
                label: Copy.Siri.askInApp, link: Route.ask(scope: "last7", query: "x").url))

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    sample(Self.sampleOutcome)
                    sample(Self.sampleNotice)
                }
                .padding(16)
                .padding(.top, 40)
            }
            .background(Tokens.ground.ignoresSafeArea())
        }

        private func sample(_ outcome: AskArchiveOutcome) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                // Where Siri puts the supporting dialog: above the card.
                Text(outcome.supporting)
                    .font(AppFont.headline)
                    .foregroundStyle(Tokens.label)
                AskArchiveSnippetView(card: outcome.card)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(.regularMaterial))
            }
        }
    }
#endif
