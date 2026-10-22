import SwiftUI

/// The rows above the reminders, on the Reminders tab and on Today (mockup v4 frames 1 and 8).
///
/// With follow-ups waiting: "3 follow-ups to review" with the first one under it and a Review
/// button, and below it, quietly, "4 reminders added from today", which opens the summary.
/// With nothing waiting: one row, "4 reminders added from today · Nothing left to review".
/// With neither: nothing at all.
struct ReminderEntryCard: View {
    let digest: ReminderDigestModel
    let open: (ReminderSheet) -> Void

    var body: some View {
        if !digest.isEmpty {
            ListCard(rowVerticalPadding: 11) {
                if digest.toReview > 0 {
                    reviewRow
                    if digest.addedToday > 0 {
                        addedLine
                    }
                } else {
                    addedRow
                }
            }
        }
    }

    private var reviewRow: some View {
        Button {
            open(.review)
        } label: {
            HStack(spacing: 12) {
                tile(systemImage: "checklist")
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.Reminders.toReview(digest.toReview))
                        .font(AppFont.rowTitle)
                        .foregroundStyle(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                    if let first = digest.firstToReview {
                        Text(first)
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.meta)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(Copy.Reminders.review)
                    .font(AppFont.cardHead)
                    .foregroundStyle(Tokens.onTint)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Capsule().fill(Tokens.tint))
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// Indented under the review row's text: the same thing, already settled.
    private var addedLine: some View {
        Button {
            open(.summary)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityHidden(true)
                Text(Copy.Reminders.addedFromToday(digest.addedToday))
                    .font(AppFont.subBody)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                chevron
            }
            .foregroundStyle(Tokens.tint)
            .padding(.leading, 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var addedRow: some View {
        Button {
            open(.summary)
        } label: {
            HStack(spacing: 12) {
                tile(systemImage: "checkmark")
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.Reminders.addedFromToday(digest.addedToday))
                        .font(AppFont.rowTitle)
                        .foregroundStyle(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Copy.Reminders.nothingLeftToReview)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                chevron
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func tile(systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(Tokens.tintFill12)
            .frame(width: 36, height: 36)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Tokens.tint))
            .accessibilityHidden(true)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Tokens.chevron)
            .accessibilityHidden(true)
    }
}
