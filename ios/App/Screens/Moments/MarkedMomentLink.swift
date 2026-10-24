import AppDB
import SwiftUI

struct MarkedMomentLink: View {
    let id: String
    let text: String
    @State private var showing = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button { showing = true } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "pin.fill").accessibilityHidden(true)
                Text(text).multilineTextAlignment(.leading).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true)
                }
            }
            .font(AppFont.footnote).foregroundStyle(Tokens.tint)
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHint("Open saved moment and its note")
        .sheet(isPresented: $showing) { SavedMomentSheet(id: id) }
    }
}

/// Marks are authoritative user data. Opening one reads its current note and review rather
/// than presenting the snapshot the parent page was built with.
private struct SavedMomentSheet: View {
    let id: String
    @State private var model = MomentsModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let moment = model.moments.first(where: { $0.id == id }) {
                MomentDetailSheet(moment: moment, source: model.source)
            } else if model.loaded {
                ContentUnavailableView("Moment removed", systemImage: "pin.slash")
                    .onAppear { dismiss() }
            } else if let error = model.error {
                Text(error).padding()
            } else {
                ProgressView("Loading moment…")
            }
        }
        .task(id: scenePhase) { if scenePhase == .active { await model.observe() } }
    }
}

struct MarkedMomentLinks: View {
    let moments: [Moment]
    var timeZone: TimeZone = .current

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(moments) { moment in
                let time = Date(timeIntervalSince1970: Double(moment.wallMs) / 1000)
                    .formatted(Date.FormatStyle(date: .omitted, time: .standard, timeZone: timeZone))
                MarkedMomentLink(id: moment.id,
                    text: moment.note.isEmpty ? "Marked at \(time)" : "\(time) · \(moment.note)")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct MarkedMomentCount: View {
    let count: Int
    var body: some View {
        Label("\(count) marked moment\(count == 1 ? "" : "s")", systemImage: "pin.fill")
            .font(AppFont.footnote).foregroundStyle(Tokens.tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}
