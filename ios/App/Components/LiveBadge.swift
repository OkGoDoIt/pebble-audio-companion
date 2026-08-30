import SwiftUI

/// The green Live badge: 11/600 `good` text on `goodFill`, r9 (capsule), padding 2/8.
struct LiveBadge: View {
    var body: some View {
        Text(Copy.Status.live)
            .font(AppFont.microBold)
            .foregroundStyle(Tokens.good)
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .background(Capsule().fill(Tokens.goodFill))
            .accessibilityLabel(Copy.Status.live)
    }
}

#Preview("Live badge") {
    VStack(spacing: 12) {
        LiveBadge()
        HStack {
            Text("App redesign session").font(AppFont.rowTitle).foregroundStyle(Tokens.label)
            LiveBadge()
        }
    }
    .padding(Tokens.screenMargin)
    .background(Tokens.ground)
}
