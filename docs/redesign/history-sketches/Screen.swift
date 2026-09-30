import SwiftUI

// Corrected pager / chrome setup after the 2026-09-30 simulator spike. Changes vs. the sketch
// are marked `SPIKE:`. `DayPageView` is a stand-in for the real page (see Stubs.swift).

enum HistoryLevel: String, CaseIterable, Hashable, Sendable { case day, week, month }

struct HistoryPageID: Hashable, Sendable, Comparable {
    var level: HistoryLevel
    var key: String
    static func < (a: Self, b: Self) -> Bool { a.key < b.key }
}

@MainActor
@Observable
final class HistoryModel {
    var level: HistoryLevel = .day
    /// SPIKE: must be non-nil BEFORE the pager's first layout. This is what positions the pager:
    /// with it set, the bound id won in every run (page 199 and page 120, with or without the
    /// trailing anchor). With it nil, `.defaultScrollAnchor(.trailing, for: .initialOffset)`
    /// did nothing and the pager opened on the FIRST page (shots/q3-init-modes-top-crops.png).
    /// Setting it in onAppear also worked, but only because it lands in the same transaction.
    var visiblePage: HistoryPageID?
    var jumpToken = 0
    var scrollToTopToken = 0
    private(set) var pages: [HistoryPageID] = []

    init(pages: [HistoryPageID], initial: HistoryPageID?) {
        self.pages = pages
        visiblePage = initial ?? pages.last
    }

    var isShowingToday: Bool { visiblePage == pages.last }

    /// SPIKE: pages further than one from the visible page draw a placeholder. The LazyHStack
    /// lays out at offset 0 first and fully builds pages 0 and 1 before jumping to the target
    /// (~200 ms Debug in the simulator, never drawn); this gate removed that cost (first content
    /// 0.313 s vs 0.511 s after launch, logs/gate0.log vs gate1.log).
    func isNear(_ page: HistoryPageID) -> Bool {
        guard let v = visiblePage, let a = pages.firstIndex(of: v), let b = pages.firstIndex(of: page)
        else { return page == pages.last }
        return abs(a - b) <= 1
    }
}

struct HistoryScreen: View {
    @Bindable var model: HistoryModel

    var body: some View {
        pager
            .id(model.level)
            .transition(.opacity)
            .safeAreaBar(edge: .top) {
                Picker("Zoom", selection: $model.level) {
                    ForEach(HistoryLevel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .levelPickerStyle()
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
            // Verified: the back button on a pushed screen is chevron-only on iOS 27 (no text at
            // all), and its long-press menu reads "History" — the title survives removal.
            .navigationTitle("History")
            .toolbarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                // Either form (if around or inside the ToolbarItem) left no empty glass on iOS 27.
                if !model.isShowingToday {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Today") { /* model.show(...) */ }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Jump to date", systemImage: "calendar") {}
                    Button("Search", systemImage: "magnifyingglass") {}
                }
            }
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(model.pages, id: \.self) { page in
                    DayPageView(page: page, isCurrent: page == model.visiblePage,
                                isNear: model.isNear(page), scrollToTopToken: model.scrollToTopToken)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $model.visiblePage)
        // SPIKE: no `.defaultScrollAnchor(.trailing, for: .initialOffset)` — it never won.
        .scrollIndicators(.hidden)
        // SPIKE: the scroll edge effect under the bars belongs to the OUTER pager. Setting
        // `scrollEdgeEffectStyle` on the page scroll views changed nothing; on the pager it does.
        // Automatic resolved to the hard style (hairline under the picker, content hidden behind
        // it); `.soft` shows content fading behind the picker. Design decision, see report.
        .accessibilityScrollAction { edge in
            guard let v = model.visiblePage, let i = model.pages.firstIndex(of: v) else { return }
            switch edge {
            case .leading where i + 1 < model.pages.count: model.visiblePage = model.pages[i + 1]
            case .trailing where i > 0: model.visiblePage = model.pages[i - 1]
            default: break
            }
        }
        // SPIKE caveat: after a History-tab re-tap the pager's scroll phase goes idle → animating
        // and stays there until the next real scroll (the system's scroll-to-top targets the
        // pager). Never gate logic on the pager's phase being `.idle`.
        .id(model.jumpToken)
    }
}

/// Tab re-tap: VERIFIED — the custom setter fires with new == current. The system then pops a
/// pushed NavigationStack to root by itself (path 1 → 0, ~30 ms after the setter), but does NOT
/// scroll the page to top (its scroll-to-top went to the horizontal pager). So: if the stack is
/// pushed, do nothing (the system pops); otherwise bump scrollToTopToken (verified to work).
@MainActor
func reselectingBinding<T: Hashable>(_ get: @escaping @MainActor @Sendable () -> T,
                                     set: @escaping @MainActor @Sendable (T) -> Void,
                                     reselected: @escaping @MainActor @Sendable (T) -> Void) -> Binding<T> {
    // SPIKE: iOS 27 SDK — the sketch's non-Sendable closures warn under Swift 6 here.
    Binding(get: get, set: { new in
        if new == get() { reselected(new) } else { set(new) }
    })
}

struct DayPageView: View {
    var page: HistoryPageID
    var isCurrent: Bool
    var isNear: Bool
    var scrollToTopToken: Int
    @State private var position = ScrollPosition(edge: .top)

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                PageTitle(page: page)
                if isNear {
                    DayTimelineStub()           // brief card, timeline, end lines
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollPosition($position)
        // SPIKE: no onScrollGeometryChange(contentInsets) → @State. The pin doesn't need insets,
        // and every such write re-ran the timeline's measurement (13-15 ms).
        .onChange(of: scrollToTopToken) {
            if isCurrent { withAnimation { position.scrollTo(edge: .top) } }
        }
    }
}

extension View {
    @ViewBuilder
    func levelPickerStyle() -> some View {
        if #available(iOS 27.0, *) {
            self.pickerStyle(.tabs)
        } else {
            self.pickerStyle(.segmented)
        }
    }
}
