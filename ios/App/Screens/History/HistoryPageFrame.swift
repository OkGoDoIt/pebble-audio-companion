import AppDB
import SwiftUI

// What every History page shares, whatever its level: a vertical scroll view of its own, the
// large title drawn inside it (so "Tuesday / September 22" slides away with Tuesday), the
// scroll-to-top token, and the report of whether it is scrolled (for the tab re-tap).
//
// Pages are compared by `HistoryPageContext` alone (`.equatable()`), so moving the pager does
// not re-run the bodies of pages whose context did not change: every re-run of a day page
// re-measures its timeline (~13 ms, spike).

/// The plain facts a page is drawn from. Equatable, so an unchanged page is skipped.
struct HistoryPageContext: Equatable {
    var page: HistoryPageID
    var todayKey: String
    /// The page in view: it subscribes to its stream and takes the scroll-to-top token.
    var isCurrent: Bool
    /// The page in view or one beside it: it draws its content. Further pages draw only their
    /// title (spike: this stopped the lazy stack building pages 0 and 1 at launch).
    var isNear: Bool
    var scrollToTopToken: Int
    /// Bumped after a level change: the current page's title takes VoiceOver focus.
    var titleFocusToken: Int
}

/// The reference-typed services every page uses. Not observed and not compared: a page never
/// re-renders because of it.
@MainActor
final class HistoryPageServices {
    let source: any HistoryDataSource
    var actions: HistoryActions
    /// Next (+1) or previous (-1) period, for the title's adjustable action.
    var adjust: (Int) -> Void
    /// A page says whether it is scrolled away from its top.
    var reportScrolled: (HistoryPageID, Bool) -> Void
    /// A week or month row opens a lower level (drill-down).
    var drillDown: (HistoryLevel, String) -> Void

    init(
        source: any HistoryDataSource, actions: HistoryActions = HistoryActions(),
        adjust: @escaping (Int) -> Void = { _ in },
        reportScrolled: @escaping (HistoryPageID, Bool) -> Void = { _, _ in },
        drillDown: @escaping (HistoryLevel, String) -> Void = { _, _ in }
    ) {
        self.source = source
        self.actions = actions
        self.adjust = adjust
        self.reportScrolled = reportScrolled
        self.drillDown = drillDown
    }
}

struct HistoryPageFrame<Content: View>: View {
    let context: HistoryPageContext
    let services: HistoryPageServices
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    @State private var position = ScrollPosition(edge: .top)

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                HistoryPageTitle(
                    title: title, subtitle: subtitle,
                    focusToken: context.isCurrent ? context.titleFocusToken : nil,
                    onAdjust: services.adjust)
                if context.isNear {
                    content()
                }
            }
            .padding(.horizontal, Tokens.screenMargin)
            .padding(.bottom, Tokens.blockGap)
        }
        .scrollPosition($position)
        .background(Tokens.ground)
        // A Bool, so this fires once when the page leaves its top and once when it returns —
        // and it writes nothing the page draws.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 1
        } action: { _, scrolled in
            services.reportScrolled(context.page, scrolled)
        }
        .onChange(of: context.scrollToTopToken) {
            if context.isCurrent {
                withAnimation(Motion.animation(.easeInOut(duration: 0.3))) {
                    position.scrollTo(edge: .top)
                }
            }
        }
        .onDisappear { services.reportScrolled(context.page, false) }
    }
}

/// A History page's title, drawn in the page under the level control (plan 5.1, 7.12): large
/// and left-aligned, one line ("Sep 20 – 26") or two ("Tuesday" / "September 22").
///
/// For VoiceOver it is the header and the pager at once (plan 5.9): swipes are VoiceOver's, so
/// paging is the title's adjustable action — swipe up for the next period, down for the one
/// before. After a level change it takes focus, so the new level announces itself.
struct HistoryPageTitle: View {
    let title: String
    var subtitle: String?
    /// Non-nil on the current page; a change moves VoiceOver focus here.
    var focusToken: Int?
    var onAdjust: ((Int) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(AppFont.historyTitle(dynamicTypeSize))
                .foregroundStyle(Tokens.label)
            if let subtitle {
                Text(subtitle)
                    .font(AppFont.bodyPlain)
                    .foregroundStyle(Tokens.meta)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(onAdjust == nil ? "" : Copy.History.A11y.titleHint)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onAdjust?(1)
            case .decrement: onAdjust?(-1)
            @unknown default: break
            }
        }
        .accessibilityFocused($focused)
        // `.task(id:)`, not `onChange`: after a level change this title belongs to a page
        // that did not exist a moment ago, and it has to act on the token it was born with.
        // Zero is a fresh screen, which leaves VoiceOver where the system put it.
        .task(id: focusToken) {
            guard let focusToken, focusToken > 0 else { return }
            // After the level's transition has settled, or VoiceOver lands on the old page.
            try? await Task.sleep(for: .milliseconds(350))
            focused = true
        }
    }
}

/// What a page's stream task restarts on: which page, and whether it is current or near.
struct HistoryStreamKey: Hashable {
    var page: HistoryPageID
    var isCurrent: Bool
    var isNear: Bool

    init(_ context: HistoryPageContext) {
        page = context.page
        isCurrent = context.isCurrent
        isNear = context.isNear
    }
}
