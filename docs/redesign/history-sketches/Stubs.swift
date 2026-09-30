import SwiftUI

// Stand-ins so the corrected files type-check on their own:
// xcrun -sdk iphonesimulator swiftc -typecheck -swift-version 6 \
//   -target arm64-apple-ios26.0-simulator corrected/*.swift

struct PageTitle: View {
    var page: HistoryPageID
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(page.key).font(.largeTitle.bold())
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityAdjustableAction { _ in }
    }
}

struct DayTimelineStub: View {
    var body: some View { Color.clear.frame(height: 100) }
}
