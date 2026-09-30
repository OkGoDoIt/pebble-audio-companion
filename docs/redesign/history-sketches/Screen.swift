import SwiftUI
import UIKit

enum HistoryLevel: String, CaseIterable, Hashable, Sendable { case day, week, month }

/// A page is named by the logical-day key of its first day ("2026-09-22"; a week's Sunday;
/// a month's 1st) so ids are stable, Hashable and cheap.
struct HistoryPageID: Hashable, Sendable, Comparable {
    var level: HistoryLevel
    var key: String
    static func < (a: Self, b: Self) -> Bool { a.key < b.key }
}

@MainActor
@Observable
final class HistoryModel {
    var level: HistoryLevel = .day
    /// The page the pager shows. Optional because `scrollPosition(id:)` binds `ID?`.
    var visiblePage: HistoryPageID?
    /// Bumped for a far jump (Today from 200 days back, calendar pick) so the pager is rebuilt
    /// at the target and cross-faded instead of scrolling past hundreds of pages.
    var jumpToken = 0
    var firstDayKey = "2026-06-01"
    var todayKey = "2026-09-30"
    /// Re-tap of the History tab increments this; the visible page scrolls to its top.
    var scrollToTopToken = 0

    func pages(for level: HistoryLevel) -> [HistoryPageID] {
        // Real version: date arithmetic from firstDayKey…todayKey (LogicalDay, 5 AM boundary).
        [HistoryPageID(level: level, key: todayKey)]
    }
    var isShowingToday: Bool { visiblePage?.key == todayKey && level == .day }

    func show(level newLevel: HistoryLevel, containing key: String) {
        level = newLevel
        visiblePage = HistoryPageID(level: newLevel, key: key)
        jumpToken += 1
    }
}

struct HistoryScreenSketch: View {
    @State private var model = HistoryModel()
    @State private var showsCalendar = false

    var body: some View {
        pager
            .id(model.level)  // one pager per level; switching levels rebuilds and cross-fades
            .transition(.opacity)
            .safeAreaBar(edge: .top) {
                Picker("Zoom", selection: levelBinding) {
                    ForEach(HistoryLevel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .levelPickerStyle()
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
            .navigationTitle("History")          // back-button text for pushed screens
            .toolbarTitleDisplayMode(.inline)
            .toolbar(removing: .title)            // the in-page title row is the title
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !model.isShowingToday {
                        Button("Today") { model.show(level: model.level, containing: model.todayKey) }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Jump to date", systemImage: "calendar") { showsCalendar = true }
                    Button("Search", systemImage: "magnifyingglass") {}
                }
            }
            .sheet(isPresented: $showsCalendar) {
                JumpCalendar(range: DateInterval(start: .distantPast, end: .now), marked: []) { _ in
                    showsCalendar = false
                }
                .presentationDetents([.medium, .large])
            }
    }

    private var levelBinding: Binding<HistoryLevel> {
        Binding(get: { model.level }, set: { new in
            withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.2)) {
                model.show(level: new, containing: model.visiblePage?.key ?? model.todayKey)
            }
        })
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(model.pages(for: model.level), id: \.self) { page in
                    PageSketch(page: page, isCurrent: page == model.visiblePage,
                               scrollToTopToken: model.scrollToTopToken)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $model.visiblePage)
        .defaultScrollAnchor(.trailing, for: .initialOffset)   // today is the last page
        .scrollIndicators(.hidden)
        .id(model.jumpToken)
    }
}

struct PageSketch: View {
    var page: HistoryPageID
    var isCurrent: Bool
    var scrollToTopToken: Int
    @State private var position = ScrollPosition(edge: .top)
    @State private var insets = EdgeInsets()

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Tuesday").font(.largeTitle.bold())
                    Text("September 22").font(.title3).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: break   // next day
                    case .decrement: break   // previous day
                    @unknown default: break
                    }
                }
                DayTimelineSketch(items: [], marks: [], insets: insets)
                    .accessibilityRotor("Chapters") {
                        AccessibilityRotorEntry("Coffee and sprint planning", id: "c1")
                    }
            }
            .padding(.horizontal, 16)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: EdgeInsets.self) { $0.contentInsets } action: { _, new in
            insets = new
        }
        .onChange(of: scrollToTopToken) { if isCurrent { withAnimation { position.scrollTo(edge: .top) } } }
        .task(id: isCurrent) {
            guard isCurrent else { return }
            // observe this page's data only while it is the visible page
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

// MARK: - Re-tap detection on the tab bar

@MainActor
func reselectingBinding<T: Hashable>(_ get: @escaping () -> T, set: @escaping (T) -> Void,
                                     reselected: @escaping (T) -> Void) -> Binding<T> {
    Binding(get: get, set: { new in
        if new == get() { reselected(new) } else { set(new) }
    })
}

// MARK: - Jump-to-date calendar

struct JumpCalendar: UIViewRepresentable {
    var range: DateInterval
    var marked: Set<DateComponents>
    var onPick: (DateComponents) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.calendar = Calendar(identifier: .gregorian)
        view.availableDateRange = range
        view.delegate = context.coordinator
        view.selectionBehavior = UICalendarSelectionSingleDate(delegate: context.coordinator)
        view.wantsDateDecorations = true
        return view
    }

    func updateUIView(_ view: UICalendarView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var parent: JumpCalendar
        init(parent: JumpCalendar) { self.parent = parent }

        func calendarView(_ calendarView: UICalendarView,
                          decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            var key = dateComponents
            key.calendar = nil; key.era = nil
            return parent.marked.contains(key) ? .default(color: .systemIndigo, size: .small) : nil
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            if let dateComponents { parent.onPick(dateComponents) }
        }
    }
}
