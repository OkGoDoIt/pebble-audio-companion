import SwiftUI

/// One proportional bar of named parts, and the legend under it. Used by the Storage screen
/// for "what is on this phone" and for the recordings' phone/iCloud split.
///
/// Drawn as a single rounded track with hairline gaps between parts, so it reads as one
/// quantity divided rather than as several bars: the question it answers is "of this, how
/// much is which", and a part under 1% is still drawn at a minimum width so it does not vanish
/// from the legend's story. Parts are drawn in the order given; a `nil` colour is the track
/// itself (the unused remainder).
struct StorageBar: View {
    struct Part: Identifiable, Equatable {
        let id: String
        var bytes: Int64
        var color: Color
        /// Hatched rather than filled: for a part that is spoken for but not yet moved.
        var hatched: Bool = false
    }

    let parts: [Part]
    /// The whole the parts are measured against. Parts summing to less than this leave the
    /// remainder as bare track.
    var total: Int64
    var height: CGFloat = 10

    private nonisolated static let gap: CGFloat = 1.5
    private nonisolated static let minimumVisible: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let widths = Self.widths(parts.map(\.bytes), total: total, in: geo.size.width)
            HStack(spacing: Self.gap) {
                ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                    if widths[index] > 0 {
                        ZStack {
                            Rectangle().fill(part.color)
                            if part.hatched {
                                DiagonalStripes(spacing: 4)
                                    .stroke(Tokens.surface.opacity(0.7), lineWidth: 1.5)
                            }
                        }
                        .frame(width: widths[index])
                    }
                }
                if widths.reduce(0, +) < geo.size.width - Self.gap {
                    Rectangle().fill(Color.clear)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .background(Tokens.track)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    /// Pixel widths: proportional, with any non-zero part at least `minimumVisible`, and the
    /// gaps taken out of the largest part so the bar never overflows.
    nonisolated static func widths(_ bytes: [Int64], total: Int64, in width: CGFloat) -> [CGFloat] {
        guard total > 0, width > 0 else { return bytes.map { _ in 0 } }
        let visible = bytes.filter { $0 > 0 }.count
        let usable = max(width - CGFloat(max(visible - 1, 0)) * gap, 0)
        var widths = bytes.map { $0 > 0 ? max(CGFloat($0) / CGFloat(total) * usable, minimumVisible) : 0 }
        let overflow = widths.reduce(0, +) - usable
        if overflow > 0, let largest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            widths[largest] = max(widths[largest] - overflow, minimumVisible)
        }
        return widths
    }
}

/// One legend row: a swatch, the name, and the size on the right.
struct StorageLegendRow: View {
    let color: Color
    var hatched: Bool = false
    let title: String
    let value: String
    var note: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(color)
                if hatched {
                    DiagonalStripes(spacing: 3)
                        .stroke(Tokens.surface.opacity(0.7), lineWidth: 1)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
            Text(title)
                .font(AppFont.subBody)
                .foregroundStyle(Tokens.label)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if let note {
                Text(note)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(AppFont.subBody.monospacedDigit())
                .foregroundStyle(Tokens.secondaryBody)
                .lineLimit(1)
                // The number is the point of the row: it never truncates, the title does.
                .layoutPriority(1)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Storage bar") {
    VStack(alignment: .leading, spacing: 12) {
        StorageBar(
            parts: [
                .init(id: "audio", bytes: 2_100, color: Tokens.tint),
                .init(id: "text", bytes: 330, color: Tokens.tintSoft),
                .init(id: "model", bytes: 2_360, color: Tokens.quiet),
                .init(id: "tmp", bytes: 6_190, color: Tokens.quiet, hatched: true),
            ],
            total: 11_000)
        StorageLegendRow(color: Tokens.tint, title: "Recordings", value: "2.1 GB")
        StorageLegendRow(color: Tokens.tintSoft, title: "Transcripts & index", value: "331 MB")
        StorageLegendRow(color: Tokens.quiet, title: "Speech model & cache", value: "2.4 GB")
        StorageLegendRow(color: Tokens.quiet, hatched: true, title: "Temporary files", value: "6.2 GB", note: "cleaned at next launch")
    }
    .padding()
    .background(Tokens.surface)
}
